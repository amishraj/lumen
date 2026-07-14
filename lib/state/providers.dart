import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/app_database.dart';
import '../data/models/models.dart';
import '../data/repositories/library_repository.dart';
import '../data/sources/realdebrid_service.dart';
import '../data/sources/tmdb_service.dart';
import '../data/sources/trakt_service.dart';
import '../data/title_index.dart';

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
  final plId = pl!.id!;
  // Search each kind independently. A single blended query shares one 200-row
  // cap, and IPTV libraries are overwhelmingly live channels — so a common
  // token fills every slot with live matches and movies/series never surface.
  // Per-kind queries guarantee each rail gets its own budget. TMDB multi
  // search runs alongside (short-timeout, session-cached) so debrid-playable
  // titles the library lacks appear too.
  final tmdbEnabled = await ref.watch(tmdbEnabledProvider.future);
  final results = await Future.wait([
    repo.search(playlistId: plId, kind: StreamKind.live, query: q, limit: 60),
    repo.search(playlistId: plId, kind: StreamKind.movie, query: q, limit: 60),
    repo.search(playlistId: plId, kind: StreamKind.series, query: q, limit: 60),
    if (tmdbEnabled)
      ref
          .watch(tmdbServiceProvider.future)
          .then((svc) => svc.searchTitles(q))
          .catchError((Object _) => const <TmdbItem>[])
    else
      Future.value(const <TmdbItem>[]),
  ]);
  final live = results[0] as List<StreamItem>;
  final movies = results[1] as List<StreamItem>;
  final series = results[2] as List<StreamItem>;
  final tmdb = results[3] as List<TmdbItem>;

  // One card per title: IPTV libraries carry the same movie/show in many
  // languages and qualities, which read as confusing duplicates. Group by
  // normalized title, keep the English-preferred entry, and enrich it with
  // TMDB art when we have it. Live channels stay un-deduped — their variants
  // (HD/FHD/regional feeds) are meaningfully different.
  var rdOn = false;
  try {
    rdOn = await ref.read(rdEnabledProvider.future);
  } catch (_) {}

  List<StreamItem> dedupe(List<StreamItem> items) {
    final byKey = <String, List<StreamItem>>{};
    final order = <String>[];
    for (final it in items) {
      var key = TitleIndex.normalize(it.name);
      if (key.isEmpty) key = it.name.toLowerCase();
      (byKey[key] ??= (() {
        order.add(key);
        return <StreamItem>[];
      })())
          .add(it);
    }
    return [
      for (final key in order)
        LibraryRepository.preferEnglish(byKey[key]!) ?? byKey[key]!.first,
    ];
  }

  var outMovies = dedupe(movies);
  var outSeries = dedupe(series);

  if (tmdb.isNotEmpty) {
    final movieKeys = {for (final m in outMovies) TitleIndex.normalize(m.name)};
    final seriesKeys = {
      for (final s in outSeries) TitleIndex.normalize(s.name)
    };
    StreamItem enrich(StreamItem it, TmdbItem t) =>
        it.copyWith(logo: t.poster ?? t.backdrop ?? it.logo, rating: t.rating);
    for (final t in tmdb) {
      final key = TitleIndex.normalize(t.title);
      if (key.isEmpty) continue;
      final keys = t.isShow ? seriesKeys : movieKeys;
      final list = t.isShow ? outSeries : outMovies;
      final at = list.indexWhere((e) => TitleIndex.normalize(e.name) == key);
      if (at >= 0) {
        list[at] = enrich(list[at], t); // library entry, better art
      } else if (rdOn && keys.add(key)) {
        // Not in the library — one debrid-playable entry, Stremio-style.
        list.add(StreamItem(
          playlistId: plId,
          kind: t.isShow ? StreamKind.series : StreamKind.movie,
          name: t.title,
          logo: t.poster ?? t.backdrop,
          url: '',
          rating: t.rating,
        ));
      }
    }
  }

  return GroupedResults(live, outMovies, outSeries);
});

// ---------------------------------------------------------------------------
// In-memory title index
// ---------------------------------------------------------------------------

/// Bumped after a playlist re-sync so the index rebuilds over the new rows.
final titleIndexRevProvider = StateProvider<int>((ref) => 0);

