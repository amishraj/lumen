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

/// Structured identity of what's playing (for scrobbling + Real-Debrid).
/// [episodes] holds (season, episode) per queue index for series.
class AuroraPlayContext {
  const AuroraPlayContext({
    required this.title,
    this.isShow = false,
    this.episodes,
  });
  final String title;
  final bool isShow;
  final List<(int, int)>? episodes;
}

enum _Panel { none, queue, audio, subtitles }

/// Aurora's full-screen player. The playback core is a straight port of the
/// battle-tested 1.0 pipeline — the app-lifetime libmpv engine, verified
/// stop, live reconnect with backoff, 5s progress persistence, Trakt
/// scrobbling, English-audio auto-pick, background scrub previews — under a
/// completely new control surface:
///
/// - Netflix-style timeline with buffered range + frame-preview scrubbing
/// - next-episode countdown card in the final 45 seconds
/// - playback speed + aspect toggles
/// - live TV: channel banner with EPG now/next, up/down zapping from the
///   channel keys, and direct number entry
/// - remote media keys (play/pause, FF/RW, next/prev) work everywhere
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
  /// cross-device resume decide, as in 1.0.
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
  BoxFit _fit = BoxFit.contain;

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
    // Every listener is stored and cancelled in dispose — the global player
    // outlives this screen, so an unstored listener would fire forever.
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

  /// Tune libmpv for flaky/slow IPTV networks: big caches, safe hardware
  /// decode, FFmpeg-level auto-reconnect on dropped sockets. Identical to the
  /// proven 1.0 configuration.
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
    });
    await _load();
    // A per-title speed choice never carries over to the next item.
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
      // Live: keep trying. VOD: surface the error.
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
    // Resume priority: explicit request from the caller (detail screen /
    // "from beginning"), else Trakt's cross-device position.
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

  /// Live streams have no real end — if the server closes the socket,
  /// reconnect with backoff instead of sitting paused. VOD auto-advances.
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

    // Background scrub previews — start well after playback settles so the
    // secondary connection never competes with initial buffering.
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
    // Persist progress every ~5s (never per position tick).
    if (_current.id != null &&
        (pos.inMilliseconds - _lastSavedPosMs).abs() >= 5000) {
      _lastSavedPosMs = pos.inMilliseconds;
      final repo = ref.read(repositoryProvider).valueOrNull;
      unawaited(repo?.db
          .saveProgress(_current.id!, pos.inMilliseconds, dur.inMilliseconds));
    }
  }

  // ---- Trakt scrobbling (start / pause / stop with exact position) --------

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
    for (final s in _subs) {
      s.cancel();
    }
    _rootFocus.dispose();
    _playFocus.dispose();
    if (_active == this) _active = null;
    ScrubThumbs.instance.cancel();
    // Stop the shared pipeline — verified & retried inside the engine.
    unawaited(PlaybackEngine.instance.stopPlayback());
    super.dispose();
  }

  // ---- Controls visibility --------------------------------------------------

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
    // Never auto-hide while paused — a paused player with no chrome reads
    // as frozen (a 1.0 paper-cut this redesign fixes).
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

  // ---- Playback actions -----------------------------------------------------

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
    _resetHideTimer();
  }

  void _cycleRate() {
    const rates = [1.0, 1.25, 1.5, 2.0];
    final next = rates[(rates.indexOf(_rate) + 1) % rates.length];
    setState(() => _rate = next);
    unawaited(_player.setRate(next));
    _resetHideTimer();
  }

  void _cycleFit() {
    setState(() {
      _fit = switch (_fit) {
        BoxFit.contain => BoxFit.cover,
        BoxFit.cover => BoxFit.fill,
        _ => BoxFit.contain,
      };
    });
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
    final picked = await showAuroraSourceSheet(
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
    _sought = true; // suppress auto-resume; we restore manually
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

  // ---- Live zapping ----------------------------------------------------------

  void _zap(int delta) {
    if (!_isLive || !_hasQueue) return;
    final next = (_index + delta) % _queue.length;
    _openAt(next < 0 ? _queue.length - 1 : next);
    _showControls(focusFirst: false);
  }

  void _onDigit(String d) {
    if (!_isLive) return;
    _digitTimer?.cancel();
    setState(() => _digits = (_digits + d).substring(
        0, (_digits.length + 1).clamp(0, 4)));
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

  // ---- Root key handling ------------------------------------------------------

  KeyEventResult _onRootKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;

    // Media keys work regardless of chrome state.
    if (k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.mediaPlay ||
        k == LogicalKeyboardKey.mediaPause) {
      _togglePlay();
      _showControls(focusFirst: false);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaFastForward) {
      _seekBy(30);
      _showControls(focusFirst: false);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaRewind) {
      _seekBy(-30);
      _showControls(focusFirst: false);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaTrackNext) {
      _skip(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaTrackPrevious) {
      _skip(-1);
      return KeyEventResult.handled;
    }
    // Channel zapping + number entry (live).
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
        return KeyEventResult.handled;
      }
    }

    if (!_wakeKeys.contains(k)) return KeyEventResult.ignored;

    if (!_controlsVisible) {
      // Chrome hidden: give the arrows immediate meaning before waking it.
      if (!_isLive && k == LogicalKeyboardKey.arrowLeft) {
        _seekBy(-10);
        _showControls(focusFirst: false);
        return KeyEventResult.handled;
      }
      if (!_isLive && k == LogicalKeyboardKey.arrowRight) {
        _seekBy(10);
        _showControls(focusFirst: false);
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
      if (k == LogicalKeyboardKey.arrowDown && _hasQueue) {
        _openPanel(_Panel.queue);
        return KeyEventResult.handled;
      }
      // Next-up shortcut: OK while the countdown card shows plays it now.
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

  // ---- Build ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final favs = ref.watch(favoriteIdsProvider).valueOrNull ?? const <int>{};
    final isFav = _current.id != null && favs.contains(_current.id);
    final rdOn = ref.watch(rdEnabledProvider).valueOrNull ?? false;
    final showSpinner = _buffering && !_reconnecting && _error == null;
    final panelOpen = _panel != _Panel.none;

    // While paused the chrome is pinned (never auto-hides), so Back must
    // exit directly instead of trying to dismiss it — otherwise a paused
    // player traps the user.
    final pausedPinned = !_playing && !_isLive && _error == null;
    return PopScope(
      canPop: !panelOpen && (!_controlsVisible || pausedPinned),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          // Real back: silence instantly, don't wait for the command queue.
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
                // ---- Video ----
                Center(
                  child: _error != null
                      ? _ErrorView(message: _error!, name: _current.name)
                      : Video(
                          controller: _controller,
                          controls: NoVideoControls,
                          fit: _fit,
                        ),
                ),
                // ---- Reconnect / buffering feedback ----
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
                // ---- Paused dim (calm, movie-poster feel) ----
                IgnorePointer(
                  child: AnimatedOpacity(
                    duration: Aurora.slow,
                    opacity: (!_playing && !_buffering && _error == null)
                        ? 1
                        : 0,
                    child: const ColoredBox(color: Color(0x59000000)),
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
                      child: _buildControls(
                          isFav: isFav, rdOn: rdOn, spinner: showSpinner),
                    ),
                  ),
                ),
                // ---- Next-episode countdown card ----
                if (_nextUpVisible)
                  Positioned(
                    right: 28,
                    bottom: _controlsVisible ? 148 : 36,
                    child: _NextUpCard(
                      item: _queue[_index + 1],
                      secondsLeft: (_duration - _position).inSeconds,
                      focusable: _controlsVisible,
                      onPlay: () => _skip(1),
                    ),
                  ),
                // ---- Live number-entry HUD ----
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
                              fontFeatures: [
                                FontFeature.tabularFigures()
                              ])),
                    ),
                  ),
                // ---- Panels ----
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

  Widget _buildControls(
      {required bool isFav, required bool rdOn, required bool spinner}) {
    final (title, _, season, episode) = _scrobbleIdentity();
    final sub = !_isLive && season != null && episode != null
        ? 'S$season · E$episode'
        : (_isLive ? (_current.groupTitle ?? '') : null);

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xB3000000),
            Color(0x14000000),
            Color(0xCC000000),
          ],
          stops: [0.0, 0.45, 1.0],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
          child: Column(children: [
            // ---- Top row: back · title · actions ----
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AuroraIconButton(
                icon: Icons.arrow_back_rounded,
                tooltip: 'Back',
                onActivity: _resetHideTimer,
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
                    const SizedBox(height: 2),
                    Row(children: [
                      if (_isLive) ...[
                        const LiveBadge(),
                        const SizedBox(width: 10),
                      ],
                      Flexible(
                        child: Text(
                          _isLive ? _current.name : title,
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
              // Actions — Flexible so a narrow (portrait phone) player wraps
              // to a second row instead of overflowing.
              Flexible(
                  child:
                      Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end, children: [
                if (_hasQueue)
                  AuroraIconButton(
                    icon: _isLive
                        ? Icons.format_list_bulleted_rounded
                        : Icons.video_library_outlined,
                    tooltip: _isLive ? 'Channels' : 'Episodes',
                    onActivity: _resetHideTimer,
                    onPressed: () => _openPanel(_Panel.queue),
                  ),
                if (!_isLive)
                  AuroraIconButton(
                    icon: Icons.speed_rounded,
                    tooltip: 'Speed (${_rate}x)',
                    active: _rate != 1.0,
                    onActivity: _resetHideTimer,
                    onPressed: _cycleRate,
                  ),
                AuroraIconButton(
                  icon: switch (_fit) {
                    BoxFit.cover => Icons.crop_free_rounded,
                    BoxFit.fill => Icons.fit_screen_rounded,
                    _ => Icons.aspect_ratio_rounded,
                  },
                  tooltip: 'Aspect',
                  active: _fit != BoxFit.contain,
                  onActivity: _resetHideTimer,
                  onPressed: _cycleFit,
                ),
                if (!_isLive)
                  AuroraIconButton(
                    icon: Icons.closed_caption_outlined,
                    tooltip: 'Subtitles',
                    onActivity: _resetHideTimer,
                    onPressed: () => _openPanel(_Panel.subtitles),
                  ),
                AuroraIconButton(
                  icon: Icons.multitrack_audio_rounded,
                  tooltip: 'Audio',
                  onActivity: _resetHideTimer,
                  onPressed: () => _openPanel(_Panel.audio),
                ),
                if (!_isLive && rdOn)
                  AuroraIconButton(
                    icon: Icons.swap_horiz_rounded,
                    tooltip: 'Source',
                    onActivity: _resetHideTimer,
                    onPressed: _pickSource,
                  ),
                if (_current.id != null)
                  AuroraIconButton(
                    icon: isFav
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    active: isFav,
                    tooltip:
                        isFav ? 'Remove from My List' : 'Add to My List',
                    onActivity: _resetHideTimer,
                    onPressed: _toggleFavorite,
                  ),
              ])),
            ]),
            const Spacer(),
            // ---- Center transport ----
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (!_isLive) ...[
                AuroraIconButton(
                  icon: Icons.replay_10_rounded,
                  size: 26,
                  tooltip: 'Back 10 seconds',
                  onActivity: _resetHideTimer,
                  onPressed: () => _seekBy(-10),
                ),
                const SizedBox(width: 34),
              ],
              _BigPlayButton(
                focusNode: _playFocus,
                playing: _playing,
                spinner: spinner,
                onActivity: _resetHideTimer,
                onPressed: spinner ? () {} : _togglePlay,
              ),
              if (!_isLive) ...[
                const SizedBox(width: 34),
                AuroraIconButton(
                  icon: Icons.forward_10_rounded,
                  size: 26,
                  tooltip: 'Forward 10 seconds',
                  onActivity: _resetHideTimer,
                  onPressed: () => _seekBy(10),
                ),
              ],
            ]),
            const Spacer(),
            // ---- Bottom cluster ----
            if (_isLive)
              _LiveBanner(item: _current)
            else
              _AuroraTimeline(
                position: _position,
                duration: _duration,
                buffered: _buffered,
                rate: _rate,
                fmt: _fmt,
                onSeek: (d) {
                  _player.seek(d);
                  setState(() => _position = d);
                  _resetHideTimer();
                },
                onScrubStart: () => _hideTimer?.cancel(),
                onScrubEnd: _resetHideTimer,
              ),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Big play/pause
// ---------------------------------------------------------------------------

class _BigPlayButton extends StatelessWidget {
  const _BigPlayButton({
    required this.playing,
    required this.spinner,
    required this.onPressed,
    required this.onActivity,
    this.focusNode,
  });

  final bool playing;
  final bool spinner;
  final VoidCallback onPressed;
  final VoidCallback onActivity;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return AuroraIconButton(
      focusNode: focusNode,
      icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
      size: 42,
      tooltip: playing ? 'Pause' : 'Play',
      onActivity: onActivity,
      onPressed: onPressed,
    );
  }
}

// ---------------------------------------------------------------------------
// Timeline — buffered range, focus-to-scrub with acceleration + previews
// ---------------------------------------------------------------------------

class _AuroraTimeline extends StatefulWidget {
  const _AuroraTimeline({
    required this.position,
    required this.duration,
    required this.buffered,
    required this.rate,
    required this.onSeek,
    required this.fmt,
    this.onScrubStart,
    this.onScrubEnd,
  });

  final Duration position;
  final Duration duration;
  final Duration buffered;
  final double rate;
  final ValueChanged<Duration> onSeek;
  final String Function(Duration) fmt;
  final VoidCallback? onScrubStart;
  final VoidCallback? onScrubEnd;

  @override
  State<_AuroraTimeline> createState() => _AuroraTimelineState();
}

class _AuroraTimelineState extends State<_AuroraTimeline> {
  final FocusNode _focus = FocusNode(debugLabel: 'aurora-timeline');
  bool _focused = false;
  bool _scrubbing = false;
  Duration _scrubPos = Duration.zero;
  int _streak = 0;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() => _focused = _focus.hasFocus);
      if (!_focus.hasFocus && _scrubbing) _endScrub(commit: false);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _startScrub() {
    setState(() {
      _scrubbing = true;
      _scrubPos = widget.position;
      _streak = 0;
    });
    widget.onScrubStart?.call();
  }

  void _endScrub({required bool commit}) {
    if (commit) widget.onSeek(_scrubPos);
    if (mounted) setState(() => _scrubbing = false);
    widget.onScrubEnd?.call();
  }

  /// Slow-then-fast: first presses nudge 5s for precision; a held key ramps
  /// through 15s/30s to 60s jumps.
  int get _stepSecs {
    if (_streak < 4) return 5;
    if (_streak < 12) return 15;
    if (_streak < 24) return 30;
    return 60;
  }

  void _nudge(int direction) {
    _streak++;
    var t = _scrubPos + Duration(seconds: _stepSecs * direction);
    if (t < Duration.zero) t = Duration.zero;
    if (t > widget.duration) t = widget.duration;
    setState(() => _scrubPos = t);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyUpEvent) {
      _streak = 0;
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final isSelect = key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.gameButtonA;
    if (!_scrubbing) {
      if (isSelect) {
        _startScrub();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _nudge(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _nudge(1);
      return KeyEventResult.handled;
    }
    if (isSelect) {
      _endScrub(commit: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      _endScrub(commit: false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled; // swallow up/down while scrubbing
  }

  double _frac(Duration d) {
    final max = widget.duration.inMilliseconds;
    if (max <= 0) return 0;
    return (d.inMilliseconds / max).clamp(0.0, 1.0);
  }

  double get _fraction => _frac(_scrubbing ? _scrubPos : widget.position);

  void _pointerTo(Offset local, double width, {required bool commit}) {
    final max = widget.duration.inMilliseconds;
    if (max <= 0) return;
    final f = (local.dx / width).clamp(0.0, 1.0);
    final t = Duration(milliseconds: (max * f).round());
    if (commit) {
      widget.onSeek(t);
      if (_scrubbing) _endScrub(commit: false);
    } else {
      if (!_scrubbing) _startScrub();
      setState(() => _scrubPos = t);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _focused || _scrubbing;
    final showPos = _scrubbing ? _scrubPos : widget.position;
    final remaining = widget.duration - showPos;

    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Preview bubble while scrubbing.
          SizedBox(
            height: _scrubbing ? 138 : 0,
            child: _scrubbing
                ? LayoutBuilder(builder: (context, box) {
                    const bw = 200.0;
                    final x = (_fraction * box.maxWidth - bw / 2)
                        .clamp(0.0, (box.maxWidth - bw).clamp(0.0, 1e9));
                    return Stack(children: [
                      Positioned(
                        left: x,
                        bottom: 10,
                        child: _PreviewBubble(
                            position: _scrubPos, fmt: widget.fmt),
                      ),
                    ]);
                  })
                : null,
          ),
          LayoutBuilder(builder: (context, box) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) =>
                  _pointerTo(d.localPosition, box.maxWidth, commit: true),
              onHorizontalDragUpdate: (d) =>
                  _pointerTo(d.localPosition, box.maxWidth, commit: false),
              onHorizontalDragEnd: (_) => _endScrub(commit: true),
              child: SizedBox(
                height: 26,
                child: Center(
                  child: AnimatedContainer(
                    duration: Aurora.fast,
                    height: active ? 8 : 4.5,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: const Color(0x30FFFFFF),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Stack(children: [
                      // Buffered range.
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: _frac(widget.buffered),
                        child:
                            const ColoredBox(color: Color(0x38FFFFFF)),
                      ),
                      // Played range.
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: _fraction,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            boxShadow: active
                                ? const [
                                    BoxShadow(
                                        color: Color(0x66FFFFFF),
                                        blurRadius: 12),
                                  ]
                                : null,
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: 6),
          Row(children: [
            Text(widget.fmt(showPos),
                style: TextStyle(
                    color: _scrubbing ? Colors.white : Aurora.textDim,
                    fontWeight:
                        _scrubbing ? FontWeight.w800 : FontWeight.w600,
                    fontSize: 12.5,
                    fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(width: 10),
            if (widget.rate != 1.0)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Aurora.hairline),
                ),
                child: Text('${widget.rate}x',
                    style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: Aurora.textDim)),
              ),
            const Spacer(),
            AnimatedOpacity(
              opacity: _focused && !_scrubbing ? 1 : 0,
              duration: Aurora.fast,
              child: const Text('OK to scrub · hold ◀ ▶ to speed up',
                  style: TextStyle(color: Aurora.textFaint, fontSize: 11)),
            ),
            const Spacer(),
            Text('-${widget.fmt(remaining < Duration.zero ? Duration.zero : remaining)}',
                style: const TextStyle(
                    color: Aurora.textDim,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ]),
        ],
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
            boxShadow: const [
              BoxShadow(color: Colors.black87, blurRadius: 22)
            ],
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
  // Cached — the surrounding controls rebuild on every position tick, and a
  // fresh future per build would hammer the DB several times a second.
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
        final progress =
            e.progress(DateTime.now().millisecondsSinceEpoch);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(e.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 12.5, color: Aurora.text)),
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
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 24),
        ],
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
    return AuroraFocusableShim(onActivate: onPlay, child: card);
  }
}

/// Minimal focus wrapper for the next-up card (a full ring would fight the
/// card's own border).
class AuroraFocusableShim extends StatefulWidget {
  const AuroraFocusableShim(
      {super.key, required this.onActivate, required this.child});
  final VoidCallback onActivate;
  final Widget child;

  @override
  State<AuroraFocusableShim> createState() => _AuroraFocusableShimState();
}

class _AuroraFocusableShimState extends State<AuroraFocusableShim> {
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
// Queue (episodes / channels) panel content
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

  /// Queue indexes + season-header markers (negative encodings: -(season+1)).
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
// Track panel content
// ---------------------------------------------------------------------------

class _TrackList extends StatelessWidget {
  const _TrackList({required this.options, required this.onDone});

  /// (label, selected, apply)
  final List<(String, bool, VoidCallback)> options;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('No tracks available.',
            style: TextStyle(color: Aurora.textDim)),
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
        const Icon(Icons.error_outline_rounded,
            color: Aurora.live, size: 46),
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
