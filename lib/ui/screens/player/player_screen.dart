import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../data/models/models.dart';
import '../../../data/sources/trakt_service.dart';
import '../../../state/providers.dart';
import '../../theme/lumen_theme.dart';

/// Full-screen player backed by libmpv (media_kit). Handles MPEG-TS, HLS and
/// the odd codecs common in IPTV, with hardware decode where available.
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key, required this.item});
  final StreamItem item;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late final Player _player = Player(
    configuration: const PlayerConfiguration(
      bufferSize: 32 * 1024 * 1024, // generous buffer for flaky IPTV sources
      title: 'Lumen',
    ),
  );
  late final VideoController _controller = VideoController(_player);
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      await _player.open(Media(widget.item.url), play: true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (widget.item.kind == StreamKind.live) return;

    // Cross-device resume: ask Trakt where this title was left off, then seek
    // once we know the duration.
    final svc = ref.read(traktServiceProvider).valueOrNull;
    final resume = await svc?.resumeProgress(widget.item.name,
        isShow: widget.item.kind == StreamKind.series);

    _player.stream.position.listen((pos) async {
      final dur = _player.state.duration;
      if (dur.inMilliseconds <= 0) return;
      _lastPosMs = pos.inMilliseconds;
      _lastDurMs = dur.inMilliseconds;

      // Seek to the Trakt resume point once, near the start of playback.
      if (!_sought && resume != null && resume > 0.02 && resume < 0.9) {
        _sought = true;
        await _player.seek(Duration(milliseconds: (dur.inMilliseconds * resume).round()));
      }

      if (widget.item.id != null) {
        final repo = ref.read(repositoryProvider).valueOrNull;
        await repo?.db.saveProgress(widget.item.id!, pos.inMilliseconds, dur.inMilliseconds);
      }
      if (!_scrobbled && pos.inMilliseconds / dur.inMilliseconds >= 0.9) {
        _scrobbled = true;
        svc?.markWatched(widget.item.name,
            isShow: widget.item.kind == StreamKind.series);
      }
    });
  }

  bool _scrobbled = false;
  bool _sought = false;
  int _lastPosMs = 0;
  int _lastDurMs = 0;

  @override
  void dispose() {
    // Push a resume checkpoint to Trakt so other devices can pick up.
    if (widget.item.kind != StreamKind.live &&
        _lastDurMs > 0 &&
        !_scrobbled) {
      final svc = ref.read(traktServiceProvider).valueOrNull;
      svc?.savePlayback(widget.item.name,
          isShow: widget.item.kind == StreamKind.series,
          progressPct: _lastPosMs / _lastDurMs * 100.0);
    }
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: _error != null
                ? _ErrorView(message: _error!, name: widget.item.name)
                : Video(
                    controller: _controller,
                    controls: AdaptiveVideoControls,
                    fit: BoxFit.contain,
                  ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: CircleAvatar(
                  backgroundColor: Colors.black54,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
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
          const Icon(Icons.error_outline, color: LumenTheme.accentWarm, size: 48),
          const SizedBox(height: 16),
          Text('Couldn\'t play "$name"',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
          const SizedBox(height: 8),
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF9AA0B0), fontSize: 12)),
        ],
      ),
    );
  }
}