/// The active source's movie/series titles, indexed in memory. ONE query to
/// build; every discovery row / Trakt reconciliation matches against this
/// instead of firing hundreds of serial LIKE scans at SQLite (which also
/// queue behind a running playlist re-sync on sqflite's single connection).
final titleIndexProvider = FutureProvider<TitleIndex?>((ref) async {
  ref.watch(titleIndexRevProvider);
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return null;
  final items = await repo.vodItems(pl!.id!);
  // Normalising tens of thousands of names is CPU work — off the UI thread.
  return compute(TitleIndex.build, (pl.id!, items));
});

// ---------------------------------------------------------------------------
// Home feed
// ---------------------------------------------------------------------------

String encodeStreamItems(List<StreamItem> items) =>
    jsonEncode([for (final it in items) it.toJson()]);

List<StreamItem> decodeStreamItems(String raw) => [
      for (final j in jsonDecode(raw) as List)
        StreamItem.fromJson(Map<String, Object?>.from(j as Map)),
    ];

/// Stale-while-revalidate disk snapshot for a computed home row.
///
/// The last computed row is persisted in app_settings; on the next app open it
/// paints IMMEDIATELY (one tiny key read — no network, no title matching),
/// while [compute] re-derives the row in the background and re-emits only if
/// something actually changed. This is what makes home content appear the
/// moment the app opens instead of minutes later.
Future<List<StreamItem>> snapshotStreamRow(
  Ref ref,
  String key,
  Future<List<StreamItem>> Function() compute,
) async {
  final repo = await ref.watch(repositoryProvider.future);
  final raw = await repo.getSetting(key);
  if (raw != null && raw.isNotEmpty) {
    List<StreamItem>? cached;
    try {
      cached = decodeStreamItems(raw);
    } catch (_) {
      cached = null; // corrupt — recompute below
    }
    if (cached != null) {
      unawaited(() async {
        try {
          final fresh = await compute();
          if (fresh.isEmpty) return; // keep last good snapshot
          final enc = encodeStreamItems(fresh);
          if (enc == raw) return;
          await repo.setSetting(key, enc);
          ref.invalidateSelf(); // re-emit with the fresh row
        } catch (_) {/* offline — snapshot stays */}
      }());
      return cached;
    }
  }
  final fresh = await compute();
  if (fresh.isNotEmpty) {
    try {
      await repo.setSetting(key, encodeStreamItems(fresh));
    } catch (_) {/* non-fatal */}
  }
  return fresh;
}

/// Featured banner = movies trending THIS WEEK, matched to the library (or
/// kept as debrid-playable picks when Real-Debrid is on). TMDB weekly trending
/// when a key is set (backdrop art for the hero), otherwise Trakt trending;
/// finally the library's own featured picks. Snapshot-backed: paints instantly
/// on reopen, refreshes in the background.
final featuredProvider = FutureProvider<List<StreamItem>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return [];
  final plId = pl!.id!;

  Future<List<StreamItem>> computeRow() async {
    final idx = await ref.read(titleIndexProvider.future);
    var rdOn = false;
    try {
      rdOn = await ref.read(rdEnabledProvider.future);
    } catch (_) {}

    List<StreamItem> match(List<(String title, String? art)> trending) {
      final picks = <StreamItem>[];
      final seenIds = <int>{};
      final seenNames = <String>{};
      for (final (title, art) in trending) {
        final m = idx?.match(title, kind: StreamKind.movie);
        if (m?.id != null && seenIds.add(m!.id!)) {
          // Prefer a wide TMDB backdrop for the cinematic hero.
          picks.add(m.copyWith(logo: art ?? m.logo));
        } else if (m == null &&
            rdOn &&
            art != null &&
            seenNames.add(title.toLowerCase())) {
          // Not in the IPTV library but Real-Debrid can play it — keep it,
          // Stremio-style, instead of silently shrinking the hero deck.
          picks.add(StreamItem(
              playlistId: plId,
              kind: StreamKind.movie,
              name: title,
              logo: art,
              url: ''));
        }
        if (picks.length >= 10) break;
      }
      return picks;
    }

    // TMDB weekly trending (best: gives backdrops).
    try {
      if (await ref.read(tmdbEnabledProvider.future)) {
        final svc = await ref.read(tmdbServiceProvider.future);
        final picks = match([
          for (final t in await svc.trendingMoviesWeek()) (t.title, t.backdrop),
        ]);
        if (picks.isNotEmpty) return picks;
      }
    } catch (_) {/* fall through */}

    // Trakt trending (works with the embedded key, no user setup).
    try {
      final svc = await ref.read(traktServiceProvider.future);
      final picks = match([
        for (final t in await svc.trendingMovies(limit: 30)) (t.title, null),
      ]);
      // Only use these if some carry art — otherwise fall through to the pure
      // IPTV featured set below rather than returning an artless (blank) hero.
      final withArt = picks.where((m) => m.logo != null).toList();
      if (withArt.isNotEmpty) return withArt;
    } catch (_) {/* fall through */}

    // Final fallback: the source's own IPTV library — always available offline.
    return repo.featured(plId);
  }

  return snapshotStreamRow(ref, 'home:snap:$plId:featured', computeRow);
});

