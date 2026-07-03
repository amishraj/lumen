import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../aurora_providers.dart';
import '../aurora_theme.dart';
import '../player/aurora_player.dart';
import '../widgets/aurora_cards.dart';
import '../widgets/aurora_shelf.dart';

/// Sports hub: event channels ("TEAM vs TEAM" + sports categories) grouped by
/// sport, each group a zappable rail.
class AuroraSportsPage extends ConsumerWidget {
  const AuroraSportsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final buckets = ref.watch(auroraSportsProvider).valueOrNull;
    final margin = Aurora.margin(context);
    final w = Aurora.wideWidth(context) * 0.82;
    final rowH = w * 9 / 16 + 40;

    if (buckets == null) {
      return const Center(
          child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2)));
    }

    return CustomScrollView(slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(margin, 92, margin, 0),
          child: Text('Sports', style: Aurora.display.copyWith(fontSize: 30)),
        ),
      ),
      if (buckets.isEmpty)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text('No live events found in your source.',
                style: TextStyle(color: Aurora.textFaint)),
          ),
        )
      else
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              final (name, items) = buckets[i];
              return AuroraShelf(
                title: name,
                items: items,
                rowHeight: rowH,
                skeletonWidth: w,
                itemBuilder: (context, it, j) => AuroraLiveCard(
                  item: it,
                  width: w,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => AuroraPlayerScreen(
                      item: it,
                      queue: items,
                      startIndex: j,
                    ),
                  )),
                ),
              );
            },
            childCount: buckets.length,
          ),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 72)),
    ]);
  }
}
