import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/app_database.dart';
import '../data/models/models.dart';
import '../data/repositories/library_repository.dart';
import '../data/sources/tmdb_service.dart';
import '../data/sources/trakt_service.dart';

/// Database + repository singletons.
final databaseProvider =
    FutureProvider<AppDatabase>((ref) => AppDatabase.open());

final repositoryProvider = FutureProvider<LibraryRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return LibraryRepository(db);
});

/// All configured sources.
final playlistsProvider = FutureProvider<List<Playlist>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  return repo.playlists();
});

/// Currently selected source + content kind (live / movie / series).
final activePlaylistProvider = StateProvider<Playlist?>((ref) => null);
final selectedKindProvider =
    StateProvider<StreamKind>((ref) => StreamKind.live);

/// Categories for the active source + kind.
final categoriesProvider =
    FutureProvider.autoDispose<List<Category>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  final kind = ref.watch(selectedKindProvider);
  if (pl?.id == null) return [];
  return repo.categories(pl!.id!, kind);
});

/// The category the user is browsing (null = first/all).
final selectedCategoryProvider = StateProvider<Category?>((ref) => null);

/// Names of pinned categories for the active source + kind.
final pinnedCategoriesProvider =
    FutureProvider.autoDispose<Set<String>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  final kind = ref.watch(selectedKindProvider);
  if (pl?.id == null) return {};
  return (await repo.pinnedCategories(pl!.id!, kind)).toSet();
});

/// Sentinel category that surfaces the user's favorites of the selected kind
/// at the top of the sidebar (e.g. favorited live channels).
const kFavoritesCategory = '★ My Favorites';

/// Categories with the favorites pseudo-category first, then pinned ones,
/// then the rest — drives the sidebar.
final orderedCategoriesProvider =
    FutureProvider.autoDispose<List<Category>>((ref) async {
  final cats = await ref.watch(categoriesProvider.future);
  final pinned = await ref.watch(pinnedCategoriesProvider.future);
  final pinnedList = cats.where((c) => pinned.contains(c.name)).toList();
  final rest = cats.where((c) => !pinned.contains(c.name)).toList();
  // Favorites-of-kind pseudo-category (only when non-empty).
  final favs = <Category>[];
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id != null) {
    ref.watch(favoriteIdsProvider); // re-run when favorites change
    final repo = await ref.watch(repositoryProvider.future);
    final kind = ref.watch(selectedKindProvider);
    final list = await repo.favoritesByKind(pl!.id!, kind);
    if (list.isNotEmpty) {
      favs.add(Category(
        id: '${pl.id}:${kind.name}:$kFavoritesCategory',
        playlistId: pl.id!,
        kind: kind,
        name: kFavoritesCategory,
        count: list.length,
      ));
    }
  }
  return [...favs, ...pinnedList, ...rest];
});

/// Persisted, resizable Live-TV sidebar width.
class SidebarWidthNotifier extends StateNotifier<double> {
  SidebarWidthNotifier(this.ref) : super(248) {
    _load();
  }
  final Ref ref;
  static const minW = 170.0;
  static const maxW = 560.0;

  Future<void> _load() async {
    final repo = await ref.read(repositoryProvider.future);
    final v = double.tryParse(await repo.getSetting('sidebar_width') ?? '');
    if (v != null) state = v.clamp(minW, maxW);
  }

  void update(double w) => state = w.clamp(minW, maxW);

  Future<void> persist() async {
    final repo = await ref.read(repositoryProvider.future);
    await repo.setSetting('sidebar_width', state.toStringAsFixed(0));
  }
}

final sidebarWidthProvider =
    StateNotifierProvider<SidebarWidthNotifier, double>(
        (ref) => SidebarWidthNotifier(ref));

/// Master-search results grouped by kind (live first). Drives the global search.
class GroupedResults {
  final List<StreamItem> live;
  final List<StreamItem> movies;
  final List<StreamItem> series;
  const GroupedResults(this.live, this.movies, this.series);
  bool get isEmpty => live.isEmpty && movies.isEmpty && series.isEmpty;
}

