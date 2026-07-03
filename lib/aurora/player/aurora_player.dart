import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../data/models/models.dart';
import '../../data/sources/realdebrid_service.dart';
import '../../data/sources/trakt_service.dart';
import '../../state/playback_engine.dart';
import '../../state/providers.dart';
import '../../state/scrub_thumbs.dart';
import '../../ui/title_utils.dart';
import '../aurora_theme.dart';
import '../widgets/aurora_badges.dart';
import '../widgets/aurora_buttons.dart';
import '../widgets/aurora_image.dart';
import '../widgets/aurora_panel.dart';
import '../widgets/aurora_source_sheet.dart';

/// Structured identity of what's playing (for scrobbling + Real-Debrid switch).
/// [episodes] holds (season, episode) per queue index for series; [iptvUrl] is
/// the library's IPTV stream for the current title so the in-player source
/// switch can always offer "Play on IPTV" even when we started on Debrid.
class AuroraPlayContext {
  const AuroraPlayContext({
    required this.title,
    this.isShow = false,
    this.episodes,
    this.iptvUrl,
  });
  final String title;
  final bool isShow;
  final List<(int, int)>? episodes;
  final String? iptvUrl;
}

enum _Panel { none, queue, audio, subtitles }

/// Aurora's full-screen player. The playback core is a straight port of the
/// battle-tested 1.0 pipeline — the app-lifetime libmpv engine, verified stop,
/// live reconnect with backoff, 5s progress persistence, Trakt scrobbling,
/// English-audio auto-pick, background scrub previews — under a new, simpler
/// control surface:
///
/// - an always-visible progress bar pinned to the bottom
/// - Space / OK toggles play; ◀ ▶ seek ±30s straight away (no "enter scrub"
///   step); a brief frame preview shows where you're landing
/// - next-episode countdown card in the final 45s
/// - fit/fill aspect + 1x/1.5x/2x/0.5x speed
/// - live TV: channel banner with EPG now/next, CH±/▲▼ zapping, number entry
class AuroraPlayerScreen extends ConsumerStatefulWidget {
  const AuroraPlayerScreen({
    super.key,
    required this.item,
    this.queue,
    this.startIndex = 0,
    this.playContext,
    this.resumeFraction,
  });

  final StreamItem item;
  final List<StreamItem>? queue;
  final int startIndex;
  final AuroraPlayContext? playContext;

  /// Explicit resume point (0 = force from beginning). Null lets Trakt's
  /// cross-device resume decide.
  final double? resumeFraction;

  @override
  ConsumerState<AuroraPlayerScreen> createState() =>
      _AuroraPlayerScreenState();
}

class _AuroraPlayerScreenState extends ConsumerState<AuroraPlayerScreen> {
  Player get _player => PlaybackEngine.instance.player;
  VideoController get _controller => PlaybackEngine.instance.controller;

  /// Event ownership: the shared player emits to every mounted player screen;
  /// only the newest may react, or a buried screen writes the wrong progress.
  static _AuroraPlayerScreenState? _active;
  bool get _ownsPlayback => _active == this;

  late final List<StreamItem> _queue =
      widget.queue == null || widget.queue!.isEmpty
          ? [widget.item]
          : widget.queue!;
  late int _index = widget.startIndex.clamp(0, _queue.length - 1);
  StreamItem get _current => _queue[_index];
  bool get _isLive => _current.kind == StreamKind.live;
  bool get _hasQueue => _queue.length > 1;

  static const _seekStep = 30; // seconds — ◀ ▶ and the skip buttons

  String? _error;
  bool _sought = false;
  bool _reconnecting = false;
  int _liveRetries = 0;
  double? _resume;
  bool _forceFromStart = false;
  int _lastPosMs = 0;
  int _lastDurMs = 0;

  bool _buffering = true;
  bool _playing = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  final List<StreamSubscription<dynamic>> _subs = [];

  bool _controlsVisible = true;
  _Panel _panel = _Panel.none;
  Timer? _hideTimer;
  double _rate = 1.0;
  bool _fill = false; // false = fit (contain), true = fill (cover)

  // Brief seek preview (position bubble) shown for ~1.1s after a ◀ ▶ seek.
  Duration? _previewPos;
  Timer? _previewTimer;

  // Live number entry.
  String _digits = '';
  Timer? _digitTimer;

  final FocusNode _rootFocus = FocusNode(debugLabel: 'aurora-player-root');
  final FocusNode _playFocus = FocusNode(debugLabel: 'aurora-player-play');

