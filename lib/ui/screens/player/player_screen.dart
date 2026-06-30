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
///
/// Optionally takes a [queue] (e.g. a season's episodes) so the user can skip
/// to the next/previous item without leaving the player.
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({
    super.key,
    required this.item,
    this.queue,
    this.startIndex = 0,
  });

  final StreamItem item;
  final List<StreamItem>? queue;
  final int startIndex;

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

  late final List<StreamItem> _queue =
      widget.queue == null || widget.queue!.isEmpty ? [widget.item] : widget.queue!;
  late int _index = widget.startIndex.clamp(0, _queue.length - 1);

  StreamItem get _current => _queue[_index];

  String? _error;
  bool _scrobbled = false;
  bool _sought = false;
  double? _resume;
  int _lastPosMs = 0;
  int _lastDurMs = 0;

  @override
  void initState() {
    super.initState();
    // One position listener for the player's lifetime; it reads _current.
    _player.stream.position.listen(_onPosition);
    _openAt(_index);
  }

  Future<void> _openAt(int i) async {
    setState(() {
      _index = i.clamp(0, _queue.length - 1);
      _error = null;
      _scrobbled = false;
      _sought = false;
      _resume = null;
      _lastPosMs = 0;
      _lastDurMs = 0;
    });
    try {
      await _player.open(Media(_current.url), play: true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (_current.kind == StreamKind.live) return;
    final svc = ref.read(traktServiceProvider).valueOrNull;
    _resume = await svc?.resumeProgress(_current.name,
        isShow: _current.kind == StreamKind.series);
  }

  Future<void> _onPosition(Duration pos) async {
    if (_current.kind == StreamKind.live) return;
    final dur = _player.state.duration;
    if (dur.inMilliseconds <= 0) return;
    _lastPosMs = pos.inMilliseconds;
    _lastDurMs = dur.inMilliseconds;

    if (!_sought && _resume != null && _resume! > 0.02 && _resume! < 0.9) {
      _sought = true;
      await _player.seek(Duration(milliseconds: (dur.inMilliseconds * _resume!).round()));
    }
    if (_current.id != null) {
      final repo = ref.read(repositoryProvider).valueOrNull;
      await repo?.db.saveProgress(_current.id!, pos.inMilliseconds, dur.inMilliseconds);
    }
    if (!_scrobbled && pos.inMilliseconds / dur.inMilliseconds >= 0.9) {
      _scrobbled = true;
      ref.read(traktServiceProvider).valueOrNull?.markWatched(_current.name,
          isShow: _current.kind == StreamKind.series);
    }
  }

  void _checkpoint() {
    if (_current.kind != StreamKind.live && _lastDurMs > 0 && !_scrobbled) {
      ref.read(traktServiceProvider).valueOrNull?.savePlayback(_current.name,
          isShow: _current.kind == StreamKind.series,
          progressPct: _lastPosMs / _lastDurMs * 100.0);
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
    _player.dispose();
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

  void _showTrackSheet({required String title, required List<_TrackOption> options}) {
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
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
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
                        o.selected ? Icons.radio_button_checked : Icons.radio_button_off,
                        color: o.selected ? LumenTheme.accent : const Color(0xFF6B7080),
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

  @override
  Widget build(BuildContext context) {
    final hasQueue = _queue.length > 1;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: _error != null
                ? _ErrorView(message: _error!, name: _current.name)
                : Video(
                    controller: _controller,
                    controls: AdaptiveVideoControls,
                    fit: BoxFit.contain,
                  ),
          ),
          SafeArea(
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: _RoundButton(
                    icon: Icons.arrow_back,
                    tooltip: 'Back',
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ),
                const Spacer(),
                if (hasQueue)
                  _RoundButton(
                    icon: Icons.skip_previous,
                    tooltip: 'Previous episode',
                    enabled: _index > 0,
                    onTap: () => _skip(-1),
                  ),
                if (hasQueue) const SizedBox(width: 6),
                if (hasQueue)
                  _RoundButton(
                    icon: Icons.skip_next,
                    tooltip: 'Next episode',
                    enabled: _index < _queue.length - 1,
                    onTap: () => _skip(1),
                  ),
                if (hasQueue) const SizedBox(width: 6),
                if (_current.kind != StreamKind.live)
                  _RoundButton(
                    icon: Icons.closed_caption,
                    tooltip: 'Subtitles',
                    onTap: _pickSubtitle,
                  ),
                const SizedBox(width: 6),
                _RoundButton(
                  icon: Icons.multitrack_audio,
                  tooltip: 'Audio track',
                  onTap: _pickAudio,
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
          // Episode label
          if (hasQueue)
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(_current.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 12.5)),
                  ),
                ),
              ),
            ),
        ],
      ),
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
  });
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      backgroundColor: Colors.black54,
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon, color: enabled ? Colors.white : const Color(0xFF5B6072)),
        onPressed: enabled ? onTap : null,
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
