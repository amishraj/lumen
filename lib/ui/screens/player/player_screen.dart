import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../data/models/models.dart';
import '../../../data/sources/realdebrid_service.dart';
import '../../../data/sources/trakt_service.dart';
import '../../../state/playback_engine.dart';
import '../../../state/providers.dart';
import '../../theme/lumen_theme.dart';
import '../../title_utils.dart';
import '../../widgets/focusable_item.dart';
import '../../widgets/source_picker.dart';

/// Structured identity of what's playing, for Real-Debrid stream lookups.
/// [episodes] holds (season, episode) per queue index for series.
class DebridContext {
  const DebridContext({
    required this.title,
    this.isShow = false,
    this.episodes,
  });
  final String title;
  final bool isShow;
  final List<(int, int)>? episodes;
}

/// Full-screen player backed by libmpv (media_kit). Handles MPEG-TS, HLS and
/// the odd codecs common in IPTV, with hardware decode where available.
///
/// Optionally takes a [queue] (e.g. a season's episodes) so the user can skip
/// to the next/previous item without leaving the player, and a [debrid]
/// context so the in-player source switch can offer Real-Debrid streams.
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({
    super.key,
    required this.item,
    this.queue,
    this.startIndex = 0,
    this.debrid,
  });

  final StreamItem item;
  final List<StreamItem>? queue;
  final int startIndex;
  final DebridContext? debrid;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  // The app-wide playback pipeline: never disposed, only stopped. See
  // PlaybackEngine for why per-screen Player instances kept leaking audio.
  Player get _player => PlaybackEngine.instance.player;
  VideoController get _controller => PlaybackEngine.instance.controller;

  /// Event ownership: the shared player emits to every mounted PlayerScreen,
  /// so if two get stacked (double OK-press), only the newest may react —
  /// otherwise a buried screen writes the wrong progress or auto-advances.
  static _PlayerScreenState? _active;
  bool get _ownsPlayback => _active == this;

  late final List<StreamItem> _queue =
      widget.queue == null || widget.queue!.isEmpty
          ? [widget.item]
          : widget.queue!;
  late int _index = widget.startIndex.clamp(0, _queue.length - 1);

  StreamItem get _current => _queue[_index];

  String? _error;
  bool _sought = false;
  bool _reconnecting = false;
  int _liveRetries = 0;
  double? _resume;
  int _lastPosMs = 0;
  int _lastDurMs = 0;

  // Playback state driven straight off the libmpv streams so our own overlay
  // can render a buffering spinner + play/pause + seek bar (we no longer use
  // media_kit's built-in controls, which aren't remote-navigable).
  bool _buffering = true;
  bool _playing = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  final List<StreamSubscription<dynamic>> _subs = [];

  // ---- Keyboard/remote controls overlay -------------------------------
  // Controls auto-hide so video can play full-screen, but any arrow/select
  // press (and not just a tap/mouse move) brings them back so the player is
  // fully usable with no pointer.
  bool _controlsVisible = true;
  Timer? _hideTimer;
  final FocusNode _rootFocus = FocusNode(debugLabel: 'player-root');
  final FocusNode _firstControlFocus =
      FocusNode(debugLabel: 'player-first-control');

  static final _wakeKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.gameButtonA,
  };

  @override
  void initState() {
    super.initState();
    _active = this;
    // Every listener is stored and cancelled in dispose — the global player
    // outlives this screen, so an unstored listener would fire forever.
    _subs.add(_player.stream.position.listen(_onPosition));
    _subs.add(_player.stream.completed.listen(_onCompleted));
    // Drive the overlay's spinner / play-pause / seek bar.
    _subs.add(_player.stream.buffering.listen((b) {
      if (mounted) setState(() => _buffering = b);
    }));
    _subs.add(_player.stream.playing.listen((p) {
      if (mounted) setState(() => _playing = p);
    }));
    _subs.add(_player.stream.position.listen((p) {
      if (mounted) setState(() => _position = p);
    }));
    _subs.add(_player.stream.duration.listen((d) {
      if (mounted) setState(() => _duration = d);
    }));
    // Default to the English audio track for movies/shows when the source
    // carries several languages; fall back to whatever libmpv picked otherwise.
    _subs.add(
        _player.stream.tracks.listen((t) => _maybePickEnglishAudio(t.audio)));
    _init();
    _resetHideTimer();
  }

  bool _autoAudioPicked = false;

  void _maybePickEnglishAudio(List<AudioTrack> tracks) {
    if (!_ownsPlayback ||
        _autoAudioPicked ||
        _current.kind == StreamKind.live) {
      return;
    }
    final en = tracks.firstWhere(
      (t) =>
          t != AudioTrack.no() &&
          t != AudioTrack.auto() &&
          (t.language ?? '').toLowerCase().startsWith('en'),
      orElse: () => AudioTrack.no(),
    );
    if (en != AudioTrack.no()) {
      _autoAudioPicked = true;
      _player.setAudioTrack(en);
    }
  }

  void _showControls({bool focusFirst = true}) {
    if (!mounted) return;
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _resetHideTimer();
    if (focusFirst) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controlsVisible) _firstControlFocus.requestFocus();
      });
    }
  }

  void _resetHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), _hideControls);
  }

  void _hideControls() {
    if (!mounted || !_controlsVisible) return;
    setState(() => _controlsVisible = false);
    // Reclaim focus so the very next arrow/select press is caught here
    // instead of being lost (nothing inside the hidden overlay is focusable).
    _rootFocus.requestFocus();
  }

  /// Sits above everything else so a key press is seen even when no control
  /// is currently focused (controls hidden = nothing focusable underneath).
  KeyEventResult _onRootKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_wakeKeys.contains(event.logicalKey)) return KeyEventResult.ignored;
    if (!_controlsVisible) {
      _showControls();
      return KeyEventResult.handled;
    }
    // Controls already visible: let the key fall through to whichever
    // control has focus, but keep the overlay alive while navigating.
    _resetHideTimer();
    return KeyEventResult.ignored;
  }

  Future<void> _init() async {
    await _configureMpv();
    await PlaybackEngine.instance.restoreVolume(); // teardown mutes to 0
    await _openAt(_index);
  }

  /// Tune libmpv for flaky / slow IPTV networks: bigger caches, hardware
  /// decode where safe, and FFmpeg-level auto-reconnect on dropped sockets.
  Future<void> _configureMpv() async {
    final p = _player.platform;
    if (p is! NativePlayer) return;
    Future<void> set(String k, String v) async {
      try {
        await p.setProperty(k, v);
      } catch (_) {/* property may not exist on this build */}
    }

    await set('hwdec', 'auto-safe'); // offload decode on weak TV boxes
    await set('cache', 'yes');
    await set('cache-secs', '30');
    await set('demuxer-max-bytes', '${96 * 1024 * 1024}');
    await set('demuxer-max-back-bytes', '${48 * 1024 * 1024}');
    await set('demuxer-readahead-secs', '20');
    await set('network-timeout', '60'); // be patient on slow links
    // Reconnect transparently when a live HTTP/HLS socket drops mid-stream.
    await set('stream-lavf-o',
        'reconnect=1,reconnect_streamed=1,reconnect_delay_max=10,reconnect_on_network_error=1');
  }

  Future<void> _openAt(int i) async {
    setState(() {
      _index = i.clamp(0, _queue.length - 1);
      _error = null;
      _reconnecting = false;
      _liveRetries = 0;
      _sought = false;
      _resume = null;
      _lastPosMs = 0;
      _lastDurMs = 0;
      _autoAudioPicked = false; // re-pick English audio for the new item
    });
    await _load();
  }

  /// Per-queue-index URL overrides set by the in-player source switch
  /// (e.g. the user swapped this episode to a Real-Debrid stream).
  final Map<int, String> _urlOverrides = {};

  Future<void> _load() async {
    try {
      await _player.open(Media(_urlOverrides[_index] ?? _current.url),
          play: true);
    } catch (e) {
      // Live: keep trying. VOD: surface the error.
      if (_current.kind == StreamKind.live) {
        _scheduleLiveReconnect();
      } else if (mounted) {
        setState(() => _error = '$e');
      }
      return;
    }
    if (mounted) setState(() => _reconnecting = false);
    _liveRetries = 0;
    if (_current.kind == StreamKind.live) return;
    _scrobble('start'); // real-time "watching now" on Trakt
    final svc = ref.read(traktServiceProvider).valueOrNull;
    _resume = await svc?.resumeProgress(_current.name,
        isShow: _current.kind == StreamKind.series);
  }

  /// Live streams have no real "end" — if libmpv reports completion (the server
  /// closed the socket, a segment ran out), reconnect with backoff instead of
  /// sitting paused. VOD at the end auto-advances to the next episode.
  void _onCompleted(bool done) {
    if (!done || !mounted || !_ownsPlayback) return;
    if (_current.kind == StreamKind.live) {
      _scheduleLiveReconnect();
    } else if (_index < _queue.length - 1) {
      _skip(1);
    }
  }

  void _scheduleLiveReconnect() {
    if (_reconnecting || !mounted) return;
    setState(() {
      _reconnecting = true;
      _liveRetries++;
    });
    final secs = (2 * _liveRetries).clamp(2, 10);
    Future.delayed(Duration(seconds: secs), () async {
      if (!mounted) return;
      _reconnecting = false;
      await _load();
    });
  }

  Future<void> _onPosition(Duration pos) async {
    if (!_ownsPlayback || _current.kind == StreamKind.live) return;
    final dur = _player.state.duration;
    if (dur.inMilliseconds <= 0) return;
    _lastPosMs = pos.inMilliseconds;
    _lastDurMs = dur.inMilliseconds;

    if (!_sought && _resume != null && _resume! > 0.02 && _resume! < 0.9) {
      _sought = true;
      await _player.seek(
          Duration(milliseconds: (dur.inMilliseconds * _resume!).round()));
    }
    if (_current.id != null) {
      final repo = ref.read(repositoryProvider).valueOrNull;
      await repo?.db
          .saveProgress(_current.id!, pos.inMilliseconds, dur.inMilliseconds);
    }
  }

  // ---- Trakt scrobbling ------------------------------------------------
  // Real protocol: start when playback begins/resumes, pause on pause, stop
  // on exit/skip. Trakt stores the exact stop position (<80% → continue
  // watching at that timestamp; ≥80% → scrobbled as watched), so what you see
  // on trakt.tv matches where you actually left the player.

  /// (title, isShow, season, episode) for the item currently playing.
  (String, bool, int?, int?) _scrobbleIdentity() {
    final ctx = widget.debrid;
    final isShow = ctx?.isShow ?? _current.kind == StreamKind.series;
    int? season, episode;
    if (ctx?.episodes != null && _index < ctx!.episodes!.length) {
      (season, episode) = ctx.episodes![_index];
    } else if (isShow) {
      // Fallback: parse "S1E2 · Title" queue names.
      final m = RegExp(r'^S(\d+)E(\d+)').firstMatch(_current.name);
      season = int.tryParse(m?.group(1) ?? '');
      episode = int.tryParse(m?.group(2) ?? '');
    }
    final raw = ctx?.title ?? _current.name;
    return (cleanTitle(raw).title, isShow, season, episode);
  }

  double get _progressPct =>
      _lastDurMs > 0 ? (_lastPosMs / _lastDurMs * 100.0).clamp(0, 100) : 0;

  void _scrobble(String action) {
    if (_current.kind == StreamKind.live) return;
    final (title, isShow, season, episode) = _scrobbleIdentity();
    // Fire-and-forget: scrobbling must never block or break playback.
    ref.read(traktServiceProvider).valueOrNull?.scrobble(action, title,
        isShow: isShow,
        season: season,
        episode: episode,
        progressPct: _progressPct);
  }

  void _checkpoint() {
    // Exact exit position → Trakt (watched if ≥80%, else continue-watching).
    if (_current.kind != StreamKind.live && _lastDurMs > 0) {
      _scrobble('stop');
    }
  }

  void _skip(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= _queue.length) return;
    _checkpoint();
    _openAt(next);
  }

  @override
  void dispose() {
    _checkpoint();
    _hideTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _rootFocus.dispose();
    _firstControlFocus.dispose();
    if (_active == this) _active = null;
    // Stop the shared pipeline — verified & retried inside the engine. No
    // dispose(): the engine owns the player for the app's lifetime, which is
    // what finally makes "exit = silence" deterministic.
    unawaited(PlaybackEngine.instance.stopPlayback());
    super.dispose();
  }

  // ---- Track selection -----------------------------------------------------

  void _pickSubtitle() {
    final tracks = _player.state.tracks.subtitle;
    final current = _player.state.track.subtitle;
    _showTrackSheet(
      title: 'Subtitles',
      options: [
        _TrackOption('Off', current == SubtitleTrack.no(),
            () => _player.setSubtitleTrack(SubtitleTrack.no())),
        for (final t in tracks)
          if (t != SubtitleTrack.no() && t != SubtitleTrack.auto())
            _TrackOption(_label(t.title, t.language, t.id), current == t,
                () => _player.setSubtitleTrack(t)),
      ],
    );
  }

  void _pickAudio() {
    final tracks = _player.state.tracks.audio;
    final current = _player.state.track.audio;
    _showTrackSheet(
      title: 'Audio',
      options: [
        for (final t in tracks)
          if (t != AudioTrack.no() && t != AudioTrack.auto())
            _TrackOption(_label(t.title, t.language, t.id), current == t,
                () => _player.setAudioTrack(t)),
      ],
    );
  }

  String _label(String? title, String? language, String id) {
    final parts = [
      if (title != null && title.isNotEmpty) title,
      if (language != null && language.isNotEmpty) language.toUpperCase(),
    ];
    return parts.isEmpty ? 'Track $id' : parts.join(' · ');
  }

  void _showTrackSheet(
      {required String title, required List<_TrackOption> options}) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF15171F),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
              ),
            ),
            if (options.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('No tracks available.',
                    style: TextStyle(color: Color(0xFF9AA0B0))),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final o in options)
                    ListTile(
                      leading: Icon(
                        o.selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: o.selected
                            ? LumenTheme.accent
                            : const Color(0xFF6B7080),
                      ),
                      title: Text(o.label),
                      onTap: () {
                        o.apply();
                        Navigator.pop(ctx);
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleFavorite() async {
    if (_current.id == null) return;
    final favs = ref.read(favoriteIdsProvider).valueOrNull ?? const <int>{};
    await setFavorite(ref, _current, !favs.contains(_current.id));
  }

  void _togglePlay() {
    final wasPlaying = _playing;
    _player.playOrPause();
    _resetHideTimer();
    // Mirror pause/resume to Trakt in real time.
    _scrobble(wasPlaying ? 'pause' : 'start');
  }

  /// In-player source switch (IPTV ↔ Real-Debrid). Keeps the playback
  /// position for VOD so switching quality doesn't lose your place.
  Future<void> _pickSource() async {
    _resetHideTimer();
    final ctx = widget.debrid;
    final isShow = ctx?.isShow ?? _current.kind == StreamKind.series;
    final se = ctx?.episodes != null && _index < ctx!.episodes!.length
        ? ctx.episodes![_index]
        : null;
    final picked = await showSourcePicker(
      context,
      ref,
      title: ctx?.title ?? _current.name,
      isShow: isShow,
      season: se?.$1,
      episode: se?.$2,
      iptvUrl: _current.url,
    );
    if (picked == null || !mounted) return;
    final resumeAt = _position;
    _sought = true; // suppress the Trakt auto-resume; we restore manually
    setState(() {
      _urlOverrides[_index] = picked.url;
      _buffering = true;
    });
    await _load();
    // Restore position on VOD once the new stream is up.
    if (_current.kind != StreamKind.live && resumeAt > Duration.zero) {
      await _player.seek(resumeAt);
    }
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final hasQueue = _queue.length > 1;
    final favs = ref.watch(favoriteIdsProvider).valueOrNull ?? const <int>{};
    final isFav = _current.id != null && favs.contains(_current.id);
    final isLive = _current.kind == StreamKind.live;
    final rdOn = ref.watch(rdEnabledProvider).valueOrNull ?? false;
    // Spinner while libmpv fills its buffer — without this a slow live stream
    // is just a black screen with no feedback.
    final showSpinner = _buffering && !_reconnecting && _error == null;

    return PopScope(
      // While the controls overlay is up, Back should dismiss it rather than
      // leave the player — only pop out once the controls are already hidden.
      canPop: !_controlsVisible,
      onPopInvokedWithResult: (didPop, _) {
        // The instant a real back happens, silence playback — don't wait for
        // dispose()/stop() to work through media_kit's command queue.
        if (didPop) {
          PlaybackEngine.instance.pauseNow();
        } else if (_controlsVisible) {
          _hideControls();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _rootFocus,
          autofocus: true,
          skipTraversal: true,
          canRequestFocus: true,
          onKeyEvent: _onRootKey,
          child: MouseRegion(
            onHover: (_) => _showControls(focusFirst: false),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => _controlsVisible ? _hideControls() : _showControls(),
              child: Stack(
                children: [
                  Center(
                    child: _error != null
                        ? _ErrorView(message: _error!, name: _current.name)
                        : Video(
                            controller: _controller,
                            controls: NoVideoControls,
                            fit: BoxFit.contain,
                          ),
                  ),
                  if (_reconnecting)
                    const ColoredBox(
                      color: Colors.black54,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: LumenTheme.accent),
                            SizedBox(height: 14),
                            Text('Reconnecting to live stream…',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 13)),
                          ],
                        ),
                      ),
                    )
                  // Buffering spinner shows regardless of the controls overlay
                  // (but hidden behind the play/pause button when paused).
                  else if (showSpinner)
                    const Center(
                        child: CircularProgressIndicator(
                            color: LumenTheme.accent)),
                  IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: ExcludeFocus(
                      excluding: !_controlsVisible,
                      child: AnimatedOpacity(
                        opacity: _controlsVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: Container(
                          // Scrim so white controls stay legible over bright video.
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0x99000000),
                                Color(0x22000000),
                                Color(0x99000000),
                              ],
                              stops: [0.0, 0.5, 1.0],
                            ),
                          ),
                          child: Stack(
                            children: [
                              // ---- Top bar: back + track / episode / fav ----
                              SafeArea(
                                child: Row(
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: _RoundButton(
                                        icon: Icons.arrow_back,
                                        tooltip: 'Back',
                                        // Explicit tap = deliberate exit, so pop
                                        // directly instead of maybePop(), which
                                        // the PopScope above blocks while the
                                        // controls overlay is visible (that
                                        // guard is only meant for system/
                                        // hardware back — see canPop below).
                                        onTap: () {
                                          PlaybackEngine.instance.pauseNow();
                                          Navigator.of(context).pop();
                                        },
                                        onActivity: _resetHideTimer,
                                      ),
                                    ),
                                    const Spacer(),
                                    if (hasQueue)
                                      _RoundButton(
                                        icon: Icons.skip_previous,
                                        tooltip: 'Previous episode',
                                        enabled: _index > 0,
                                        onTap: () => _skip(-1),
                                        onActivity: _resetHideTimer,
                                      ),
                                    if (hasQueue) const SizedBox(width: 6),
                                    if (hasQueue)
                                      _RoundButton(
                                        icon: Icons.skip_next,
                                        tooltip: 'Next episode',
                                        enabled: _index < _queue.length - 1,
                                        onTap: () => _skip(1),
                                        onActivity: _resetHideTimer,
                                      ),
                                    if (hasQueue) const SizedBox(width: 6),
                                    if (_current.id != null)
                                      _RoundButton(
                                        icon: isFav
                                            ? Icons.favorite
                                            : Icons.favorite_border,
                                        iconColor: isFav
                                            ? LumenTheme.accentWarm
                                            : null,
                                        tooltip: isFav
                                            ? 'Remove from favorites'
                                            : 'Add to favorites',
                                        onTap: _toggleFavorite,
                                        onActivity: _resetHideTimer,
                                      ),
                                    if (_current.id != null)
                                      const SizedBox(width: 6),
                                    if (!isLive && rdOn) ...[
                                      _RoundButton(
                                        icon: Icons.swap_horiz,
                                        tooltip:
                                            'Change source (IPTV / Debrid)',
                                        onTap: _pickSource,
                                        onActivity: _resetHideTimer,
                                      ),
                                      const SizedBox(width: 6),
                                    ],
                                    if (!isLive)
                                      _RoundButton(
                                        icon: Icons.closed_caption,
                                        tooltip: 'Subtitles',
                                        onTap: _pickSubtitle,
                                        onActivity: _resetHideTimer,
                                      ),
                                    const SizedBox(width: 6),
                                    _RoundButton(
                                      icon: Icons.multitrack_audio,
                                      tooltip: 'Audio track',
                                      onTap: _pickAudio,
                                      onActivity: _resetHideTimer,
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                ),
                              ),
                              // ---- Center: play / pause (hidden while buffering) ----
                              if (!showSpinner)
                                Center(
                                  child: _RoundButton(
                                    focusNode: _firstControlFocus,
                                    big: true,
                                    icon: _playing
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                    tooltip: _playing ? 'Pause' : 'Play',
                                    onTap: _togglePlay,
                                    onActivity: _resetHideTimer,
                                  ),
                                ),
                              // ---- Bottom: title + seek bar (or LIVE pill) ----
                              SafeArea(
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        16, 0, 16, 12),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(_current.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600)),
                                        const SizedBox(height: 4),
                                        if (isLive)
                                          Row(children: [
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 3),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFFED1C24),
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                              child: const Text('● LIVE',
                                                  style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w800)),
                                            ),
                                          ])
                                        else
                                          _SeekBar(
                                            position: _position,
                                            duration: _duration,
                                            onSeek: (d) {
                                              _player.seek(d);
                                              _resetHideTimer();
                                            },
                                            fmt: _fmt,
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Seek bar with elapsed / remaining labels. The [Slider] is natively
/// focusable so Left/Right on a remote scrubs while it holds focus.
class _SeekBar extends StatelessWidget {
  const _SeekBar({
    required this.position,
    required this.duration,
    required this.onSeek,
    required this.fmt,
  });
  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final String Function(Duration) fmt;

  @override
  Widget build(BuildContext context) {
    final maxMs = duration.inMilliseconds;
    final posMs = position.inMilliseconds.clamp(0, maxMs == 0 ? 0 : maxMs);
    return Row(
      children: [
        Text(fmt(position),
            style: const TextStyle(color: Colors.white, fontSize: 12)),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: LumenTheme.accent,
              inactiveTrackColor: Colors.white24,
              thumbColor: LumenTheme.accent,
              overlayColor: LumenTheme.accent.withValues(alpha: 0.2),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(
              value: posMs.toDouble(),
              max: (maxMs == 0 ? 1 : maxMs).toDouble(),
              onChanged: maxMs == 0
                  ? null
                  : (v) => onSeek(Duration(milliseconds: v.round())),
            ),
          ),
        ),
        Text(fmt(duration),
            style: const TextStyle(color: Colors.white, fontSize: 12)),
      ],
    );
  }
}

class _TrackOption {
  final String label;
  final bool selected;
  final VoidCallback apply;
  _TrackOption(this.label, this.selected, this.apply);
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.enabled = true,
    this.iconColor,
    this.focusNode,
    this.onActivity,
    this.big = false,
  });
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final bool enabled;
  final Color? iconColor;
  final FocusNode? focusNode;
  final VoidCallback? onActivity;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final button = FocusableItem(
      focusNode: focusNode,
      borderRadius: big ? 40 : 24,
      onActivate: () {
        onActivity?.call();
        if (enabled) onTap();
      },
      builder: (context, focused) => CircleAvatar(
        radius: big ? 34 : 20,
        backgroundColor: Colors.black54,
        child: Icon(icon,
            size: big ? 40 : 24,
            color: !enabled
                ? const Color(0xFF5B6072)
                : (iconColor ?? Colors.white)),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.name});
  final String message;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline,
              color: LumenTheme.accentWarm, size: 48),
          const SizedBox(height: 16),
          Text('Couldn\'t play "$name"',
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 16)),
          const SizedBox(height: 8),
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF9AA0B0), fontSize: 12)),
        ],
      ),
    );
  }
}
