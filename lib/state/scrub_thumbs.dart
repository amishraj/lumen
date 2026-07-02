import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Background scrub-preview generator: walks a VOD stream with a *muted*,
/// headless secondary pipeline and grabs a sparse set of frames, so the seek
/// bubble can show what's at the target position.
///
/// Deliberately gentle: starts well after playback begins, caps the frame
/// count, tolerates any failure silently, and is cancelled the moment the
/// player leaves or switches content. Thumbs live only in memory.
class ScrubThumbs {
  ScrubThumbs._();
  static final ScrubThumbs instance = ScrubThumbs._();

  static const _count = 14;

  /// seconds → jpeg bytes for the CURRENT [_url]. Notifier so the scrub UI
  /// updates live as grabs land.
  final ValueNotifier<Map<int, Uint8List>> thumbs =
      ValueNotifier(const <int, Uint8List>{});

  String? _url;
  int _generation = 0;
  Player? _worker;

  /// Nearest available grab for [position], or null while none exist yet.
  Uint8List? nearest(Duration position) {
    final map = thumbs.value;
    if (map.isEmpty) return null;
    final target = position.inSeconds;
    int? best;
    for (final k in map.keys) {
      if (best == null || (k - target).abs() < (best - target).abs()) {
        best = k;
      }
    }
    return best == null ? null : map[best];
  }

  /// Kick off generation for [url]. No-ops if already generated/generating for
  /// the same url. Safe to call repeatedly.
  Future<void> generate(String url, Duration duration) async {
    if (url == _url) return;
    cancel();
    if (duration < const Duration(minutes: 5)) return; // not worth it
    _url = url;
    final gen = ++_generation;
    thumbs.value = const {};

    Player? worker;
    try {
      worker = Player(
          configuration: const PlayerConfiguration(
              muted: true, title: 'Lumen thumbnailer'));
      _worker = worker;
      unawaited(worker.setVolume(0));
      // A controller is required for frames to be decoded/renderable.
      VideoController(worker);
      await worker.open(Media(url), play: false);

      final step = duration.inSeconds ~/ (_count + 1);
      final acc = <int, Uint8List>{};
      for (var i = 1; i <= _count; i++) {
        if (gen != _generation) return; // cancelled / superseded
        final at = step * i;
        try {
          await worker.seek(Duration(seconds: at));
          // Give the decoder a moment to land on the new frame.
          await Future.delayed(const Duration(milliseconds: 450));
          if (gen != _generation) return;
          final shot = await worker
              .screenshot(format: 'image/jpeg')
              .timeout(const Duration(seconds: 4));
          if (shot != null && shot.isNotEmpty) {
            acc[at] = shot;
            thumbs.value = Map.unmodifiable(acc);
          }
        } catch (_) {/* skip this point, keep walking */}
      }
    } catch (_) {
      /* stream refused a second connection — no previews */
    } finally {
      if (identical(_worker, worker)) _worker = null;
      final w = worker;
      if (w != null) {
        () async {
          try {
            await w.stop().timeout(const Duration(seconds: 2));
          } catch (_) {}
          try {
            await w.dispose().timeout(const Duration(seconds: 4));
          } catch (_) {}
        }();
      }
    }
  }

  /// Stop any in-flight generation and drop the grabs.
  void cancel() {
    _generation++;
    _url = null;
    thumbs.value = const {};
    final w = _worker;
    _worker = null;
    if (w != null) {
      () async {
        try {
          await w.stop().timeout(const Duration(seconds: 2));
        } catch (_) {}
        try {
          await w.dispose().timeout(const Duration(seconds: 4));
        } catch (_) {}
      }();
    }
  }
}