  static final _wakeKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.gameButtonA,
  };

  static final _digitKeys = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.digit0: '0',
    LogicalKeyboardKey.digit1: '1',
    LogicalKeyboardKey.digit2: '2',
    LogicalKeyboardKey.digit3: '3',
    LogicalKeyboardKey.digit4: '4',
    LogicalKeyboardKey.digit5: '5',
    LogicalKeyboardKey.digit6: '6',
    LogicalKeyboardKey.digit7: '7',
    LogicalKeyboardKey.digit8: '8',
    LogicalKeyboardKey.digit9: '9',
    LogicalKeyboardKey.numpad0: '0',
    LogicalKeyboardKey.numpad1: '1',
    LogicalKeyboardKey.numpad2: '2',
    LogicalKeyboardKey.numpad3: '3',
    LogicalKeyboardKey.numpad4: '4',
    LogicalKeyboardKey.numpad5: '5',
    LogicalKeyboardKey.numpad6: '6',
    LogicalKeyboardKey.numpad7: '7',
    LogicalKeyboardKey.numpad8: '8',
    LogicalKeyboardKey.numpad9: '9',
  };

  @override
  void initState() {
    super.initState();
    _active = this;
    _subs.add(_player.stream.position.listen(_onPosition));
    _subs.add(_player.stream.completed.listen(_onCompleted));
    _subs.add(_player.stream.buffering.listen((b) {
      if (mounted) setState(() => _buffering = b);
    }));
    _subs.add(_player.stream.playing.listen((p) {
      if (mounted) setState(() => _playing = p);
    }));
    _subs.add(_player.stream.duration.listen((d) {
      if (mounted) setState(() => _duration = d);
    }));
    _subs.add(_player.stream.buffer.listen((b) {
      if (mounted) setState(() => _buffered = b);
    }));
    _subs.add(
        _player.stream.tracks.listen((t) => _maybePickEnglishAudio(t.audio)));
    _init();
    _resetHideTimer();
  }

  bool _autoAudioPicked = false;

  void _maybePickEnglishAudio(List<AudioTrack> tracks) {
    if (!_ownsPlayback || _autoAudioPicked || _isLive) return;
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

  Future<void> _init() async {
    await _configureMpv();
    await PlaybackEngine.instance.restoreVolume();
    await _openAt(_index);
  }

  /// Tune libmpv for flaky/slow IPTV networks — identical to the proven 1.0
  /// configuration (big caches, safe hwdec, FFmpeg auto-reconnect).
  Future<void> _configureMpv() async {
    final p = _player.platform;
    if (p is! NativePlayer) return;
    Future<void> set(String k, String v) async {
      try {
        await p.setProperty(k, v);
      } catch (_) {/* property may not exist on this build */}
    }

    await set('hwdec', 'auto-safe');
    await set('cache', 'yes');
    await set('cache-secs', '30');
    await set('demuxer-max-bytes', '${96 * 1024 * 1024}');
    await set('demuxer-max-back-bytes', '${48 * 1024 * 1024}');
    await set('demuxer-readahead-secs', '20');
    await set('network-timeout', '60');
    await set('stream-lavf-o',
        'reconnect=1,reconnect_streamed=1,reconnect_delay_max=10,reconnect_on_network_error=1');
  }

  /// Per-queue-index URL overrides from the in-player source switch.
  final Map<int, String> _urlOverrides = {};

  Future<void> _openAt(int i) async {
    setState(() {
      _index = i.clamp(0, _queue.length - 1);
      _error = null;
      _reconnecting = false;
      _liveRetries = 0;
      _sought = false;
      _resume = null;
      _forceFromStart = false;
      _lastPosMs = 0;
      _lastDurMs = 0;
      _autoAudioPicked = false;
      _thumbsScheduled = false;
      _buffered = Duration.zero;
      _position = Duration.zero;
      _duration = Duration.zero;
      _previewPos = null;
    });
    await _load();
    if (_rate != 1.0) {
      if (mounted) setState(() => _rate = 1.0);
      unawaited(_player.setRate(1.0));
    }
  }

  Future<void> _load() async {
    try {
      await _player.open(Media(_urlOverrides[_index] ?? _current.url),
          play: true);
    } catch (e) {
      if (_isLive) {
        _scheduleLiveReconnect();
      } else if (mounted) {
        setState(() => _error = '$e');
      }
      return;
    }
    if (mounted) setState(() => _reconnecting = false);
    _liveRetries = 0;
    if (_isLive) return;
    _scrobble('start');
    final requested = widget.resumeFraction;
    if (requested != null && _index == widget.startIndex) {
      if (requested <= 0.005) {
        _forceFromStart = true;
      } else {
        _resume = requested;
      }
      return;
    }
    final svc = ref.read(traktServiceProvider).valueOrNull;
    _resume = await svc?.resumeProgress(_current.name,
        isShow: _current.kind == StreamKind.series);
  }

  void _onCompleted(bool done) {
    if (!done || !mounted || !_ownsPlayback) return;
    if (_isLive) {
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

  bool _thumbsScheduled = false;
  int _lastSavedPosMs = -1;

  Future<void> _onPosition(Duration pos) async {
    if (mounted) setState(() => _position = pos);
    if (!_ownsPlayback || _isLive) return;
    final dur = _player.state.duration;
    if (dur.inMilliseconds <= 0) return;
    _lastPosMs = pos.inMilliseconds;
    _lastDurMs = dur.inMilliseconds;

    if (!_thumbsScheduled) {
      _thumbsScheduled = true;
      final url = _urlOverrides[_index] ?? _current.url;
      Future.delayed(const Duration(seconds: 12), () {
        if (!mounted || !_ownsPlayback) return;
        if ((_urlOverrides[_index] ?? _current.url) != url) return;
        ScrubThumbs.instance.generate(url, dur);
      });
    }

    if (!_sought &&
        !_forceFromStart &&
        _resume != null &&
        _resume! > 0.02 &&
        _resume! < 0.9) {
      _sought = true;
      await _player.seek(
          Duration(milliseconds: (dur.inMilliseconds * _resume!).round()));
    }
    if (_current.id != null &&
        (pos.inMilliseconds - _lastSavedPosMs).abs() >= 5000) {
      _lastSavedPosMs = pos.inMilliseconds;
      final repo = ref.read(repositoryProvider).valueOrNull;
      unawaited(repo?.db
          .saveProgress(_current.id!, pos.inMilliseconds, dur.inMilliseconds));
    }
  }

  // ---- Trakt scrobbling ----------------------------------------------------

  (String, bool, int?, int?) _scrobbleIdentity() {
    final ctx = widget.playContext;
    final isShow = ctx?.isShow ?? _current.kind == StreamKind.series;
    int? season, episode;
    if (ctx?.episodes != null && _index < ctx!.episodes!.length) {
      (season, episode) = ctx.episodes![_index];
    } else if (isShow) {
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
    if (_isLive) return;
    final (title, isShow, season, episode) = _scrobbleIdentity();
    ref.read(traktServiceProvider).valueOrNull?.scrobble(action, title,
        isShow: isShow,
        season: season,
        episode: episode,
        progressPct: _progressPct);
  }

  void _checkpoint() {
    if (_isLive || _lastDurMs <= 0) return;
    if (_current.id != null) {
      final repo = ref.read(repositoryProvider).valueOrNull;
      unawaited(repo?.db.saveProgress(_current.id!, _lastPosMs, _lastDurMs));
    }
    _scrobble('stop');
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
    _digitTimer?.cancel();
    _previewTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _rootFocus.dispose();
    _playFocus.dispose();
    if (_active == this) _active = null;
    ScrubThumbs.instance.cancel();
    unawaited(PlaybackEngine.instance.stopPlayback());
    super.dispose();
  }

  // ---- Controls visibility -------------------------------------------------

  void _showControls({bool focusFirst = true}) {
    if (!mounted) return;
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _resetHideTimer();
    if (focusFirst) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controlsVisible && _panel == _Panel.none) {
          _playFocus.requestFocus();
        }
      });
    }
  }

  void _resetHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), _hideControls);
  }

  void _hideControls() {
    if (!mounted || !_controlsVisible) return;
    // Never auto-hide while paused — a paused player with no chrome reads as
    // frozen (a 1.0 paper-cut this redesign fixes).
    if (!_playing && !_isLive) {
      _resetHideTimer();
      return;
    }
    setState(() => _controlsVisible = false);
    _rootFocus.requestFocus();
  }

  void _openPanel(_Panel p) {
    setState(() {
      _panel = p;
      _controlsVisible = true;
    });
    _hideTimer?.cancel();
  }

  void _closePanel() {
    setState(() => _panel = _Panel.none);
    _showControls(focusFirst: true);
  }

  // ---- Playback actions ----------------------------------------------------

  void _togglePlay() {
    final wasPlaying = _playing;
    _player.playOrPause();
    _resetHideTimer();
    _scrobble(wasPlaying ? 'pause' : 'start');
  }

  void _seekBy(int secs) {
    if (_isLive) return;
    var target = _position + Duration(seconds: secs);
    if (target < Duration.zero) target = Duration.zero;
    if (_duration > Duration.zero && target > _duration) target = _duration;
    _player.seek(target);
    setState(() => _position = target);
    _flashPreview(target);
    _showControls(focusFirst: false);
    _resetHideTimer();
  }

  /// Seek to an absolute position (pointer tap/drag on the track).
  void _seekTo(Duration d) {
    if (_isLive) return;
    _player.seek(d);
    setState(() => _position = d);
    _flashPreview(d);
    _resetHideTimer();
  }

  /// Show the position/frame preview bubble briefly after a keyboard seek.
  void _flashPreview(Duration at) {
    setState(() => _previewPos = at);
    _previewTimer?.cancel();
    _previewTimer = Timer(const Duration(milliseconds: 1100), () {
      if (mounted) setState(() => _previewPos = null);
    });
  }

  void _cycleRate() {
    const rates = [1.0, 1.5, 2.0, 0.5];
    final next = rates[(rates.indexOf(_rate) + 1) % rates.length];
    setState(() => _rate = next);
    unawaited(_player.setRate(next));
    _resetHideTimer();
  }

  void _toggleFill() {
    setState(() => _fill = !_fill);
    _resetHideTimer();
  }

  Future<void> _toggleFavorite() async {
    if (_current.id == null) return;
    final favs = ref.read(favoriteIdsProvider).valueOrNull ?? const <int>{};
    await setFavorite(ref, _current, !favs.contains(_current.id));
  }

  /// In-player source switch (IPTV ↔ Real-Debrid), keeping the position.
  Future<void> _pickSource() async {
    _resetHideTimer();
    final ctx = widget.playContext;
    final isShow = ctx?.isShow ?? _current.kind == StreamKind.series;
    final se = ctx?.episodes != null && _index < ctx!.episodes!.length
        ? ctx.episodes![_index]
        : null;
    // For a series episode the current url IS the IPTV stream; for a movie the
    // context carries the resolved library url (we may be on Debrid right now).
    final iptvUrl = isShow ? _current.url : (ctx?.iptvUrl ?? _current.url);
    final picked = await showAuroraSourceSheet(
      context,
      ref,
      title: ctx?.title ?? _current.name,
      isShow: isShow,
      season: se?.$1,
      episode: se?.$2,
      iptvUrl: iptvUrl,
    );
    if (picked == null || !mounted) return;
    final resumeAt = _position;
    _sought = true;
    setState(() {
      _urlOverrides[_index] = picked.url;
      _buffering = true;
    });
    await _load();
    if (!_isLive && resumeAt > Duration.zero) {
      await _player.seek(resumeAt);
    }
  }

  void _switchTo(int i) {
    _closePanel();
    if (i == _index) return;
    _checkpoint();
    _openAt(i);
    _showControls(focusFirst: false);
  }

  // ---- Live zapping --------------------------------------------------------

  void _zap(int delta) {
    if (!_isLive || !_hasQueue) return;
    var next = (_index + delta) % _queue.length;
    if (next < 0) next = _queue.length - 1;
    _openAt(next);
    _showControls(focusFirst: false);
  }

  void _onDigit(String d) {
    if (!_isLive) return;
    _digitTimer?.cancel();
    setState(() =>
        _digits = (_digits + d).substring(0, (_digits.length + 1).clamp(0, 4)));
    _digitTimer = Timer(const Duration(milliseconds: 1600), _commitDigits);
  }

  void _commitDigits() {
    final n = int.tryParse(_digits);
    setState(() => _digits = '');
    if (n == null) return;
    var target = _queue.indexWhere((e) => e.num == n);
    if (target < 0 && n >= 1 && n <= _queue.length) target = n - 1;
    if (target >= 0) {
      _openAt(target);
      _showControls(focusFirst: false);
    }
  }

  // ---- Root key handling ---------------------------------------------------

  KeyEventResult _onRootKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;

    // Space toggles play/pause everywhere.
    if (k == LogicalKeyboardKey.space) {
      _togglePlay();
      _showControls(focusFirst: false);
      return KeyEventResult.handled;
    }
    // Media keys work regardless of chrome state.
    if (k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.mediaPlay ||
        k == LogicalKeyboardKey.mediaPause) {
      _togglePlay();
      _showControls(focusFirst: false);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaFastForward) {
      _seekBy(_seekStep);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaRewind) {
      _seekBy(-_seekStep);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaTrackNext) {
      _isLive ? _zap(1) : _skip(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaTrackPrevious) {
      _isLive ? _zap(-1) : _skip(-1);
      return KeyEventResult.handled;
    }
    // Live: channel keys + number entry.
    if (_isLive) {
      if (k == LogicalKeyboardKey.channelUp) {
        _zap(1);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.channelDown) {
        _zap(-1);
        return KeyEventResult.handled;
      }
      final digit = _digitKeys[k];
      if (digit != null) {
        _onDigit(digit);
        _showControls(focusFirst: false);
        return KeyEventResult.handled;
      }
    }

    if (!_wakeKeys.contains(k)) return KeyEventResult.ignored;

    if (!_controlsVisible) {
      // Chrome hidden: give arrows immediate meaning, then wake.
      if (!_isLive && k == LogicalKeyboardKey.arrowLeft) {
        _seekBy(-_seekStep);
        return KeyEventResult.handled;
      }
      if (!_isLive && k == LogicalKeyboardKey.arrowRight) {
        _seekBy(_seekStep);
        return KeyEventResult.handled;
      }
      if (_isLive && k == LogicalKeyboardKey.arrowUp) {
        _zap(1);
        return KeyEventResult.handled;
      }
      if (_isLive && k == LogicalKeyboardKey.arrowDown) {
        _zap(-1);
        return KeyEventResult.handled;
      }
      if (_nextUpVisible &&
          (k == LogicalKeyboardKey.select ||
              k == LogicalKeyboardKey.enter ||
              k == LogicalKeyboardKey.gameButtonA)) {
        _skip(1);
        return KeyEventResult.handled;
      }
      _showControls();
      return KeyEventResult.handled;
    }
    // Controls already visible — keep them alive, let focus traversal work.
    _resetHideTimer();
    return KeyEventResult.ignored;
  }

  bool get _nextUpVisible {
    if (_isLive || !_hasQueue || _index >= _queue.length - 1) return false;
    if (_duration.inSeconds <= 60) return false;
    final remaining = _duration - _position;
    return remaining.inSeconds > 0 && remaining.inSeconds <= 45;
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  // ---- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final favs = ref.watch(favoriteIdsProvider).valueOrNull ?? const <int>{};
    final isFav = _current.id != null && favs.contains(_current.id);
    final rdOn = ref.watch(rdEnabledProvider).valueOrNull ?? false;
    final showSpinner = _buffering && !_reconnecting && _error == null;
    final panelOpen = _panel != _Panel.none;
    final pausedPinned = !_playing && !_isLive && _error == null;

    return PopScope(
      canPop: !panelOpen && (!_controlsVisible || pausedPinned),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          PlaybackEngine.instance.pauseNow();
        } else if (panelOpen) {
          _closePanel();
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
            cursor: (_controlsVisible || panelOpen)
                ? MouseCursor.defer
                : SystemMouseCursors.none,
            onHover: (_) => _showControls(focusFirst: false),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () =>
                  _controlsVisible ? _hideControls() : _showControls(),
              child: Stack(children: [
                Center(
                  child: _error != null
                      ? _ErrorView(message: _error!, name: _current.name)
                      : Video(
                          controller: _controller,
                          controls: NoVideoControls,
                          fit: _fill ? BoxFit.cover : BoxFit.contain,
                        ),
                ),
                if (_reconnecting)
                  const ColoredBox(
                    color: Color(0x8C000000),
                    child: Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        CircularProgressIndicator(color: Colors.white),
                        SizedBox(height: 16),
                        Text('Reconnecting to live stream…',
                            style: TextStyle(
                                color: Colors.white, fontSize: 13.5)),
                      ]),
                    ),
                  )
                else if (showSpinner && !_controlsVisible)
                  const Center(
                      child: CircularProgressIndicator(color: Colors.white)),
                IgnorePointer(
                  child: AnimatedOpacity(
                    duration: Aurora.slow,
                    opacity: (!_playing && !_buffering && _error == null)
                        ? 1
                        : 0,
                    child: const ColoredBox(color: Color(0x40000000)),
                  ),
                ),
                // ---- Controls ----
                IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: ExcludeFocus(
                    excluding: !_controlsVisible || panelOpen,
                    child: AnimatedOpacity(
                      opacity: _controlsVisible ? 1 : 0,
                      duration: Aurora.normal,
                      child: _Chrome(
                        isFav: isFav,
                        rdOn: rdOn,
                        spinner: showSpinner,
                        state: this,
                      ),
                    ),
                  ),
                ),
                if (_nextUpVisible)
                  Positioned(
                    right: 28,
                    bottom: _controlsVisible ? 150 : 36,
                    child: _NextUpCard(
                      item: _queue[_index + 1],
                      secondsLeft: (_duration - _position).inSeconds,
                      focusable: _controlsVisible,
                      onPlay: () => _skip(1),
                    ),
                  ),
                if (_digits.isNotEmpty)
                  Positioned(
                    top: 40,
                    right: 40,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xD906070B),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Aurora.hairline),
                      ),
                      child: Text(_digits,
                          style: const TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 6,
                              color: Colors.white,
                              fontFeatures: [FontFeature.tabularFigures()])),
                    ),
                  ),
                if (_hasQueue)
                  AuroraSidePanel(
                    open: _panel == _Panel.queue,
                    title: _isLive ? 'Channels' : 'Episodes',
                    onClose: _closePanel,
                    child: _QueueList(
                      queue: _queue,
                      episodes: widget.playContext?.episodes,
                      currentIndex: _index,
                      isLive: _isLive,
                      onSelect: _switchTo,
                    ),
                  ),
                AuroraSidePanel(
                  open: _panel == _Panel.audio,
                  title: 'Audio',
                  onClose: _closePanel,
                  child: _TrackList(
                    options: [
                      for (final t in _player.state.tracks.audio)
                        if (t != AudioTrack.no() && t != AudioTrack.auto())
                          (
                            _trackLabel(t.title, t.language, t.id),
                            _player.state.track.audio == t,
                            () => _player.setAudioTrack(t)
                          ),
                    ],
                    onDone: _closePanel,
                  ),
                ),
                AuroraSidePanel(
                  open: _panel == _Panel.subtitles,
                  title: 'Subtitles',
                  onClose: _closePanel,
                  child: _TrackList(
                    options: [
                      (
                        'Off',
                        _player.state.track.subtitle == SubtitleTrack.no(),
                        () => _player.setSubtitleTrack(SubtitleTrack.no())
                      ),
                      for (final t in _player.state.tracks.subtitle)
                        if (t != SubtitleTrack.no() &&
                            t != SubtitleTrack.auto())
                          (
                            _trackLabel(t.title, t.language, t.id),
                            _player.state.track.subtitle == t,
                            () => _player.setSubtitleTrack(t)
                          ),
                    ],
                    onDone: _closePanel,
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  static String _trackLabel(String? title, String? language, String id) {
    final parts = [
      if (title != null && title.isNotEmpty) title,
      if (language != null && language.isNotEmpty) language.toUpperCase(),
    ];
    return parts.isEmpty ? 'Track $id' : parts.join(' · ');
  }
}

// ---------------------------------------------------------------------------
// Chrome — top bar, centre transport, bottom progress. A Stack (not a Column
// of Spacers) so the progress bar is *always* pinned to the bottom edge and
// can never be pushed off-screen.
// ---------------------------------------------------------------------------

class _Chrome extends StatelessWidget {
  const _Chrome({
    required this.isFav,
    required this.rdOn,
    required this.spinner,
    required this.state,
  });

  final bool isFav;
  final bool rdOn;
  final bool spinner;
  final _AuroraPlayerScreenState state;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xC2000000), Color(0x00000000), Color(0xD9000000)],
          stops: [0.0, 0.4, 1.0],
        ),
      ),
      child: SafeArea(
        child: Stack(children: [
          Positioned(top: 8, left: 20, right: 20, child: _topBar(context)),
          Center(child: _centreTransport()),
          Positioned(
            left: 24,
            right: 24,
            bottom: 14,
            child: state._isLive ? _LiveBanner(item: state._current) : _timeline(),
          ),
        ]),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    final (title, _, season, episode) = state._scrobbleIdentity();
    final sub = !state._isLive && season != null && episode != null
        ? 'S$season · E$episode'
        : (state._isLive ? (state._current.groupTitle ?? '') : null);

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AuroraIconButton(
        icon: Icons.arrow_back_rounded,
        tooltip: 'Back',
        onActivity: state._resetHideTimer,
        onPressed: () {
          PlaybackEngine.instance.pauseNow();
          Navigator.of(context).pop();
        },
      ),
      const SizedBox(width: 16),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Row(children: [
              if (state._isLive) ...[
                const LiveBadge(),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Text(
                  state._isLive ? state._current.name : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -0.3),
                ),
              ),
            ]),
            if (sub != null && sub.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5, color: Aurora.textDim)),
              ),
          ],
        ),
      ),
      const SizedBox(width: 12),
      // Actions hug the top-right corner: a fixed-size Row (not a Flexible that
      // would split the row's free space with the title and drift to centre).
      Row(mainAxisSize: MainAxisSize.min, children: _actions()),
    ]);
  }

  List<Widget> _actions() {
    const gap = SizedBox(width: 8);
    return [
      if (state._hasQueue) ...[
        AuroraIconButton(
          icon: state._isLive
              ? Icons.format_list_bulleted_rounded
              : Icons.video_library_outlined,
          tooltip: state._isLive ? 'Channels' : 'Episodes',
          onActivity: state._resetHideTimer,
          onPressed: () => state._openPanel(_Panel.queue),
        ),
        gap,
      ],
      if (!state._isLive) ...[
        AuroraIconButton(
          icon: Icons.speed_rounded,
          tooltip: 'Speed (${state._rate}x)',
          active: state._rate != 1.0,
          onActivity: state._resetHideTimer,
          onPressed: state._cycleRate,
        ),
        gap,
      ],
      AuroraIconButton(
        icon: state._fill ? Icons.fit_screen_rounded : Icons.aspect_ratio_rounded,
        tooltip: state._fill ? 'Fill' : 'Fit',
        active: state._fill,
        onActivity: state._resetHideTimer,
        onPressed: state._toggleFill,
      ),
      gap,
      if (!state._isLive) ...[
        AuroraIconButton(
          icon: Icons.closed_caption_outlined,
          tooltip: 'Subtitles',
          onActivity: state._resetHideTimer,
          onPressed: () => state._openPanel(_Panel.subtitles),
        ),
        gap,
      ],
      AuroraIconButton(
        icon: Icons.multitrack_audio_rounded,
        tooltip: 'Audio',
        onActivity: state._resetHideTimer,
        onPressed: () => state._openPanel(_Panel.audio),
      ),
      if (!state._isLive && rdOn) ...[
        gap,
        AuroraIconButton(
          icon: Icons.swap_horiz_rounded,
          tooltip: 'Switch source',
          onActivity: state._resetHideTimer,
          onPressed: state._pickSource,
        ),
      ],
      if (state._current.id != null) ...[
        gap,
        AuroraIconButton(
          icon: isFav
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          active: isFav,
          tooltip: isFav ? 'Remove from My List' : 'Add to My List',
          onActivity: state._resetHideTimer,
          onPressed: state._toggleFavorite,
        ),
      ],
    ];
  }

  Widget _centreTransport() {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (!state._isLive) ...[
        AuroraIconButton(
          icon: Icons.replay_30_rounded,
          size: 26,
          tooltip: 'Back 30 seconds',
          onActivity: state._resetHideTimer,
          onPressed: () => state._seekBy(-_AuroraPlayerScreenState._seekStep),
        ),
        const SizedBox(width: 34),
      ],
      AuroraIconButton(
        focusNode: state._playFocus,
        icon: state._playing
            ? Icons.pause_rounded
            : Icons.play_arrow_rounded,
        size: 42,
        tooltip: state._playing ? 'Pause' : 'Play',
        onActivity: state._resetHideTimer,
        // ◀ ▶ from the (default-focused) play button seek immediately, so the
        // user never has to hunt for the progress bar first.
        onLeft: state._isLive
            ? null
            : () => state._seekBy(-_AuroraPlayerScreenState._seekStep),
        onRight: state._isLive
            ? null
            : () => state._seekBy(_AuroraPlayerScreenState._seekStep),
        onPressed: spinner ? () {} : state._togglePlay,
      ),
      if (!state._isLive) ...[
        const SizedBox(width: 34),
        AuroraIconButton(
          icon: Icons.forward_30_rounded,
          size: 26,
          tooltip: 'Forward 30 seconds',
          onActivity: state._resetHideTimer,
          onPressed: () => state._seekBy(_AuroraPlayerScreenState._seekStep),
        ),
      ],
    ]);
  }

  Widget _timeline() {
    return _AuroraTimeline(
      position: state._position,
      duration: state._duration,
      buffered: state._buffered,
      rate: state._rate,
      previewPos: state._previewPos,
      fmt: _AuroraPlayerScreenState._fmt,
      onSeekBy: state._seekBy,
      onSeekTo: state._seekTo,
    );
  }
}

