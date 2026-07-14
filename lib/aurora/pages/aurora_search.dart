import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../aurora_navigation.dart';
import '../aurora_theme.dart';
import '../widgets/aurora_cards.dart';
import '../widgets/aurora_search_field.dart';
import '../widgets/aurora_shelf.dart';

/// Unified search over the whole library (FTS5-backed), with one-press voice.
/// Results group into Live / Movies / Shows rails as you type.
class AuroraSearchPage extends ConsumerStatefulWidget {
  const AuroraSearchPage({super.key});

  @override
  ConsumerState<AuroraSearchPage> createState() => _AuroraSearchPageState();
}

class _AuroraSearchPageState extends ConsumerState<AuroraSearchPage> {
  final _ctl = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      if (mounted) ref.read(searchQueryProvider.notifier).state = v;
    });
  }

  void _onVoice(String text) {
    _ctl.text = text;
    _ctl.selection = TextSelection.collapsed(offset: text.length);
    _onChanged(text);
  }

  @override
  Widget build(BuildContext context) {
    final margin = Aurora.margin(context);
    final q = ref.watch(searchQueryProvider).trim();
    final grouped = ref.watch(groupedSearchProvider);
    final posterW = Aurora.posterWidth(context);
    final liveW = Aurora.wideWidth(context) * 0.82;

    return Column(children: [
      Padding(
        padding: EdgeInsets.fromLTRB(margin, 88, margin, 4),
        child: Row(children: [
          Expanded(
            child: AuroraSearchField(
              controller: _ctl,
              hint: 'Search movies, shows & channels',
              onChanged: _onChanged,
            ),
          ),
          const SizedBox(width: 10),
          AuroraVoiceButton(onText: _onVoice),
        ]),
      ),
      Expanded(
        child: q.length < 2
            ? const _Hint(
                icon: Icons.search_rounded,
                text: 'Type, or hold the mic and just say it.')
            : grouped.when(
                loading: () => const Center(
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))),
                error: (e, _) => Center(child: Text('$e')),
                data: (g) {
                  if (g.isEmpty) {
                    return _Hint(
                        icon: Icons.search_off_rounded,
                        text: 'No results for "$q"');
                  }
                  return ListView(
                    padding: const EdgeInsets.only(bottom: 48),
                    children: [
                      AuroraShelf<StreamItem>(
                        title: 'Live TV',
                        items: g.live,
                        rowHeight: liveW * 9 / 16 + 40,
                        skeletonWidth: liveW,
                        itemBuilder: (context, it, i) => AuroraLiveCard(
                          item: it,
                          width: liveW,
                          onTap: () => openAuroraItem(context, ref, it,
                              liveQueue: g.live),
                        ),
                      ),
                      AuroraShelf<StreamItem>(
                        title: 'Movies',
                        items: g.movies,
                        rowHeight: posterW * 1.5 + 56,
                        skeletonWidth: posterW,
                        itemBuilder: (context, it, i) => AuroraPosterCard(
                          item: it,
                          width: posterW,
                          showSourceBadge: true,
                          onTap: () => openAuroraItem(context, ref, it),
                        ),
                      ),
                      AuroraShelf<StreamItem>(
                        title: 'TV Shows',
                        items: g.series,
                        rowHeight: posterW * 1.5 + 56,
                        skeletonWidth: posterW,
                        itemBuilder: (context, it, i) => AuroraPosterCard(
                          item: it,
                          width: posterW,
                          showSourceBadge: true,
                          onTap: () => openAuroraItem(context, ref, it),
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    ]);
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 52, color: const Color(0xFF262B38)),
        const SizedBox(height: 14),
        Text(text, style: const TextStyle(color: Aurora.textFaint)),
      ]),
    );
  }
}
