import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/sources/realdebrid_service.dart';
import '../../ui/title_utils.dart';
import '../aurora_focus.dart';
import '../aurora_theme.dart';

/// The stream the user picked.
class AuroraPickedSource {
  final String url;
  final String label;
  final bool isDebrid;
  const AuroraPickedSource(this.url, this.label, {required this.isDebrid});
}

/// Aurora-styled source chooser: your own IPTV stream plus cached
/// Real-Debrid options (quality/size), resolved via the title's IMDb id.
Future<AuroraPickedSource?> showAuroraSourceSheet(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  bool isShow = false,
  int? season,
  int? episode,
  String? iptvUrl,
}) {
  return showModalBottomSheet<AuroraPickedSource>(
    context: context,
    backgroundColor: Aurora.bgRaised,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => _Sheet(
      title: title,
      isShow: isShow,
      season: season,
      episode: episode,
      iptvUrl: iptvUrl,
    ),
  );
}

class _Sheet extends ConsumerStatefulWidget {
  const _Sheet({
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
  ConsumerState<_Sheet> createState() => _SheetState();
}

class _SheetState extends ConsumerState<_Sheet> {
  List<RdStream>? _streams;
  String? _error;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    try {
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
              padding: EdgeInsets.fromLTRB(24, 20, 24, 10),
              child: Text('Choose a source', style: Aurora.title),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: [
                  if (widget.iptvUrl != null)
                    _SourceRow(
                      autofocus: true,
                      badge: 'IPTV',
                      badgeColor: Aurora.accent,
                      title: 'Your IPTV stream',
                      subtitle: 'From your provider',
                      onPick: () => Navigator.pop(
                          context,
                          AuroraPickedSource(widget.iptvUrl!, 'IPTV',
                              isDebrid: false)),
                    ),
                  if (streams == null && _error == null)
                    const Padding(
                      padding: EdgeInsets.all(26),
                      child: Center(
                        child: Column(children: [
                          SizedBox(
                              width: 20,
                              height: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(height: 12),
                          Text('Finding Debrid streams…',
                              style: TextStyle(
                                  color: Aurora.textDim, fontSize: 12.5)),
                        ]),
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                      child: Text(_error!,
                          style: const TextStyle(
                              color: Aurora.textDim, fontSize: 13)),
                    ),
                  if (streams != null)
                    for (final s in streams.take(12))
                      _SourceRow(
                        badge: s.quality,
                        badgeColor: Aurora.accentAlt,
                        title: s.label,
                        subtitle: [
                          'Real-Debrid',
                          if (s.size != null) s.size!,
                        ].join(' · '),
                        onPick: () => Navigator.pop(
                            context,
                            AuroraPickedSource(s.url, 'RD ${s.quality}',
                                isDebrid: true)),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.badge,
    required this.badgeColor,
    required this.title,
    required this.subtitle,
    required this.onPick,
    this.autofocus = false,
  });

  final String badge;
  final Color badgeColor;
  final String title;
  final String subtitle;
  final VoidCallback onPick;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return AuroraFocusable(
      autofocus: autofocus,
      radius: 14,
      scale: 1.0,
      onActivate: onPick,
      builder: (context, focused) => Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: focused ? Aurora.glassHi : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          Container(
            width: 56,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 5),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(8),
              border:
                  Border.all(color: badgeColor.withValues(alpha: 0.45)),
            ),
            child: Text(badge,
                style: TextStyle(
                    color: badgeColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 11.5)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(
                        fontSize: 12, color: Aurora.textDim)),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