// ---------------------------------------------------------------------------
// Timeline — always visible, scrub-free. Focus it and ◀ ▶ seek ±30s (with a
// frame preview); pointer users can also tap/drag anywhere on the track.
// ---------------------------------------------------------------------------

class _AuroraTimeline extends StatelessWidget {
  const _AuroraTimeline({
    required this.position,
    required this.duration,
    required this.buffered,
    required this.rate,
    required this.previewPos,
    required this.fmt,
    required this.onSeekBy,
    required this.onSeekTo,
  });

  final Duration position;
  final Duration duration;
  final Duration buffered;
  final double rate;
  final Duration? previewPos;
  final String Function(Duration) fmt;
  final ValueChanged<int> onSeekBy;
  final ValueChanged<Duration> onSeekTo;

  double _frac(Duration d) {
    final max = duration.inMilliseconds;
    if (max <= 0) return 0;
    return (d.inMilliseconds / max).clamp(0.0, 1.0);
  }

  void _pointerTo(Offset local, double width) {
    final max = duration.inMilliseconds;
    if (max <= 0) return;
    final f = (local.dx / width).clamp(0.0, 1.0);
    onSeekTo(Duration(milliseconds: (max * f).round()));
  }

  @override
  Widget build(BuildContext context) {
    final remaining = duration - position;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Preview bubble (after a keyboard seek).
        SizedBox(
          height: previewPos != null ? 132 : 0,
          child: previewPos != null
              ? LayoutBuilder(builder: (context, box) {
                  const bw = 200.0;
                  final x = (_frac(previewPos!) * box.maxWidth - bw / 2)
                      .clamp(0.0, (box.maxWidth - bw).clamp(0.0, 1e9));
                  return Stack(children: [
                    Positioned(
                      left: x,
                      bottom: 8,
                      child: _PreviewBubble(position: previewPos!, fmt: fmt),
                    ),
                  ]);
                })
              : null,
        ),
        _FocusableTrack(
          builder: (context, focused) {
            final active = focused;
            return LayoutBuilder(builder: (context, box) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => _pointerTo(d.localPosition, box.maxWidth),
                onHorizontalDragUpdate: (d) =>
                    _pointerTo(d.localPosition, box.maxWidth),
                child: SizedBox(
                  height: 26,
                  child: Center(
                    child: AnimatedContainer(
                      duration: Aurora.fast,
                      height: active ? 9 : 5,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: const Color(0x3DFFFFFF),
                        borderRadius: BorderRadius.circular(5),
                        boxShadow: active
                            ? const [
                                BoxShadow(
                                    color: Color(0x55FFFFFF), blurRadius: 12)
                              ]
                            : null,
                      ),
                      child: Stack(children: [
                        FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: _frac(buffered),
                          child: const ColoredBox(color: Color(0x40FFFFFF)),
                        ),
                        FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: _frac(position),
                          child: const DecoratedBox(
                              decoration:
                                  BoxDecoration(gradient: Aurora.gradient)),
                        ),
                      ]),
                    ),
                  ),
                ),
              );
            });
          },
          onLeft: () => onSeekBy(-30),
          onRight: () => onSeekBy(30),
        ),
        const SizedBox(height: 7),
        Row(children: [
          Text(fmt(position),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()])),
          const SizedBox(width: 10),
          if (rate != 1.0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Aurora.hairline),
              ),
              child: Text('${rate}x',
                  style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: Aurora.textDim)),
            ),
          const Spacer(),
          Text('-${fmt(remaining < Duration.zero ? Duration.zero : remaining)}',
              style: const TextStyle(
                  color: Aurora.textDim,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ]),
      ],
    );
  }
}