/// Bumped when the user dismisses a Continue Watching entry so the row
/// recomputes immediately.
final cwHiddenRevProvider = StateProvider<int>((ref) => 0);

/// Stable dismiss-key for a Continue Watching entry. Series key on the show
/// title (an episode-derived row and the library's series entry must dismiss
/// together); everything else keys on the stream url, which survives the id
/// reassignment of a playlist re-sync.
/// Keyed on the normalized TITLE (not the stream url) so the same movie in
/// several languages/qualities collapses to ONE Continue Watching card — two
/// url-keyed variants was what showed two dismiss ✕s — and dismissing hides
/// every variant of that title.
String cwDismissKey(StreamItem item) {
  final norm = TitleIndex.normalize(item.name);
  final base = norm.isEmpty ? item.name.toLowerCase() : norm;
  return item.kind == StreamKind.series ? 'show:$base' : 'movie:$base';
}

/// key → dismissed-at ms. Kept as a map (not a set) so replaying something
/// after dismissing it resurfaces the row — newer activity wins.
Future<Map<String, int>> loadCwHidden(LibraryRepository repo) async {
  try {
    final raw = await repo.getSetting('cw_hidden');
    if (raw == null || raw.isEmpty) return {};
    return (jsonDecode(raw) as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, (v as num).toInt()));
  } catch (_) {
    return {};
  }
}

/// Hide an entry from Continue Watching WITHOUT touching tracked progress —
/// resume points, watched flags and Trakt state all stay intact.
Future<void> dismissFromContinueWatching(
    WidgetRef ref, StreamItem item) async {
  final repo = await ref.read(repositoryProvider.future);
  final map = await loadCwHidden(repo);
  map[cwDismissKey(item)] = DateTime.now().millisecondsSinceEpoch;
  await repo.setSetting('cw_hidden', jsonEncode(map));
  ref.read(cwHiddenRevProvider.notifier).state++;
  ref.invalidate(continueWatchingProvider);
}

