import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// The app's single libmpv pipeline. One Player for the whole app lifetime:
/// screens open media into it and *stop* it on exit — nothing ever disposes
/// it mid-flight.
///
/// Why: per-screen Player+dispose() leaked audio repeatedly. media_kit
/// serializes commands, so a stop/dispose queued behind a stalled network
/// operation never ran — and once dispose() was issued there was no object
/// left to command. With a singleton, stop can be retried until verified,
/// and even a missed stop is replaced by the next open().
class PlaybackEngine {
  PlaybackEngine._();
  static final PlaybackEngine instance = PlaybackEngine._();

  Player? _player;
  VideoController? _controller;

  Player get player => _player ??= Player(
        configuration: const PlayerConfiguration(
          bufferSize: 32 * 1024 * 1024, // generous for flaky IPTV sources
          title: 'Lumen',
        ),
      );

  VideoController get controller => _controller ??= VideoController(player);

  /// Hard-stop playback: mute instantly (so even a lagging stop is silent),
  /// pause, then stop — verified and retried until the pipeline reports idle.
  Future<void> stopPlayback() async {
    final p = _player;
    if (p == null) return;
    try {
      unawaited(p.setVolume(0));
      unawaited(p.pause());
    } catch (_) {/* already quiet */}
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await p.stop().timeout(const Duration(seconds: 2));
      } catch (_) {/* stalled — retry below */}
      if (!p.state.playing) return;
      await Future.delayed(const Duration(milliseconds: 400));
    }
  }

  /// Undo the teardown mute before a new session plays.
  Future<void> restoreVolume() async {
    try {
      await player.setVolume(100);
    } catch (_) {/* best effort */}
  }
}