/// A focus stop over the progress track. ◀ ▶ seek; it never "enters" a mode —
/// the arrows act immediately, matching the "no click" ask.
class _FocusableTrack extends StatefulWidget {
  const _FocusableTrack({
    required this.builder,
    required this.onLeft,
    required this.onRight,
  });
  final Widget Function(BuildContext, bool focused) builder;
  final VoidCallback onLeft;
  final VoidCallback onRight;

  @override
  State<_FocusableTrack> createState() => _FocusableTrackState();
}

class _FocusableTrackState extends State<_FocusableTrack> {
  final FocusNode _node = FocusNode(debugLabel: 'aurora-track');
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(() {
      if (mounted) setState(() => _focused = _node.hasFocus);
    });
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      widget.onLeft();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
      widget.onRight();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored; // up/down leave the track
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      onKeyEvent: _onKey,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: widget.builder(context, _focused),
      ),
    );
  }
}

/// Timestamp + frame preview (once background grabs exist) above the thumb.
class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({required this.position, required this.fmt});
  final Duration position;
  final String Function(Duration) fmt;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: ScrubThumbs.instance.thumbs,
      builder: (context, _, __) {
        final frame = ScrubThumbs.instance.nearest(position);
        return Container(
          width: 200,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: const Color(0xF20C0E15),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x66FFFFFF)),
            boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 22)],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (frame != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: Image.memory(frame,
                    width: 188,
                    height: 104,
                    fit: BoxFit.cover,
                    gaplessPlayback: true),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(fmt(position),
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
          ]),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Live banner — channel identity + EPG now/next
