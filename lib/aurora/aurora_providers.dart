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

/// Selected IPTV category name per kind (null = All). Used when TMDB is off.
final auroraGroupProvider =
    StateProvider.family<String?, StreamKind>((ref, kind) => null);

/// Selected TMDB genre id per kind (null = All / Popular). Used when TMDB is on
/// — the browse grid and the home category cards drive this.
final auroraGenreProvider =
    StateProvider.family<int?, StreamKind>((ref, kind) => null);

/// Whether TMDB governs listings (a key is present). When true, the Movies /
/// TV Shows browse pages are driven entirely by TMDB metadata.
final auroraTmdbGovernsProvider = FutureProvider<bool>((ref) async {
  return ref.watch(tmdbEnabledProvider.future);
});

/// TMDB genres for a kind (movie/tv), with a couple of stable brand colours
/// assigned for the home category cards.
final auroraTmdbGenresProvider = FutureProvider.autoDispose
    .family<List<TmdbGenre>, StreamKind>((ref, kind) async {
  if (!await ref.watch(tmdbEnabledProvider.future)) return const [];
  final svc = await ref.watch(tmdbServiceProvider.future);
  return svc.genres(show: kind == StreamKind.series);
});

/// Pinned category/genre names for the active source + kind (reuses the same
/// pinned_categories store the classic UI uses, so pins are shared).
final auroraPinnedProvider = FutureProvider.autoDispose
    .family<Set<String>, StreamKind>((ref, kind) async {
  ref.watch(auroraPinRevProvider);
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return {};
  return (await repo.pinnedCategories(pl!.id!, kind)).toSet();
});

/// Bumped after a pin toggle so the pinned set + ordered lists recompute.
final auroraPinRevProvider = StateProvider<int>((ref) => 0);

Future<void> toggleAuroraPin(
    WidgetRef ref, StreamKind kind, String name) async {
  final repo = await ref.read(repositoryProvider.future);
  final pl = ref.read(activePlaylistProvider);
  if (pl?.id == null) return;
  final current = (await repo.pinnedCategories(pl!.id!, kind)).contains(name);
  await repo.setPinned(pl.id!, kind, name, !current);
  ref.read(auroraPinRevProvider.notifier).state++;
}

/// TMDB genres ordered with pinned ones first — drives the browse chips.
final auroraOrderedGenresProvider = FutureProvider.autoDispose
    .family<List<TmdbGenre>, StreamKind>((ref, kind) async {
  final genres = await ref.watch(auroraTmdbGenresProvider(kind).future);
  final pinned = await ref.watch(auroraPinnedProvider(kind).future);
  final pin = genres.where((g) => pinned.contains(g.name)).toList();
  final rest = genres.where((g) => !pinned.contains(g.name)).toList();
  return [...pin, ...rest];
});

/// IPTV categories ordered with pinned ones first (TMDB-off browse + Live).
final auroraOrderedCategoriesProvider = FutureProvider.autoDispose
    .family<List<Category>, StreamKind>((ref, kind) async {
  final cats = await ref.watch(auroraCategoriesProvider(kind).future);
  final pinned = await ref.watch(auroraPinnedProvider(kind).future);
  final pin = cats.where((c) => pinned.contains(c.name)).toList();
  final rest = cats.where((c) => !pinned.contains(c.name)).toList();
  return [...pin, ...rest];
});

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

// ---------------------------------------------------------------------------
// TMDB catalog pager — the Movies / TV Shows browse grid when TMDB governs.
// Pages TMDB discovery and resolves each title against the user's library so
// matched items carry a playable id/url (and progress/seen overlays), while
// unmatched titles still show (playable via Real-Debrid, per the play flow).
// ---------------------------------------------------------------------------

class CatalogPageState {
  final List<StreamItem> items;
  final bool loading;
  final bool reachedEnd;
  const CatalogPageState({
    this.items = const [],
    this.loading = false,
    this.reachedEnd = false,
  });

  CatalogPageState copyWith({
    List<StreamItem>? items,
    bool? loading,
    bool? reachedEnd,
  }) =>
      CatalogPageState(
        items: items ?? this.items,
        loading: loading ?? this.loading,
        reachedEnd: reachedEnd ?? this.reachedEnd,
      );
}

class TmdbCatalogPager extends StateNotifier<CatalogPageState> {
  TmdbCatalogPager(this._svc, this._repo, this._plId, this._show, this._genreId)
      : super(const CatalogPageState()) {
    loadMore();
  }

  TmdbCatalogPager.empty()
      : _svc = null,
        _repo = null,
        _plId = 0,
        _show = false,
        _genreId = null,
        super(const CatalogPageState(reachedEnd: true));

  final TmdbService? _svc;
  final LibraryRepository? _repo;
  final int _plId;
  final bool _show;
  final int? _genreId;
  int _page = 0;
  bool _busy = false;
  static const _maxPages = 6;

  Future<void> loadMore() async {
    final svc = _svc, repo = _repo;
    if (svc == null || repo == null || _busy || state.reachedEnd) return;
    _busy = true;
    state = state.copyWith(loading: true);
    _page++;
    final tmdb = await svc.discover(show: _show, genreId: _genreId, page: _page);
    final kind = _show ? StreamKind.series : StreamKind.movie;
    final mapped = <StreamItem>[];
    for (final t in tmdb) {
      // Match to library for playability + overlays; keep the item regardless.
      final hits = await repo.search(playlistId: _plId, kind: kind, query: t.title);
      final hit = LibraryRepository.preferEnglish(hits);
      mapped.add(StreamItem(
        id: hit?.id,
        playlistId: _plId,
        kind: kind,
        name: t.title,
        logo: t.poster ?? t.backdrop,
        url: hit?.url ?? '',
        rating: t.rating,
      ));
    }
    state = state.copyWith(
      items: [...state.items, ...mapped],
      loading: false,
      reachedEnd: tmdb.length < 15 || _page >= _maxPages,
    );
    _busy = false;
  }
}

@immutable
class CatalogKey {
  final bool show;
  final int? genreId;
  const CatalogKey(this.show, this.genreId);
  @override
  bool operator ==(Object other) =>
      other is CatalogKey && other.show == show && other.genreId == genreId;
  @override
  int get hashCode => Object.hash(show, genreId);
}

final auroraCatalogPagerProvider = StateNotifierProvider.autoDispose
    .family<TmdbCatalogPager, CatalogPageState, CatalogKey>((ref, key) {
  final svc = ref.watch(tmdbServiceProvider).valueOrNull;
  final repo = ref.watch(repositoryProvider).valueOrNull;
  final pl = ref.watch(activePlaylistProvider);
  if (svc == null || repo == null || pl?.id == null) {
    return TmdbCatalogPager.empty();
  }
  return TmdbCatalogPager(svc, repo, pl!.id!, key.show, key.genreId);
});

/// The nav's focus target — the currently-selected tab's *stable* focus node,
/// published by the top bar each build. Pages call
/// `auroraNavTarget?.requestFocus()` to send focus back up to the active tab
/// (▲ from their top row). Kept as a plain field (not a per-tab focusNode swap)
/// so selecting a tab never re-parents a focus node mid-navigation — that swap
/// was what made the bar flicker.
FocusNode? auroraNavTarget;

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
