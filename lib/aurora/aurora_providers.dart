import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
import '../data/repositories/library_repository.dart';
import '../data/sources/tmdb_service.dart';
import '../state/providers.dart';

/// Aurora keeps its own browse state (per-kind categories & selection) so the
/// classic UI's global kind/category providers stay untouched — both shells
/// can coexist in one binary without fighting over state.

/// Categories for the active source, keyed by kind. Movies / Shows / Live
/// pages each watch their own family instance, so they never clash.
final auroraCategoriesProvider = FutureProvider.autoDispose
    .family<List<Category>, StreamKind>((ref, kind) async {
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return [];
  return repo.categories(pl!.id!, kind);
});

/// Selected category name per kind (null = All).
final auroraGroupProvider =
    StateProvider.family<String?, StreamKind>((ref, kind) => null);

/// Combined My List for VOD (favorite movies + shows, newest first is the
/// repo order per kind; movies lead).
final auroraMyListProvider = FutureProvider<List<StreamItem>>((ref) async {
  final movies =
      await ref.watch(favoritesByKindProvider(StreamKind.movie).future);
  final shows =
      await ref.watch(favoritesByKindProvider(StreamKind.series).future);
  return [...movies, ...shows];
});

/// The Live Now rail on Home: your favorite channels, else a taste of the
/// first channels in the library.
final auroraLiveNowProvider = FutureProvider<List<StreamItem>>((ref) async {
  final favs =
      await ref.watch(favoritesByKindProvider(StreamKind.live).future);
  if (favs.isNotEmpty) return favs.take(20).toList();
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return [];
  return repo.page(
      playlistId: pl!.id!,
      kind: StreamKind.live,
      groupTitle: null,
      offset: 0,
      limit: 20);
});

/// Sports events bucketed by sport — ordered, non-empty buckets only.
final auroraSportsProvider =
    FutureProvider<List<(String, List<StreamItem>)>>((ref) async {
  final all = await ref.watch(sportsEventsProvider.future);
  const buckets = <String, List<String>>{
    'Soccer': [
      'soccer', 'football', 'fifa', 'world cup', 'uefa', 'premier',
      'la liga', 'serie a', 'bundesliga', 'champions',
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
  final grouped = <String, List<StreamItem>>{};
  for (final it in all) {
    final hay = '${it.name} ${it.groupTitle ?? ''}'.toLowerCase();
    var placed = false;
    for (final e in buckets.entries) {
      if (e.value.any(hay.contains)) {
        grouped.putIfAbsent(e.key, () => []).add(it);
        placed = true;
        break;
      }
    }
    if (!placed) grouped.putIfAbsent('More Events', () => []).add(it);
  }
  final order = [...buckets.keys, 'More Events'];
  return [
    for (final k in order)
      if ((grouped[k] ?? const []).isNotEmpty) (k, grouped[k]!),
  ];
});

/// "More Like This" for detail pages: TMDB recommendations matched back to
/// the user's own library (only titles they can actually play).
final auroraRecsProvider = FutureProvider.autoDispose
    .family<List<StreamItem>, ({String title, bool isShow})>((ref, args) async {
  if (!await ref.watch(tmdbEnabledProvider.future)) return [];
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return [];
  final svc = await ref.watch(tmdbServiceProvider.future);
  final recs = await svc.recommendationsFor(args.title, show: args.isShow);
  final out = <StreamItem>[];
  final seen = <int>{};
  for (final t in recs) {
    final hits = await repo.search(
      playlistId: pl!.id!,
      kind: args.isShow ? StreamKind.series : StreamKind.movie,
      query: t.title,
    );
    final hit = LibraryRepository.preferEnglish(hits);
    if (hit?.id != null && seen.add(hit!.id!)) {
      out.add(hit.copyWith(logo: t.poster ?? t.backdrop, rating: t.rating));
      if (out.length >= 14) break;
    }
  }
  return out;
});

/// The shell's selected tab.
final auroraTabProvider = StateProvider<int>((ref) => AuroraTab.home.index);

enum AuroraTab { search, home, movies, shows, live, sports, myStuff, settings }

@immutable
class AuroraTabSpec {
  final AuroraTab tab;
  final String label;
  final IconData? icon;
  const AuroraTabSpec(this.tab, this.label, [this.icon]);
}