// ---------------------------------------------------------------------------

class _LiveBanner extends ConsumerWidget {
  const _LiveBanner({required this.item});
  final StreamItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xB30A0C12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Aurora.hairline),
      ),
      child: Row(children: [
        AuroraLogoTile(
            url: item.logo,
            width: 86,
            height: 52,
            radius: 10,
            fallbackText: item.name),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                if (item.num != null) ...[
                  Text('${item.num}',
                      style: const TextStyle(
                          color: Aurora.accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: Colors.white)),
                ),
              ]),
              const SizedBox(height: 4),
              if (item.tvgId != null && item.tvgId!.isNotEmpty)
                _EpgNow(tvgId: item.tvgId!)
              else
                Text(item.groupTitle ?? 'Live broadcast',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5, color: Aurora.textDim)),
              const SizedBox(height: 2),
              const Text('CH− / CH+ or ▲ ▼ to zap · type a channel number',
                  style: TextStyle(fontSize: 10.5, color: Aurora.textFaint)),
            ],
          ),
        ),
      ]),
    );
  }
}

class _EpgNow extends ConsumerStatefulWidget {
  const _EpgNow({required this.tvgId});
  final String tvgId;

  @override
  ConsumerState<_EpgNow> createState() => _EpgNowState();
}

class _EpgNowState extends ConsumerState<_EpgNow> {
  late Future<EpgEntry?> _future = _lookup();

