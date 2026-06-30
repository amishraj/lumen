import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/app_database.dart';
import '../data/models/models.dart';
import '../data/repositories/library_repository.dart';

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
