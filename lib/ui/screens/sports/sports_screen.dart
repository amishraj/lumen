import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../state/providers.dart';
import '../../theme/lumen_theme.dart';
import '../../widgets/focusable_item.dart';
import '../../widgets/logo_image.dart';
import '../player/player_screen.dart';

/// Sports hub: surfaces "TEAM vs TEAM" event channels from your provider,
/// grouped by sport. v1 is heuristic on channel naming — tell me your panel's
/// exact format and I'll tighten the Now/Upcoming windowing.
class SportsScreen extends ConsumerWidget {
  const SportsScreen({super.key});

  static const _buckets = <String, List<String>>{
    'Soccer': [
      'soccer',
      'football',
      'fifa',
      'world cup',
      'uefa',
      'premier',
      'la liga',
      'serie a',
      'bundesliga',
      'champions'
    ],
    'American Football': ['nfl', 'super bowl', 'ncaaf'],
    'Basketball': ['nba', 'basket', 'ncaab', 'euroleague'],
    'Ice Hockey': ['nhl', 'hockey'],
    'Tennis': ['tennis', 'atp', 'wta', 'wimbledon', 'roland'],
    'Combat': ['ufc', 'mma', 'boxing', 'fight', 'wwe'],
    'Motorsport': ['formula', ' f1', 'motogp', 'nascar', 'grand prix'],
    'Cricket': ['cricket', 'ipl'],
    'Rugby': ['rugby'],
    'Olympics': ['olympic'],
  };

  static String _sportOf(StreamItem it) {
    final hay = '${it.name} ${it.groupTitle ?? ''}'.toLowerCase();
    for (final entry in _buckets.entries) {
      if (entry.value.any(hay.contains)) return entry.key;
    }
    return 'Other Events';
  }

  static final _timeRe = RegExp(r'(\d{1,2}:\d{2})');
  static String? _timeOf(String name) => _timeRe.firstMatch(name)?.group(1);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sportsEventsProvider);
    return SafeArea(
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (all) {
          final events = all
              .where((e) => !e.name.toLowerCase().contains('no match'))
              .toList();
          if (events.isEmpty) {
            return const _Empty();
          }
          final grouped = <String, List<StreamItem>>{};
          for (final e in events) {
            grouped.putIfAbsent(_sportOf(e), () => []).add(e);
          }
          // Soccer first, then NBA (Basketball), then the rest; Other last.
          const order = [
            'Soccer',
            'Basketball',
            'American Football',
            'Ice Hockey',
            'Tennis',
            'Combat',
            'Motorsport',
            'Cricket',
            'Rugby',
            'Olympics',
            'Other Events',
          ];
          int rank(String s) {
            final i = order.indexOf(s);
            return i < 0 ? order.length : i;
          }

          final sports = grouped.keys.toList()
            ..sort((a, b) => rank(a).compareTo(rank(b)));

          return CustomScrollView(
            slivers: [
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Row(children: [
                    Icon(Icons.sports_soccer, color: LumenTheme.accent),
                    SizedBox(width: 8),
                    Text('Sports',
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w900)),
                  ]),
                ),
              ),
              for (final sport in sports) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
                    child: Row(children: [
                      Text(sport,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w800)),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 1),
                        decoration: BoxDecoration(
                            color: LumenTheme.surfaceHi,
                            borderRadius: BorderRadius.circular(20)),
                        child: Text('${grouped[sport]!.length}',
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFF9AA0B0))),
                      ),
                    ]),
                  ),
                ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => _EventTile(
                        item: grouped[sport]![i],
                        time: _timeOf(grouped[sport]![i].name)),
                    childCount: grouped[sport]!.length,
                  ),
                ),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: 28)),
            ],
          );
        },
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.item, this.time});
  final StreamItem item;
  final String? time;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: FocusableItem(
        borderRadius: 14,
        onActivate: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => PlayerScreen(item: item))),
        builder: (context, focused) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: focused ? LumenTheme.surfaceHi : LumenTheme.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              LogoImage(url: item.logo, size: 44, fallbackText: item.name),
              const SizedBox(width: 14),
              Expanded(
                child: Text(item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
              ),
              if (time != null) ...[
                const SizedBox(width: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: LumenTheme.accent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(time!,
                      style: const TextStyle(
                          color: LumenTheme.accent,
                          fontWeight: FontWeight.w700,
                          fontSize: 12)),
                ),
              ],
              const SizedBox(width: 8),
              const Icon(Icons.play_circle_fill,
                  color: LumenTheme.accent, size: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sports, size: 48, color: Color(0xFF3A3E4A)),
            SizedBox(height: 12),
            Text("No sports events detected in this source.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF6B7080))),
          ],
        ),
      ),
    );
  }
}