/// Continue Watching: local activity paints IMMEDIATELY (it's the source of
/// truth for this device) — stream-backed items from the progress table plus
/// one entry per show derived from per-episode progress (an episode mid-watch
/// resumes it; a recently finished one surfaces the show for "up next").
/// Trakt's cross-device resume items append from the last known snapshot and
/// re-derive in the background (memory-matched via the title index — no SQL).
/// Dismissed entries stay hidden until newer activity resurfaces them.
final continueWatchingProvider = FutureProvider<List<StreamItem>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return [];
  final plId = pl!.id!;
  ref.watch(cwHiddenRevProvider);
  final hidden = await loadCwHidden(repo);
  // valueOrNull: never gate the row on the index build — show entries render
  // as synthetic items first and upgrade to library entries (with art) when
  // the index lands, since watching it re-runs this provider.
  final idx = ref.watch(titleIndexProvider).valueOrNull;

  final localMovies = await repo.continueWatching(plId);
  final ts = await repo.db.progressTimestamps();

  // One row per show from per-episode progress, newest activity first.
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  const recentFinishWindowMs = 30 * 24 * 3600 * 1000;
  final eps = await repo.db.episodeProgressAll();
  final byShow = <String, int>{}; // show title (from ep_key) → latest ms
  eps.forEach((key, p) {
    final bar = key.lastIndexOf('|');
    if (bar <= 0) return;
    final title = key.substring(0, bar);
    final inProgress = !p.watched && p.fraction > 0.02 && p.fraction < 0.97;
    final recentFinish =
        p.watched && nowMs - p.updatedAt < recentFinishWindowMs;
    if (!inProgress && !recentFinish) return;
    if (p.updatedAt > (byShow[title] ?? -1)) byShow[title] = p.updatedAt;
  });
  // ep_key titles are stored lowercase; title-case the synthetic fallback so
  // the card doesn't read as "breaking bad" while the index is still building.
  String titleCase(String s) => s
      .split(' ')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
  final showEntries = <(StreamItem, int)>[
    for (final e in byShow.entries)
      (
        idx?.match(e.key, kind: StreamKind.series) ??
            StreamItem(
                playlistId: plId,
                kind: StreamKind.series,
                name: titleCase(e.key),
                url: ''),
        e.value,
      ),
  ];

  final combined = <(StreamItem, int)>[
    for (final m in localMovies) (m, m.id != null ? (ts[m.id] ?? 0) : 0),
    ...showEntries,
  ]..sort((a, b) => b.$2.compareTo(a.$2));

  final result = <StreamItem>[];
  final seenKeys = <String>{};
  void add(StreamItem it, int at) {
    final key = cwDismissKey(it);
    final hiddenAt = hidden[key];
    if (hiddenAt != null && at <= hiddenAt) return; // dismissed, no new play
    if (seenKeys.add(key)) result.add(it);
  }

  for (final (it, at) in combined) {
    add(it, at);
  }

  // Keys from LOCAL activity ONLY — the background Trakt merge is computed
  // against this, never against `result` (which also holds the snapshot
  // extras below). Basing it on `result` made the merge oscillate — it wrote
  // [] (extras already in result), invalidated, recomputed with them gone,
  // wrote them back, invalidated… forever. That was the flicker.
  final baseKeys = Set<String>.of(seenKeys);

  final extrasKey = 'home:snap:$plId:cw_extras';
  final raw = await repo.getSetting(extrasKey);
  if (raw != null && raw.isNotEmpty) {
    try {
      for (final it in decodeStreamItems(raw)) {
        add(it, 0); // cross-device rows: any dismissal wins until replayed
      }
    } catch (_) {/* corrupt snapshot — background refresh rewrites it */}
  }

  unawaited(() async {
    try {
      if (!await ref.read(traktConnectedProvider.future)) return;
      final svc = await ref.read(traktServiceProvider.future);
      final index = await ref.read(titleIndexProvider.future);
      if (index == null) return;
      final extras = <StreamItem>[];
      final xKeys = <String>{};
      for (final p in (await svc.playback()).take(20)) {
        final hit = index.matchVod(p.item.title);
        if (hit == null) continue;
        final key = cwDismissKey(hit);
        // Skip anything already shown from local activity, and de-dupe the
        // extras themselves. Deterministic → this settles after one write.
        if (baseKeys.contains(key) || !xKeys.add(key)) continue;
        extras.add(hit);
      }
      final enc = encodeStreamItems(extras);
      if (enc != raw) {
        await repo.setSetting(extrasKey, enc);
        ref.invalidateSelf();
      }
    } catch (_) {/* offline / not connected — local list already shown */}
  }());
  return result;
});

/// Set of library item ids the user has watched — locally and (synced once an
/// hour, or immediately after the app-open Trakt refresh finds changes) from
/// Trakt's watched history. Drives the "seen" check on posters.
final watchedIdsProvider = FutureProvider<Set<int>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return {};

  // Return the locally-known "seen" set IMMEDIATELY so the marks paint on the
  // first frame. The Trakt reconciliation (title-matching 300 entries) runs in
  // the BACKGROUND against the in-memory index — zero SQL reads, one batched
  // write — and re-invalidates this provider when it lands.
  final local = await repo.watchedIds(pl!.id!);
  final last =
      int.tryParse(await repo.getSetting('trakt_watched_sync_at') ?? '') ?? 0;
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  if (nowMs - last > 3600 * 1000) {
    unawaited(() async {
      try {
        if (!await ref.read(traktConnectedProvider.future)) return;
        final svc = await ref.read(traktServiceProvider.future);
        final idx = await ref.read(titleIndexProvider.future);
        if (idx == null) return;
        final toMark = <int>{};
        for (final w in (await svc.watchedMovies()).take(300)) {
          final hit = idx.match(w.title, kind: StreamKind.movie);
          if (hit?.id != null && !local.contains(hit!.id)) toMark.add(hit.id!);
        }
        for (final w in (await svc.watchedShows()).take(300)) {
          final hit = idx.match(w.title, kind: StreamKind.series);
          if (hit?.id != null && !local.contains(hit!.id)) toMark.add(hit.id!);
        }
        await repo.markWatchedMany(toMark);
        await repo.setSetting('trakt_watched_sync_at', '$nowMs');
        if (toMark.isNotEmpty) {
          ref.invalidateSelf(); // re-read with the freshly-marked ids
        }
      } catch (_) {/* best effort — keep the local set */}
    }());
  }
  return local;
});

