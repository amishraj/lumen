import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../state/providers.dart';
import '../../navigation.dart';
import '../../theme/lumen_theme.dart';
import '../../widgets/poster_card.dart';

/// Master search results, grouped by kind (Live TV first, then Movies, TV
/// Shows). The query is driven by the always-present search bar in the app bar.
class SearchScreen extends ConsumerWidget {
  const SearchScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(searchQueryProvider).trim();
    final grouped = ref.watch(groupedSearchProvider);

    if (q.length < 2) {
      return const _Hint(icon: Icons.search, text: 'Search movies, shows & channels');
    }

    return grouped.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (g) {
        if (g.isEmpty) {
          return _Hint(icon: Icons.search_off, text: 'No results for "$q"');
        }
        return ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          children: [
            _Section(title: 'Live TV', icon: Icons.live_tv, items: g.live),
            _Section(title: 'Movies', icon: Icons.movie_outlined, items: g.movies),
            _Section(title: 'TV Shows', icon: Icons.tv, items: g.series),
          ],
        );
      },
    );
  }
}

class _Section extends ConsumerWidget {
  const _Section({required this.title, required this.icon, required this.items});
  final String title;
  final IconData icon;
  final List<StreamItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(children: [
            Icon(icon, size: 18, color: LumenTheme.accent),
            const SizedBox(width: 8),
            Text(title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
              decoration: BoxDecoration(
                color: LumenTheme.surfaceHi,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('${items.length}',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF9AA0B0))),
            ),
          ]),
        ),
        SizedBox(
          height: 214,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, i) => PosterCard(
              item: items[i],
              onTap: () => openItem(context, ref, items[i]),
            ),
          ),
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: const Color(0xFF3A3E4A)),
          const SizedBox(height: 12),
          Text(text, style: const TextStyle(color: Color(0xFF6B7080))),
        ],
      ),
    );
  }
}
