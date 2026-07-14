import 'dart:async';

import 'package:flutter/foundation.dart'
    show ValueListenable, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../../data/models/models.dart';
import '../../data/sources/opensubtitles_service.dart';
import '../../data/sources/realdebrid_service.dart';
import '../../data/sources/trakt_service.dart';
import '../../state/live_quality.dart';
import '../../state/playback_engine.dart';
import '../../state/providers.dart';
import '../../state/scrub_thumbs.dart';
import '../../ui/title_utils.dart';
import '../aurora_focus.dart';
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
    this.overviews,
    this.iptvUrl,
  });
  final String title;
  final bool isShow;
  final List<(int, int)>? episodes;

  /// Short synopsis per queue index (aligned with [episodes]) — shown in the
  /// player's Episodes panel so the user can tell where they are in a season.
  final List<String?>? overviews;
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
  StreamItem get _current => _liveVariant[_index] ?? _queue[_index];
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
  bool _fetchingSubs = false; // OpenSubtitles online fetch in flight

  // Brief seek preview (position bubble) shown for ~1.1s after a ◀ ▶ seek.
  Duration? _previewPos;
  Timer? _previewTimer;

  // YouTube-style ±30s directional flash that fades in/out on a keyboard seek.
  int _seekFlashDir = 0; // -1 back, +1 forward
  bool _seekFlashOn = false;
  Timer? _seekFlashTimer;

  // Live number entry.
  String _digits = '';
  Timer? _digitTimer;

  // ---- Mobile-only: brightness control + screen lock (Netflix-style) ------
  /// Touch phone/tablet layout: the only place the brightness rail and lock
  /// live. TV boxes are Android too but never compact, so they're excluded.
  bool _phoneUi(BuildContext context) =>
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) &&
      Aurora.isCompact(context);

  /// Notifier, not setState: a drag fires dozens of updates a second and only
  /// the rail may rebuild — never the whole player Stack.
  final ValueNotifier<double> _brightness = ValueNotifier(1.0);
  bool _brightnessTouched = false; // reset app brightness on exit only if set
  bool _locked = false;
  bool _unlockHintOn = false;
  Timer? _unlockHintTimer;

  Future<void> _setBrightness(double v) async {
    final nv = v.clamp(0.0, 1.0);
    _brightness.value = nv;
    _brightnessTouched = true;
    try {
      await ScreenBrightness.instance.setApplicationScreenBrightness(nv);
    } catch (_) {/* platform without brightness control */}
  }

  void _lockScreen() {
    _hideTimer?.cancel();
    setState(() {
      _locked = true;
      _panel = _Panel.none;
      _controlsVisible = false;
    });
    _pokeUnlockHint();
  }

  void _unlock() {
    setState(() => _locked = false);
    _unlockHintTimer?.cancel();
    _unlockHintOn = false;
    _showControls(focusFirst: false);
  }

  /// While locked, any tap/key briefly reveals the unlock pill — everything
  /// else is ignored, exactly like Netflix's lock.
  void _pokeUnlockHint() {
    setState(() => _unlockHintOn = true);
    _unlockHintTimer?.cancel();
    _unlockHintTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _unlockHintOn = false);
    });
  }

  // Live auto quality fallback — a fixed-bitrate feed on a connection slower
  // than its bitrate stalls forever, so on sustained stalling we swap to a
  // lower-quality variant of the same channel from the playlist (if one
  // exists). Sticky per queue index for the session.
  final Map<int, StreamItem> _liveVariant = {};
  final List<DateTime> _liveStallStarts = [];
  final Set<String> _noVariantFor = {}; // base names with nothing lighter
  bool _livePlayedOnce = false;
  bool _downgrading = false;
  Timer? _longStallTimer;
  String? _qualityNotice;
  Timer? _qualityNoticeTimer;

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
      _onLiveBuffering(b);
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
    _subs.add(_player.stream.tracks.listen((t) {
      _maybePickEnglishAudio(t.audio);
      _maybePickEnglishSubtitle(t.subtitle);
    }));
    _init();
    _resetHideTimer();
    // Seed the brightness rail with the device's current level (phones only —
    // harmless no-op elsewhere, the rail simply never shows).
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      ScreenBrightness.instance.application.then((v) {
        if (mounted) _brightness.value = v.clamp(0.0, 1.0);
      }).catchError((_) {});
    }
  }

  bool _autoAudioPicked = false;
  bool _autoSubPicked = false;

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

  /// Turn on an embedded English subtitle track by default when one is present
  /// (matched by language code or a title like "English"). One-shot per title;
  /// the user can still change or turn subs off from the Subtitles panel.
  void _maybePickEnglishSubtitle(List<SubtitleTrack> tracks) {
    if (!_ownsPlayback || _autoSubPicked || _isLive) return;
    bool isEnglish(SubtitleTrack t) {
      final lang = (t.language ?? '').toLowerCase();
      final title = (t.title ?? '').toLowerCase();
      return lang.startsWith('en') || title.contains('english');
    }

    final en = tracks.firstWhere(
      (t) =>
          t != SubtitleTrack.no() && t != SubtitleTrack.auto() && isEnglish(t),
      orElse: () => SubtitleTrack.no(),
    );
    if (en != SubtitleTrack.no()) {
      _autoSubPicked = true;
      _player.setSubtitleTrack(en);
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

    if (_isLive) {
      // Live: lock onto the stream sooner. IPTV is simple MPEG-TS, so a shorter
      // analyze window + smaller probe finds the tracks quickly instead of
      // waiting out ffmpeg's ~5s/5MB defaults — and start playing on the first
      // frame rather than filling the whole cache first. Decode quality is
      // untouched (same bitrate/resolution/codec); this only affects how fast
      // playback *begins*, while the 30s cache above keeps it smooth after.
      await set('demuxer-lavf-analyzeduration', '2');
      await set('demuxer-lavf-probesize', '2500000'); // ~2.5 MB
      await set('cache-pause-initial', 'no');
    }
  }

  /// Per-queue-index URL overrides from the in-player source switch.
  final Map<int, String> _urlOverrides = {};

  Future<void> _openAt(int i) async {
    _livePlayedOnce = false;
    _liveStallStarts.clear();
    _longStallTimer?.cancel();
    // Episode change: re-read the tiny per-episode progress table so the
    // Episodes panel's watched/season checks include what just finished.
    ref.invalidate(episodeProgressProvider);
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
      _autoSubPicked = false;
      _thumbsScheduled = false;
      _buffered = Duration.zero;
      _position = Duration.zero;
      _duration = Duration.zero;
      _previewPos = null;
    });
    // Series episodes prefer a smart Real-Debrid stream by default (like
    // movies) — resolved per episode so skips get it too, capped so a slow
    // lookup falls back to the IPTV episode url quickly.
    await _maybeResolveDebrid();
    await _load();
    if (_rate != 1.0) {
      if (mounted) setState(() => _rate = 1.0);
      unawaited(_player.setRate(1.0));
    }
  }

  Future<void> _maybeResolveDebrid() async {
    final ctx = widget.playContext;
    if (_isLive || ctx?.episodes == null) return; // only series episodes
    if (_urlOverrides.containsKey(_index)) return; // already chosen a source
    bool rdOn;
    try {
      rdOn = await ref.read(rdEnabledProvider.future);
    } catch (_) {
      return;
    }
    if (!rdOn) return;
    final se = _index < ctx!.episodes!.length ? ctx.episodes![_index] : null;
    if (se == null) return;
    try {
      final imdb = await imdbIdForTitle(ref, ctx.title, isShow: true);
      if (imdb == null) return;
      final svc = await ref.read(realDebridServiceProvider.future);
      final best = await svc
          .bestStream(imdb, season: se.$1, episode: se.$2)
          .timeout(const Duration(seconds: 8));
      if (best != null && mounted) _urlOverrides[_index] = best.url;
    } catch (_) {/* fall back to the IPTV episode url */}
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
    // Local per-episode resume first (works offline, no Trakt needed).
    final ek = _episodeKey();
    if (ek != null) {
      final all =
          await ref.read(repositoryProvider).valueOrNull?.db.episodeProgressAll();
      final ep = all?[ek];
      if (ep != null && ep.fraction > 0.02 && ep.fraction < 0.97) {
        _resume = ep.fraction;
        return;
      }
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

  // ---- Live auto quality fallback ------------------------------------------

  /// A live feed is one fixed bitrate — when the connection is slower than
  /// that bitrate, mpv stalls over and over no matter how big the cache is.
  /// Watch for the pattern (3 stalls inside 60s of playback, or one stall
  /// lasting 10s+) and fall back to a lower-quality variant of the channel.
  void _onLiveBuffering(bool buffering) {
    if (!_ownsPlayback || !_isLive || _reconnecting || _error != null) return;
    if (!buffering) {
      _livePlayedOnce = true;
      _longStallTimer?.cancel();
      return;
    }
    if (!_livePlayedOnce) return; // initial spin-up, not a mid-play stall
    final now = DateTime.now();
    _liveStallStarts
      ..add(now)
      ..removeWhere((t) => now.difference(t) > const Duration(seconds: 60));
    _longStallTimer?.cancel();
    _longStallTimer =
        Timer(const Duration(seconds: 10), _maybeDowngradeLiveQuality);
    if (_liveStallStarts.length >= 3) _maybeDowngradeLiveQuality();
  }

  Future<void> _maybeDowngradeLiveQuality() async {
    if (_downgrading || !mounted || !_ownsPlayback || !_isLive) return;
    final cur = _current;
    final base = liveBaseName(cur.name);
    if (base.isEmpty || _noVariantFor.contains(base)) return;
    _downgrading = true;
    try {
      final repo = ref.read(repositoryProvider).valueOrNull;
      if (repo == null) return;
      // All same-name channels in the playlist — the quality variants.
      final siblings = await repo.db.search(
        playlistId: cur.playlistId,
        kind: StreamKind.live,
        query: base,
        limit: 100,
      );
      final next = pickLowerQualityVariant(cur, siblings);
      if (next == null) {
        _noVariantFor.add(base); // don't re-query on every stall
        return;
      }
      if (!mounted || !_ownsPlayback || !_isLive || _current.url != cur.url) {
        return; // user zapped away while we searched
      }
      _liveVariant[_index] = next;
      _showQualityNotice('Slow connection — switched to ${next.name}');
      await _openAt(_index);
    } finally {
      _downgrading = false;
    }
  }

  void _showQualityNotice(String msg) {
    _qualityNoticeTimer?.cancel();
    setState(() => _qualityNotice = msg);
    _qualityNoticeTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _qualityNotice = null);
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
    if ((pos.inMilliseconds - _lastSavedPosMs).abs() >= 5000) {
      _lastSavedPosMs = pos.inMilliseconds;
      final repo = ref.read(repositoryProvider).valueOrNull;
      if (_current.id != null) {
        unawaited(repo?.db.saveProgress(
            _current.id!, pos.inMilliseconds, dur.inMilliseconds));
      } else {
        final ek = _episodeKey();
        if (ek != null) {
          unawaited(repo?.db.saveEpisodeProgress(
              ek, pos.inMilliseconds, dur.inMilliseconds));
        }
      }
    }

    // Keep Trakt's progress near-live: re-send a start scrobble every ~5 min
    // (the protocol allows refreshing it) so even a killed app leaves Trakt
    // within minutes of the truth instead of only learning at stop time.
    if (_playing &&
        DateTime.now().difference(_lastScrobbleAt) >
            const Duration(minutes: 5)) {
      _scrobble('start');
    }
  }

  /// Stable per-episode key for the current item, or null if it isn't a
  /// season/episode-identified series episode.
  String? _episodeKey() {
    final (title, isShow, season, episode) = _scrobbleIdentity();
    if (!isShow || season == null || episode == null) return null;
    return episodeKey(title, season, episode);
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

  DateTime _lastScrobbleAt = DateTime.now();

  void _scrobble(String action) {
    if (_isLive) return;
    _lastScrobbleAt = DateTime.now();
    final (title, isShow, season, episode) = _scrobbleIdentity();
    ref.read(traktServiceProvider).valueOrNull?.scrobble(action, title,
        isShow: isShow,
        season: season,
        episode: episode,
        progressPct: _progressPct);
  }

  void _checkpoint() {
    if (_isLive || _lastDurMs <= 0) return;
    final repo = ref.read(repositoryProvider).valueOrNull;
    if (_current.id != null) {
      unawaited(repo?.db.saveProgress(_current.id!, _lastPosMs, _lastDurMs));
    } else {
      final ek = _episodeKey();
      if (ek != null) {
        unawaited(repo?.db.saveEpisodeProgress(ek, _lastPosMs, _lastDurMs));
      }
    }
    // Stop scrobble, then re-pull Trakt's resume points so the cached playback
    // snapshot (which feeds the Continue Watching overlay) reflects this
    // session the moment the player closes — not after the 6h cache TTL.
    final svc = ref.read(traktServiceProvider).valueOrNull;
    if (svc == null) return;
    _lastScrobbleAt = DateTime.now();
    final (title, isShow, season, episode) = _scrobbleIdentity();
    unawaited(svc
        .scrobble('stop', title,
            isShow: isShow,
            season: season,
            episode: episode,
            progressPct: _progressPct)
        .then((_) => svc.refreshPlaybackCache()));
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
    if (_brightnessTouched) {
      // Hand the system its brightness back — the override was player-only.
      unawaited(ScreenBrightness.instance
          .resetApplicationScreenBrightness()
          .catchError((_) {}));
    }
    _unlockHintTimer?.cancel();
    _brightness.dispose();
    _hideTimer?.cancel();
    _digitTimer?.cancel();
    _previewTimer?.cancel();
    _seekFlashTimer?.cancel();
    _longStallTimer?.cancel();
    _qualityNoticeTimer?.cancel();
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
    _flashSeek(secs < 0 ? -1 : 1);
    _resetHideTimer();
  }

  /// Pulse the directional ±30s indicator (fades in, then out).
  void _flashSeek(int dir) {
    setState(() {
      _seekFlashDir = dir;
      _seekFlashOn = true;
    });
    _seekFlashTimer?.cancel();
    _seekFlashTimer = Timer(const Duration(milliseconds: 620), () {
      if (mounted) setState(() => _seekFlashOn = false);
    });
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
      currentUrl: _urlOverrides[_index] ?? _current.url,
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

  /// Fetch an English subtitle track from OpenSubtitles and attach it — the
  /// "else" path when a stream ships without English subs baked in.
  Future<void> _fetchOnlineSubs() async {
    if (_fetchingSubs) return;
    setState(() => _fetchingSubs = true);
    final messenger = ScaffoldMessenger.of(context);
    void toast(String m) => messenger.showSnackBar(SnackBar(
        backgroundColor: Aurora.bgRaised,
        content: Text(m, style: const TextStyle(color: Aurora.text))));
    try {
      final (title, isShow, season, episode) = _scrobbleIdentity();
      final imdb = await imdbIdForTitle(ref, title, isShow: isShow);
      if (imdb == null) {
        toast('Couldn\'t match this title for subtitles.');
        return;
      }
      final srt = await OpenSubtitlesService()
          .englishSrt(imdb, season: season, episode: episode);
      if (srt == null) {
        toast('No English subtitles found online.');
        return;
      }
      await _player.setSubtitleTrack(
          SubtitleTrack.data(srt, title: 'English (online)', language: 'en'));
      toast('English subtitles loaded.');
      _closePanel();
    } catch (_) {
      toast('Subtitle search failed.');
    } finally {
      if (mounted) setState(() => _fetchingSubs = false);
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
    // Locked: swallow everything, just surface the unlock pill.
    if (_locked) {
      _pokeUnlockHint();
      return KeyEventResult.handled;
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
      // Up/Down no longer zap channels — they just wake the chrome so the user
      // switches channels deliberately from the Channels panel (or dedicated
      // channel/media keys). Falls through to _showControls() below.
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

    final phone = _phoneUi(context);

    return PopScope(
      canPop: !_locked && !panelOpen && (!_controlsVisible || pausedPinned),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          PlaybackEngine.instance.pauseNow();
        } else if (_locked) {
          _pokeUnlockHint(); // back doesn't escape the lock
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
            onHover: (_) {
              if (!_locked) _showControls(focusFirst: false);
            },
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => _locked
                  ? _pokeUnlockHint()
                  : (_controlsVisible ? _hideControls() : _showControls()),
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
                        phone: phone,
                        state: this,
                      ),
                    ),
                  ),
                ),
                // ---- Mobile: Netflix-style brightness rail (left) ----
                if (phone && _controlsVisible && !_locked && _error == null)
                  Positioned(
                    left: 12,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: _BrightnessRail(
                        brightness: _brightness,
                        onChanged: _setBrightness,
                        onActivity: _resetHideTimer,
                      ),
                    ),
                  ),
                // ---- Mobile: screen-lock unlock pill ----
                if (_locked)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 44,
                    child: IgnorePointer(
                      ignoring: !_unlockHintOn,
                      child: AnimatedOpacity(
                        opacity: _unlockHintOn ? 1 : 0,
                        duration: Aurora.normal,
                        child: Center(
                          child: GestureDetector(
                            onTap: _unlock,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 18, vertical: 11),
                              decoration: BoxDecoration(
                                color: const Color(0xE60C0E15),
                                borderRadius: BorderRadius.circular(26),
                                border: Border.all(color: Aurora.hairline),
                                boxShadow: const [
                                  BoxShadow(
                                      color: Colors.black54, blurRadius: 18),
                                ],
                              ),
                              child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.lock_open_rounded,
                                        size: 17, color: Colors.white),
                                    SizedBox(width: 8),
                                    Text('Tap to unlock',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w700)),
                                  ]),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // ±30s directional seek flash (keyboard/remote seeks).
                _SeekFlash(dir: _seekFlashDir, on: _seekFlashOn),
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
                // Auto quality fallback notice ("Slow connection — switched
                // to ESPN HD"). Purely informational, fades after a few secs.
                if (_qualityNotice != null)
                  Positioned(
                    top: 40,
                    left: 40,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xD906070B),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Aurora.hairline),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.network_check_rounded,
                              size: 18, color: Colors.amber),
                          const SizedBox(width: 10),
                          Text(_qualityNotice!,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600)),
                        ]),
                      ),
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
                      overviews: widget.playContext?.overviews,
                      showTitle: widget.playContext?.title,
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
                  child: Column(children: [
                    // Online fetch — the fallback when no English subs are baked
                    // into the stream.
                    AuroraOptionRow(
                      label: _fetchingSubs
                          ? 'Searching OpenSubtitles…'
                          : 'Search online (English)',
                      sublabel: 'Fetch & attach from OpenSubtitles',
                      selected: false,
                      onSelect: _fetchingSubs ? () {} : _fetchOnlineSubs,
                    ),
                    const Divider(
                        height: 12, color: Aurora.hairline, indent: 16, endIndent: 16),
                    Expanded(
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
    required this.phone,
    required this.state,
  });

  final bool isFav;
  final bool rdOn;
  final bool spinner;

  /// Touch phone layout — gates the screen-lock action.
  final bool phone;
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
      if (phone) ...[
        AuroraIconButton(
          icon: Icons.lock_outline_rounded,
          tooltip: 'Lock screen',
          onActivity: state._resetHideTimer,
          onPressed: state._lockScreen,
        ),
        gap,
      ],
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
        // With the overlay up, ◀ ▶ navigate to the skip buttons / timeline
        // (which seek) rather than seeking directly — so remote D-pad browses
        // the visible controls. When the overlay is hidden, ◀ ▶ seek globally.
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
                  width: double.infinity,
                  child: Center(
                    child: AnimatedContainer(
                      duration: Aurora.fast,
                      height: active ? 9 : 5,
                      width: double.infinity,
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
                      // Explicit left-anchored widths — fills grow strictly
                      // left → right (never from the centre outward).
                      child: Stack(children: [
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: box.maxWidth * _frac(buffered),
                          child:
                              const ColoredBox(color: Color(0x40FFFFFF)),
                        ),
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: box.maxWidth * _frac(position),
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

/// Netflix-style vertical brightness control for phones: a slim glass rail on
/// the overlay's left. Drag anywhere on it (or tap a spot) to set the level;
/// the icon tracks low/high. Pointer-only by design — it never takes D-pad
/// focus, so TV traversal is untouched. Listens to a notifier so a drag only
/// ever rebuilds this rail, not the player.
class _BrightnessRail extends StatelessWidget {
  const _BrightnessRail({
    required this.brightness,
    required this.onChanged,
    required this.onActivity,
  });

  final ValueListenable<double> brightness;
  final ValueChanged<double> onChanged;
  final VoidCallback onActivity;

  static const _trackH = 168.0;

  void _fromLocal(Offset local) {
    onActivity();
    onChanged(1 - (local.dy / _trackH).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeFocus(
      child: ValueListenableBuilder<double>(
        valueListenable: brightness,
        builder: (context, value, _) =>
            Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(
            value >= 0.66
                ? Icons.brightness_high_rounded
                : value >= 0.33
                    ? Icons.brightness_medium_rounded
                    : Icons.brightness_low_rounded,
            size: 19,
            color: Colors.white,
          ),
          const SizedBox(height: 10),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _fromLocal(d.localPosition),
            onVerticalDragUpdate: (d) => _fromLocal(d.localPosition),
            child: Container(
              width: 34,
              height: _trackH,
              alignment: Alignment.center,
              child: Container(
                width: 6,
                height: _trackH,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: const Color(0x40FFFFFF),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: value.clamp(0.0, 1.0),
                    child: const DecoratedBox(
                      decoration: BoxDecoration(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// YouTube-style ±30s indicator: a rounded glass badge that flashes on the
/// left (rewind) or right (forward) and fades away.
class _SeekFlash extends StatelessWidget {
  const _SeekFlash({required this.dir, required this.on});
  final int dir;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final back = dir < 0;
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: back ? const Alignment(-0.5, 0) : const Alignment(0.5, 0),
          child: AnimatedOpacity(
            opacity: on ? 1 : 0,
            duration: Duration(milliseconds: on ? 110 : 360),
            curve: Curves.easeOut,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
              decoration: const BoxDecoration(
                color: Color(0x80000000),
                shape: BoxShape.circle,
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(
                    back
                        ? Icons.fast_rewind_rounded
                        : Icons.fast_forward_rounded,
                    color: Colors.white,
                    size: 34),
                const SizedBox(height: 4),
                const Text('30s',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w800)),
              ]),
            ),
          ),
        ),
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

/// Channels: the flat zap list it always was. Episodes: a season browser —
/// season chips across the top (checked once every episode in them is
/// watched), then only that season's episodes as rich tiles: thumbnail,
/// title, short synopsis, watched check. Fully D-pad navigable: chips ↔ list
/// via normal traversal, current episode autofocused.
class _QueueList extends ConsumerStatefulWidget {
  const _QueueList({
    required this.queue,
    required this.episodes,
    required this.currentIndex,
    required this.isLive,
    required this.onSelect,
    this.overviews,
    this.showTitle,
  });

  final List<StreamItem> queue;
  final List<(int, int)>? episodes;
  final List<String?>? overviews;
  final String? showTitle;
  final int currentIndex;
  final bool isLive;
  final ValueChanged<int> onSelect;

  @override
  ConsumerState<_QueueList> createState() => _QueueListState();
}

class _QueueListState extends ConsumerState<_QueueList> {
  static const _tileH = 86.0;
  int? _season;

  late final ScrollController _controller = ScrollController(
    initialScrollOffset: () {
      if (widget.episodes == null) {
        return widget.currentIndex <= 2 ? 0.0 : (widget.currentIndex - 2) * 64.0;
      }
      final inSeason = _indicesFor(_currentSeason());
      final at = inSeason.indexOf(widget.currentIndex);
      return at <= 1 ? 0.0 : (at - 1) * _tileH;
    }(),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int? _seasonOf(int i) =>
      (widget.episodes != null && i < widget.episodes!.length)
          ? widget.episodes![i].$1
          : null;

  int _currentSeason() => _seasonOf(widget.currentIndex) ?? 1;

  List<int> _indicesFor(int season) => [
        for (var i = 0; i < widget.queue.length; i++)
          if (_seasonOf(i) == season) i,
      ];

  @override
  Widget build(BuildContext context) {
    if (widget.episodes == null) {
      // Live channels — flat list, unchanged.
      return ListView.builder(
        controller: _controller,
        padding: const EdgeInsets.only(bottom: 14),
        itemCount: widget.queue.length,
        itemBuilder: (context, i) {
          final it = widget.queue[i];
          final current = i == widget.currentIndex;
          return AuroraOptionRow(
            label: widget.isLive
                ? '${it.num != null ? '${it.num}  ' : ''}${it.name}'
                : cleanTitle(it.name).title,
            sublabel: current ? 'Now playing' : null,
            selected: current,
            autofocus: current,
            onSelect: () => widget.onSelect(i),
          );
        },
      );
    }

    final seasons =
        widget.episodes!.map((e) => e.$1).toSet().toList()..sort();
    final season = _season ?? _currentSeason();

    // Watched state: local per-episode progress merged with Trakt history.
    final prog = ref.watch(episodeProgressProvider).valueOrNull ?? const {};
    final cleanShow =
        cleanTitle(widget.showTitle ?? '').title;
    final trakt = cleanShow.isEmpty
        ? const <(int, int)>{}
        : (ref.watch(traktWatchedEpisodesProvider(cleanShow)).valueOrNull ??
            const <(int, int)>{});
    bool isWatched(int s, int e) =>
        (prog[episodeKey(cleanShow, s, e)]?.watched ?? false) ||
        trakt.contains((s, e));
    final watchedSeasons = <int>{
      for (final s in seasons)
        if (widget.episodes!.every((se) => se.$1 != s || isWatched(s, se.$2)))
          s,
    };

    final indices = _indicesFor(season);
    return Column(children: [
      // Season selector — chips scroll horizontally, ✓ = season fully seen.
      SizedBox(
        height: 46,
        child: FocusTraversalGroup(
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
            itemCount: seasons.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final s = seasons[i];
              final sel = s == season;
              final done = watchedSeasons.contains(s);
              return AuroraFocusable(
                ring: false,
                scale: 1.0,
                onActivate: () => setState(() => _season = s),
                builder: (context, focused) => AnimatedContainer(
                  duration: Aurora.fast,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: focused
                        ? Colors.white
                        : (sel ? Aurora.glassHi : Aurora.glass),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Aurora.hairline),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (done) ...[
                      Icon(Icons.check_rounded,
                          size: 13, color: focused ? Aurora.bg : Aurora.good),
                      const SizedBox(width: 4),
                    ],
                    Text('Season $s',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: sel || focused
                                ? FontWeight.w800
                                : FontWeight.w600,
                            color: focused
                                ? Aurora.bg
                                : (sel ? Aurora.text : Aurora.textDim))),
                  ]),
                ),
              );
            },
          ),
        ),
      ),
      const Divider(
          height: 10, color: Aurora.hairline, indent: 16, endIndent: 16),
      Expanded(
        child: ListView.builder(
          controller: _controller,
          padding: const EdgeInsets.only(bottom: 14),
          itemCount: indices.length,
          itemBuilder: (context, n) {
            final i = indices[n];
            final it = widget.queue[i];
            final (s, e) = widget.episodes![i];
            final overview = widget.overviews != null &&
                    i < widget.overviews!.length
                ? widget.overviews![i]
                : null;
            return _EpisodeTile(
              item: it,
              episodeLabel: 'E$e',
              overview: overview,
              watched: isWatched(s, e),
              current: i == widget.currentIndex,
              onSelect: () => widget.onSelect(i),
            );
          },
        ),
      ),
    ]);
  }
}

/// One episode row in the player panel: still + title + synopsis + state.
class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.item,
    required this.episodeLabel,
    required this.overview,
    required this.watched,
    required this.current,
    required this.onSelect,
  });

  final StreamItem item;
  final String episodeLabel;
  final String? overview;
  final bool watched;
  final bool current;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final title = cleanTitle(item.name).title;
    return AuroraFocusable(
      radius: 12,
      scale: 1.0,
      autofocus: current,
      onActivate: onSelect,
      builder: (context, focused) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: focused
              ? Aurora.glassHi
              : (current ? Aurora.glass : Colors.transparent),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: current ? const Color(0x554CC2FF) : Colors.transparent),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 104,
            height: 58,
            child: Stack(fit: StackFit.expand, children: [
              Opacity(
                opacity: watched && !current ? 0.55 : 1,
                child: AuroraImage(
                  url: item.logo,
                  width: 104,
                  height: 58,
                  radius: 8,
                  fallbackText: title,
                ),
              ),
              if (watched && !current)
                const Positioned.fill(child: CenterSeenBadge(size: 26)),
              if (current)
                const Positioned(
                  left: 4,
                  bottom: 4,
                  child: Icon(Icons.equalizer_rounded,
                      size: 14, color: Aurora.accent),
                ),
            ]),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$episodeLabel · $title',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: current
                            ? Aurora.accent
                            : (watched ? Aurora.textDim : Aurora.text))),
                const SizedBox(height: 3),
                if (current)
                  const Text('Now playing',
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: Aurora.accent))
                else if (overview != null && overview!.isNotEmpty)
                  Text(overview!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, height: 1.35, color: Aurora.textDim))
                else if (watched)
                  const Text('Watched',
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: Aurora.good)),
              ],
            ),
          ),
        ]),
      ),
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
    // Always give the panel a focus target so the remote can enter it — audio
    // has no "Off" row, so when the active track is "auto" nothing is marked
    // selected; fall back to autofocusing the first row.
    final anySelected = options.any((o) => o.$2);
    return ListView(
      padding: const EdgeInsets.only(bottom: 14),
      children: [
        for (final (i, (label, selected, apply)) in options.indexed)
          AuroraOptionRow(
            label: label,
            selected: selected,
            autofocus: selected || (!anySelected && i == 0),
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