final groupedSearchProvider =
    FutureProvider.autoDispose<GroupedResults>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  final q = ref.watch(searchQueryProvider).trim();
  if (pl?.id == null || q.length < 2) {
    return const GroupedResults([], [], []);
  }
  final all = await repo.search(playlistId: pl!.id!, query: q);
  return GroupedResults(
    all.where((e) => e.kind == StreamKind.live).toList(),
    all.where((e) => e.kind == StreamKind.movie).toList(),
    all.where((e) => e.kind == StreamKind.series).toList(),
  );
});

// ---------------------------------------------------------------------------
// Home feed
// ---------------------------------------------------------------------------

/// Featured banner = movies trending THIS WEEK, matched to the library.
/// TMDB weekly trending when a key is set (with backdrop art for the hero),
/// otherwise Trakt trending; finally the library's own featured picks.
final featuredProvider = FutureProvider<List<StreamItem>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return [];

  Future<List<StreamItem>> match(
      List<(String title, String? art)> trending) async {
    final picks = <StreamItem>[];
    final seen = <int>{};
    for (final (title, art) in trending) {
      final hits = await repo.search(
          playlistId: pl!.id!, kind: StreamKind.movie, query: title);
      final m = LibraryRepository.preferEnglish(hits);
      if (m?.id != null && seen.add(m!.id!)) {
        // Prefer a wide TMDB backdrop for the cinematic hero.
        picks.add(m.copyWith(logo: art ?? m.logo));
        if (picks.length >= 10) break;
      }
    }
    return picks;
  }

  // TMDB weekly trending (best: gives backdrops).
  try {
    if (await ref.watch(tmdbEnabledProvider.future)) {
      final svc = await ref.watch(tmdbServiceProvider.future);
      final picks = await match([
        for (final t in await svc.trendingMoviesWeek()) (t.title, t.backdrop),
      ]);
      if (picks.isNotEmpty) return picks;
    }
  } catch (_) {/* fall through */}

  // Trakt trending (works with the embedded key, no user setup).
  try {
    final svc = await ref.watch(traktServiceProvider.future);
    final picks = await match([
      for (final t in await svc.trendingMovies(limit: 30)) (t.title, null),
    ]);
    if (picks.isNotEmpty) return picks.where((m) => m.logo != null).toList();
  } catch (_) {/* fall through */}

  return repo.featured(pl!.id!);
});

final continueWatchingProvider = FutureProvider<List<StreamItem>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return [];
  final local = await repo.continueWatching(pl!.id!);
  final result = <StreamItem>[...local];
  final seen = local.map((e) => e.id).toSet();
  // Merge Trakt's cross-device in-progress items, matched to the library.
  try {
    final connected = await ref.watch(traktConnectedProvider.future);
    if (connected) {
      final svc = await ref.watch(traktServiceProvider.future);
      for (final p in (await svc.playback()).take(20)) {
        final hit = await repo.findByTitle(pl.id!, p.item.title);
        if (hit != null && !seen.contains(hit.id)) {
          result.add(hit);
          seen.add(hit.id);
        }
      }
    }
  } catch (_) {/* offline / not connected */}
  return result;
});

/// Set of library item ids the user has watched — locally and (synced once an
/// hour) from Trakt's watched history. Drives the "seen" check on posters.
final watchedIdsProvider = FutureProvider<Set<int>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return {};
  try {
    final connected = await ref.watch(traktConnectedProvider.future);
    if (connected) {
      final last =
          int.tryParse(await repo.getSetting('trakt_watched_sync_at') ?? '') ??
              0;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - last > 3600 * 1000) {
        final svc = await ref.watch(traktServiceProvider.future);
        // Movies AND shows — matched to the library with the EN-preferring
        // title search, so a watch on any language variant marks the same
        // title here.
        for (final w in (await svc.watchedMovies()).take(150)) {
          final hit = await repo.findByTitle(pl!.id!, w.title);
          if (hit?.id != null && hit!.kind == StreamKind.movie) {
            await repo.markWatched(hit.id!);
          }
        }
        for (final w in (await svc.watchedShows()).take(150)) {
          final hit = await repo.findByTitle(pl!.id!, w.title);
          if (hit?.id != null && hit!.kind == StreamKind.series) {
            await repo.markWatched(hit.id!);
          }
        }
        await repo.setSetting('trakt_watched_sync_at', '$nowMs');
      }
    }
  } catch (_) {/* best effort */}
  return repo.watchedIds(pl!.id!);
});

