import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/sources/realdebrid_service.dart';
import '../theme/lumen_theme.dart';
import '../title_utils.dart';

/// The stream the user picked in [showSourcePicker].
class PickedSource {
  final String url;
  final String label;
  final bool isDebrid;
  const PickedSource(this.url, this.label, {required this.isDebrid});
}

/// Bottom sheet listing playback sources for a title: the user's own IPTV
/// stream plus Real-Debrid options (quality/size), resolved via the title's
/// IMDb id. Returns null if dismissed.
Future<PickedSource?> showSourcePicker(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  bool isShow = false,
  int? season,
  int? episode,
  String? iptvUrl,
}) {
  return showModalBottomSheet<PickedSource>(
    context: context,
    backgroundColor: const Color(0xFF15171F),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _SourceSheet(
      title: title,
      isShow: isShow,
      season: season,
      episode: episode,
      iptvUrl: iptvUrl,
    ),
  );
}

class _SourceSheet extends ConsumerStatefulWidget {
  const _SourceSheet({
    required this.title,
    required this.isShow,
    this.season,
    this.episode,
    this.iptvUrl,
  });
  final String title;
  final bool isShow;
  final int? season;
  final int? episode;
  final String? iptvUrl;

  @override
  ConsumerState<_SourceSheet> createState() => _SourceSheetState();
}

class _SourceSheetState extends ConsumerState<_SourceSheet> {
  List<RdStream>? _streams;
  String? _error;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    try {
      // Clean provider noise (numbering, "EN -", quality tags, episode
      // prefixes) so the IMDb lookup sees the real title.
      final clean =
          cleanTitle(widget.title.replaceAll(RegExp(r'^S\d+E\d+\s*·\s*'), ''))
              .title;
      final imdb = await imdbIdForTitle(ref, clean, isShow: widget.isShow);
      if (imdb == null) {
        if (mounted) {
          setState(() => _error = 'Couldn\'t match this title to IMDb.');
        }
        return;
      }
      final svc = await ref.read(realDebridServiceProvider.future);
      final list = await svc.streams(imdb,
          season: widget.season, episode: widget.episode);
      if (mounted) {
        setState(() {
          _streams = list;
          if (list.isEmpty) _error = 'No cached Debrid streams found.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final streams = _streams;
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text('Choose a source',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (widget.iptvUrl != null)
                    ListTile(
                      leading:
                          const Icon(Icons.live_tv, color: LumenTheme.accent),
                      title: const Text('Your IPTV stream'),
                      subtitle: const Text('From your provider'),
                      onTap: () => Navigator.pop(
                          context,
                          PickedSource(widget.iptvUrl!, 'IPTV',
                              isDebrid: false)),
                    ),
                  if (streams == null && _error == null)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: Column(children: [
                          SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(height: 10),
                          Text('Finding Debrid streams…',
                              style: TextStyle(
                                  color: Color(0xFF9AA0B0), fontSize: 12.5)),
                        ]),
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                      child: Text(_error!,
                          style: const TextStyle(
                              color: Color(0xFF9AA0B0), fontSize: 13)),
                    ),
                  if (streams != null)
                    for (final s in streams.take(12))
                      ListTile(
                        leading: Container(
                          width: 52,
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          decoration: BoxDecoration(
                            color: LumenTheme.accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(s.quality,
                              style: const TextStyle(
                                  color: LumenTheme.accent,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12)),
                        ),
                        title: Text(s.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13.5)),
                        subtitle: Text(
                            [
                              'Real-Debrid',
                              if (s.size != null) s.size!,
                            ].join(' · '),
                            style: const TextStyle(fontSize: 12)),
                        onTap: () => Navigator.pop(
                            context,
                            PickedSource(s.url, 'RD ${s.quality}',
                                isDebrid: true)),
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
}