  Future<EpgEntry?> _lookup() => ref
      .read(repositoryProvider.future)
      .then((repo) => repo.nowPlaying(widget.tvgId));

  @override
  void didUpdateWidget(covariant _EpgNow old) {
    super.didUpdateWidget(old);
    if (old.tvgId != widget.tvgId) _future = _lookup();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EpgEntry?>(
      future: _future,
      builder: (context, snap) {
        final e = snap.data;
        if (e == null) {
          return const Text('Live broadcast',
              style: TextStyle(fontSize: 12.5, color: Aurora.textDim));
        }
        final progress = e.progress(DateTime.now().millisecondsSinceEpoch);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(e.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: Aurora.text)),
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 3,
                width: 240,
                child: Stack(children: [
                  Container(color: const Color(0x33FFFFFF)),
                  FractionallySizedBox(
                    widthFactor: progress.clamp(0.0, 1.0),
                    child: Container(color: Aurora.live),
                  ),
                ]),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Next-up countdown card
// ---------------------------------------------------------------------------

class _NextUpCard extends StatelessWidget {
  const _NextUpCard({
    required this.item,
    required this.secondsLeft,
    required this.focusable,
    required this.onPlay,
  });

  final StreamItem item;
  final int secondsLeft;
  final bool focusable;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      width: 292,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xE60C0E15),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Aurora.hairline),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 24)],
      ),
      child: Row(children: [
        AuroraImage(
            url: item.logo,
            width: 96,
            height: 54,
            radius: 9,
            fallbackText: item.name),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Next · in ${secondsLeft}s',
                  style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      color: Aurora.accent)),
              const SizedBox(height: 3),
              Text(cleanTitle(item.name).title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ],
          ),
        ),
        const Icon(Icons.play_arrow_rounded, color: Colors.white),
      ]),
    );

    if (!focusable) return card;
    return _NextUpFocus(onActivate: onPlay, child: card);
  }
}