/// stream id → watched fraction (0..1). Local progress first, overlaid with
/// Trakt's cross-device resume points (matched by EN-preferring title search)
/// so partial progress shows no matter where you watched.
final progressFractionsProvider = FutureProvider<Map<int, double>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final map = await repo.progressFractions();
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return map;
  try {
    final connected = await ref.watch(traktConnectedProvider.future);
    if (connected) {
      final svc = await ref.watch(traktServiceProvider.future);
      for (final p in (await svc.playback()).take(30)) {
        final hit = await repo.findByTitle(pl!.id!, p.item.title);
        if (hit?.id != null && !map.containsKey(hit!.id)) {
          map[hit.id!] = p.progress.clamp(0.0, 1.0);
        }
      }
    }
  } catch (_) {/* offline — local progress still shows */}
  return map;
});

final recentlyWatchedProvider = FutureProvider<List<StreamItem>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return [];
  return repo.recentlyWatched(pl!.id!);
});

final favoritesListProvider = FutureProvider<List<StreamItem>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  ref.watch(favoriteIdsProvider); // refresh when favorites change
  return repo.favorites();
});

/// Event-style live channels for the Sports tab.
final sportsEventsProvider = FutureProvider<List<StreamItem>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return [];
  return repo.sportsEvents(pl!.id!);
});

/// First N items of a kind (for "Movies for You" / "TV Shows" home rows).
final kindSampleProvider =
    FutureProvider.family<List<StreamItem>, StreamKind>((ref, kind) async {
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return [];
  return repo.page(
      playlistId: pl!.id!, kind: kind, groupTitle: null, offset: 0, limit: 20);
});

/// Catalogue of home rows the user can toggle/reorder.
class HomeRow {
  final String id;
  final String label;
  const HomeRow(this.id, this.label);
}

// Note: the Trakt watchlist + custom lists render always-on when connected
// (see home_feed_screen), so they're intentionally not toggleable rows here.
const kAllHomeRows = <HomeRow>[
  HomeRow('continue', 'Continue Watching'),
  HomeRow('favorites', 'My Favorites'),
  HomeRow('recent', 'Recently Watched'),
  HomeRow('movies', 'Movies for You'),
  HomeRow('series', 'TV Shows'),
];

const _defaultHomeRows = 'continue,favorites,recent,movies,series';

/// Ordered list of enabled home-row ids, persisted in settings.
final homeConfigProvider = FutureProvider<List<String>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final raw = await repo.getSetting('home_rows') ?? _defaultHomeRows;
  return raw.split(',').where((s) => s.isNotEmpty).toList();
});

Future<void> saveHomeConfig(WidgetRef ref, List<String> ids) async {
  final repo = await ref.read(repositoryProvider.future);
  await repo.setSetting('home_rows', ids.join(','));
  ref.invalidate(homeConfigProvider);
}

final favoriteIdsProvider = FutureProvider<Set<int>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  return repo.favoriteIds();
});

/// Favorites of one kind for the active source — backs the categorized
/// "My List" rows on Home. Re-runs whenever favorites change.
final favoritesByKindProvider =
    FutureProvider.family<List<StreamItem>, StreamKind>((ref, kind) async {
  ref.watch(favoriteIdsProvider);
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return [];
  return repo.favoritesByKind(pl!.id!, kind);
});

/// Refresh every provider that depends on the Trakt account. Must be called
/// after connect / disconnect / a health-check retry: home data is
/// session-cached now, so any provider missed here simply never updates.
void refreshTraktData(WidgetRef ref) {
  ref.invalidate(traktConnectedProvider);
  ref.invalidate(traktUsernameProvider);
  ref.invalidate(traktWatchlistProvider);
  ref.invalidate(traktListsProvider);
  ref.invalidate(featuredProvider);
  ref.invalidate(continueWatchingProvider);
  ref.invalidate(watchedIdsProvider);
}