/// stream id → watched fraction (0..1). Local progress paints immediately,
/// overlaid with the last known Trakt cross-device resume points; the Trakt
/// overlay re-derives in the background (memory-matched) and re-emits on
/// change — so partial progress shows no matter where you watched, without
/// ever gating the home paint on the network.
final progressFractionsProvider = FutureProvider<Map<int, double>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final map = await repo.progressFractions();
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return map;
  final plId = pl!.id!;

  final extrasKey = 'home:snap:$plId:progress_extras';
  final raw = await repo.getSetting(extrasKey);
  if (raw != null && raw.isNotEmpty) {
    try {
      (jsonDecode(raw) as Map<String, dynamic>).forEach((k, v) {
        final id = int.tryParse(k);
        if (id != null && v is num && !map.containsKey(id)) {
          map[id] = v.toDouble().clamp(0.0, 1.0);
        }
      });
    } catch (_) {/* corrupt snapshot — background refresh rewrites it */}
  }

  unawaited(() async {
    try {
      if (!await ref.read(traktConnectedProvider.future)) return;
      final svc = await ref.read(traktServiceProvider.future);
      final idx = await ref.read(titleIndexProvider.future);
      if (idx == null) return;
      final extras = <String, double>{};
      for (final p in (await svc.playback()).take(30)) {
        final hit = idx.matchVod(p.item.title);
        if (hit?.id != null) {
          extras['${hit!.id}'] = p.progress.clamp(0.0, 1.0);
        }
      }
      // Canonical (key-sorted) encoding so the compare is insertion-order
      // independent — a self-invalidate must fire only on a real change.
      final enc = jsonEncode({
        for (final k in extras.keys.toList()..sort()) k: extras[k],
      });
      if (enc != raw) {
        await repo.setSetting(extrasKey, enc);
        ref.invalidateSelf();
      }
    } catch (_) {/* offline — local progress still shows */}
  }());
  return map;
});

final recentlyWatchedProvider = FutureProvider<List<StreamItem>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return [];
  return repo.recentlyWatched(pl!.id!);
});

/// Every started episode's local progress, keyed by ep_key — backs the
/// watched/season marks in the player's Episodes panel. autoDispose: the
/// underlying table is tiny and re-read on each panel open, so marks are
/// always current.
final episodeProgressProvider = FutureProvider.autoDispose<
    Map<String, ({double fraction, bool watched, int updatedAt})>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  return repo.db.episodeProgressAll();
});

/// (season, episode) pairs watched on Trakt for a show title — so the series
/// page can mark episodes seen even when they were watched on another device.
/// Empty when Trakt is off; cached by the service so it's cheap to watch.
final traktWatchedEpisodesProvider =
    FutureProvider.family<Set<(int, int)>, String>((ref, title) async {
  try {
    if (!await ref.watch(traktConnectedProvider.future)) return {};
    final svc = await ref.watch(traktServiceProvider.future);
    return svc.watchedEpisodesFor(title);
  } catch (_) {
    return {};
  }
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

/// Favorite stream ids for the active source. Backed by a notifier so a toggle
/// can flip the set *optimistically* — every watcher (buttons, hearts, rails)
/// updates the same frame, before the DB write round-trips.
final favoriteIdsProvider =
    AsyncNotifierProvider<FavoriteIdsNotifier, Set<int>>(
        FavoriteIdsNotifier.new);

class FavoriteIdsNotifier extends AsyncNotifier<Set<int>> {
  @override
  Future<Set<int>> build() async {
    final repo = await ref.watch(repositoryProvider.future);
    return repo.favoriteIds();
  }

  /// Flip a single id in-place so the UI reacts instantly, then persist.
  /// Reverts the optimistic change if the write fails.
  Future<void> toggle(int id, bool fav) async {
    final previous = state.valueOrNull ?? const <int>{};
    final next = Set<int>.of(previous);
    fav ? next.add(id) : next.remove(id);
    state = AsyncData(next);
    try {
      final repo = await ref.read(repositoryProvider.future);
      await repo.toggleFavorite(id, fav);
    } catch (_) {
      state = AsyncData(previous);
      rethrow;
    }
  }
}

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
  // Optimistic + persisted: flips favoriteIds this frame so buttons/hearts react
  // instantly; the write is awaited inside toggle(). Then re-query the DB-backed
  // favorite rails now that the row exists, so they reflect the change too.
  await ref.read(favoriteIdsProvider.notifier).toggle(item.id!, fav);
  ref.invalidate(favoritesListProvider);
  ref.invalidate(favoritesByKindProvider(item.kind));
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