class _NextUpFocus extends StatefulWidget {
  const _NextUpFocus({required this.onActivate, required this.child});
  final VoidCallback onActivate;
  final Widget child;

  @override
  State<_NextUpFocus> createState() => _NextUpFocusState();
}

class _NextUpFocusState extends State<_NextUpFocus> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onActivate();
          return null;
        }),
      },
      child: GestureDetector(
        onTap: widget.onActivate,
        child: AnimatedScale(
          scale: _focused ? 1.05 : 1.0,
          duration: Aurora.fast,
          child: widget.child,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Queue (episodes / channels) panel
// ---------------------------------------------------------------------------

class _QueueList extends StatefulWidget {
  const _QueueList({
    required this.queue,
    required this.episodes,
    required this.currentIndex,
    required this.isLive,
    required this.onSelect,
  });

  final List<StreamItem> queue;
  final List<(int, int)>? episodes;
  final int currentIndex;
  final bool isLive;
  final ValueChanged<int> onSelect;

  @override
  State<_QueueList> createState() => _QueueListState();
}

class _QueueListState extends State<_QueueList> {
  late final ScrollController _controller =
      ScrollController(initialScrollOffset: () {
    final startAt = _entries().indexOf(widget.currentIndex);
    return startAt <= 2 ? 0.0 : (startAt - 2) * 64.0;
  }());

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int? _seasonOf(int i) =>
      (widget.episodes != null && i < widget.episodes!.length)
          ? widget.episodes![i].$1
          : null;

  List<int> _entries() {
    if (widget.episodes == null) {
      return [for (var i = 0; i < widget.queue.length; i++) i];
    }
    final out = <int>[];
    int? last;
    for (var i = 0; i < widget.queue.length; i++) {
      final s = _seasonOf(i);
      if (s != null && s != last) {
        out.add(-(s + 1));
        last = s;
      }
      out.add(i);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries();
    return ListView.builder(
      controller: _controller,
      padding: const EdgeInsets.only(bottom: 14),
      itemCount: entries.length,
      itemBuilder: (context, n) {
        final e = entries[n];
        if (e < 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(22, 16, 22, 6),
            child: Text('SEASON ${-e - 1}',
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                    color: Aurora.textFaint)),
          );
        }
        final it = widget.queue[e];
        final current = e == widget.currentIndex;
        return AuroraOptionRow(
          label: widget.isLive
              ? '${it.num != null ? '${it.num}  ' : ''}${it.name}'
              : cleanTitle(it.name).title,
          sublabel: current ? 'Now playing' : null,
          selected: current,
          autofocus: current,
          onSelect: () => widget.onSelect(e),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Track panel
// ---------------------------------------------------------------------------

class _TrackList extends StatelessWidget {
  const _TrackList({required this.options, required this.onDone});
  final List<(String, bool, VoidCallback)> options;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child:
            Text('No tracks available.', style: TextStyle(color: Aurora.textDim)),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 14),
      children: [
        for (final (label, selected, apply) in options)
          AuroraOptionRow(
            label: label,
            selected: selected,
            autofocus: selected,
            onSelect: () {
              apply();
              onDone();
            },
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Error view
// ---------------------------------------------------------------------------

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.name});
  final String message;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(30),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline_rounded, color: Aurora.live, size: 46),
        const SizedBox(height: 16),
        Text('Couldn\'t play "$name"',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 16)),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Aurora.textDim, fontSize: 12)),
        ),
      ]),
    );
  }
}
