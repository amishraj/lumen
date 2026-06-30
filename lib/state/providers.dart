import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/app_database.dart';
import '../data/models/models.dart';
import '../data/repositories/library_repository.dart';
import '../data/sources/trakt_service.dart';

/// Database + repository singletons.
final databaseProvider = FutureProvider<AppDatabase>((ref) => AppDatabase.open());

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
final selectedKindProvider = StateProvider<StreamKind>((ref) => StreamKind.live);

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

/// Categories with pinned ones floated to the top — drives the sidebar.
final orderedCategoriesProvider =
    FutureProvider.autoDispose<List<Category>>((ref) async {
  final cats = await ref.watch(categoriesProvider.future);
  final pinned = await ref.watch(pinnedCategoriesProvider.future);
  final pinnedList = cats.where((c) => pinned.contains(c.name)).toList();
  final rest = cats.where((c) => !pinned.contains(c.name)).toList();
  return [...pinnedList, ...rest];
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

final featuredProvider = FutureProvider.autoDispose<List<StreamItem>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return [];
  // Prefer current popular movies (Trakt trending) that exist in the library.
  try {
    final svc = await ref.watch(traktServiceProvider.future);
    final trending = await svc.trendingMovies(limit: 30);
    final picks = <StreamItem>[];
    final seen = <int>{};
    for (final t in trending) {
      final hits = await repo.search(
          playlistId: pl!.id!, kind: StreamKind.movie, query: t.title);
      if (hits.isNotEmpty) {
        final m = hits.first;
        if (m.id != null &&
            seen.add(m.id!) &&
            (m.logo?.isNotEmpty ?? false)) {
          picks.add(m);
          if (picks.length >= 8) break;
        }
      }
    }
    if (picks.isNotEmpty) return picks;
  } catch (_) {/* fall back below */}
  return repo.featured(pl!.id!);
});

final continueWatchingProvider =
    FutureProvider.autoDispose<List<StreamItem>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return [];
  return repo.continueWatching(pl!.id!);
});

final recentlyWatchedProvider =
    FutureProvider.autoDispose<List<StreamItem>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return [];
  return repo.recentlyWatched(pl!.id!);
});

final favoritesListProvider =
    FutureProvider.autoDispose<List<StreamItem>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  ref.watch(favoriteIdsProvider); // refresh when favorites change
  return repo.favorites();
});

/// First N items of a kind (for "Movies for You" / "TV Shows" home rows).
final kindSampleProvider = FutureProvider.autoDispose
    .family<List<StreamItem>, StreamKind>((ref, kind) async {
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

const kAllHomeRows = <HomeRow>[
  HomeRow('continue', 'Continue Watching'),
  HomeRow('favorites', 'My Favorites'),
  HomeRow('recent', 'Recently Watched'),
  HomeRow('trakt_watchlist', 'Trakt Watchlist'),
  HomeRow('movies', 'Movies for You'),
  HomeRow('series', 'TV Shows'),
];

const _defaultHomeRows = 'continue,favorites,recent,movies,series';

/// Ordered list of enabled home-row ids, persisted in settings.
final homeConfigProvider =
    FutureProvider.autoDispose<List<String>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final raw = await repo.getSetting('home_rows') ?? _defaultHomeRows;
  return raw.split(',').where((s) => s.isNotEmpty).toList();
});

Future<void> saveHomeConfig(WidgetRef ref, List<String> ids) async {
  final repo = await ref.read(repositoryProvider.future);
  await repo.setSetting('home_rows', ids.join(','));
  ref.invalidate(homeConfigProvider);
}

final favoriteIdsProvider = FutureProvider.autoDispose<Set<int>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  return repo.favoriteIds();
});

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