/// Single entry point for favoriting: toggles locally, refreshes the favorite
/// providers, and (for movies/shows) mirrors the change onto the Trakt
/// watchlist so "My List" and Trakt stay the same list.
Future<void> setFavorite(WidgetRef ref, StreamItem item, bool fav) async {
  if (item.id == null) return;
  final repo = await ref.read(repositoryProvider.future);
  await repo.toggleFavorite(item.id!, fav);
  ref.invalidate(favoriteIdsProvider);
  ref.invalidate(favoritesListProvider);
  if (item.kind == StreamKind.movie || item.kind == StreamKind.series) {
    // Fire-and-forget: Trakt sync must never block or fail the local toggle.
    ref
        .read(traktServiceProvider)
        .valueOrNull
        ?.setInWatchlist(item.name,
            isShow: item.kind == StreamKind.series, inList: fav)
        .then((_) {
      try {
        ref.invalidate(traktWatchlistProvider);
      } catch (_) {/* screen gone */}
    });
  }
}

/// Search results (debounced query set by the search screen).
final searchQueryProvider = StateProvider.autoDispose<String>((ref) => '');

final searchResultsProvider =
    FutureProvider.autoDispose<List<StreamItem>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  final q = ref.watch(searchQueryProvider).trim();
  if (pl?.id == null || q.length < 2) return [];
  return repo.search(playlistId: pl!.id!, query: q);
});

// ---------------------------------------------------------------------------
// Paged channel loader — infinite scroll over a single category. Holds only a
// sliding window of rows in memory, never the full 40k set.
// ---------------------------------------------------------------------------

class ChannelPageState {
  final List<StreamItem> items;
  final bool loading;
  final bool reachedEnd;
  const ChannelPageState({
    this.items = const [],
    this.loading = false,
    this.reachedEnd = false,
  });

  ChannelPageState copyWith({
    List<StreamItem>? items,
    bool? loading,
    bool? reachedEnd,
  }) =>
      ChannelPageState(
        items: items ?? this.items,
        loading: loading ?? this.loading,
        reachedEnd: reachedEnd ?? this.reachedEnd,
      );
}

class ChannelPager extends StateNotifier<ChannelPageState> {
  ChannelPager(this._repo, this._playlistId, this._kind, this._group)
      : super(const ChannelPageState()) {
    loadMore();
  }

  /// Inert pager used while the repository is still initialising.
  ChannelPager.empty()
      : _repo = null,
        _playlistId = 0,
        _kind = StreamKind.live,
        _group = null,
        super(const ChannelPageState(reachedEnd: true));

  final LibraryRepository? _repo;
  final int _playlistId;
  final StreamKind _kind;
  final String? _group;
  static const _pageSize = 60;
  bool _busy = false;

  Future<void> loadMore() async {
    final repo = _repo;
    if (repo == null || _busy || state.reachedEnd) return;
    _busy = true;
    state = state.copyWith(loading: true);
    final page = await repo.page(
      playlistId: _playlistId,
      kind: _kind,
      groupTitle: _group,
      offset: state.items.length,
      limit: _pageSize,
    );
    state = state.copyWith(
      items: [...state.items, ...page],
      loading: false,
      reachedEnd: page.length < _pageSize,
    );
    _busy = false;
  }
}

/// Family keyed by the (playlist, kind, group) tuple so switching categories
/// spins up an isolated pager and disposes the old one.
final channelPagerProvider = StateNotifierProvider.autoDispose
    .family<ChannelPager, ChannelPageState, ChannelPageKey>((ref, key) {
  final repo = ref.watch(repositoryProvider).valueOrNull;
  if (repo == null) {
    return ChannelPager.empty();
  }
  return ChannelPager(repo, key.playlistId, key.kind, key.group);
});

@immutable
class ChannelPageKey {
  final int playlistId;
  final StreamKind kind;
  final String? group;
  const ChannelPageKey(this.playlistId, this.kind, this.group);

  @override
  bool operator ==(Object other) =>
      other is ChannelPageKey &&
      other.playlistId == playlistId &&
      other.kind == kind &&
      other.group == group;

  @override
  int get hashCode => Object.hash(playlistId, kind, group);
}
