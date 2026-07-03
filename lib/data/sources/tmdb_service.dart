import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../repositories/library_repository.dart';
import '../../state/providers.dart';

/// The Movie Database (TMDB) — richer artwork (posters/backdrops), overviews,
/// genres, cast, and discovery lists (popular / trending / by-genre /
/// recommendations). Optional: nothing is fetched until the user pastes their
/// own free key in Settings → Metadata.
///
/// Get a free key at https://www.themoviedb.org/settings/api. Both the classic
/// v3 API key and a v4 read-access token are accepted.
class TmdbService {
  TmdbService(this._repo);
  final LibraryRepository _repo;

  static const _api = 'https://api.themoviedb.org/3';
  static const _img = 'https://image.tmdb.org/t/p';

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 12),
    validateStatus: (s) => s != null && s < 500,
  ));

  Future<String?> key() async => _repo.getSetting('tmdb_key');

  Future<bool> get enabled async => (await key())?.isNotEmpty ?? false;

  Future<void> saveKey(String k) => _repo.setSetting('tmdb_key', k.trim());

  /// Fast health probe: does the saved key authenticate against TMDB?
  Future<({bool configured, bool ok, String detail})> ping() async {
    final k = await key();
    if (k == null || k.isEmpty) {
      return (configured: false, ok: false, detail: 'No key set');
    }
    try {
      final (q, opts) = await _auth();
      final res = await _dio.get('$_api/configuration',
          queryParameters: q, options: opts);
      if (res.statusCode == 200) {
        return (configured: true, ok: true, detail: 'OK');
      }
      return (
        configured: true,
        ok: false,
        detail: res.statusCode == 401 ? 'Invalid key' : 'HTTP ${res.statusCode}'
      );
    } catch (_) {
      return (configured: true, ok: false, detail: 'Unreachable');
    }
  }

  /// TMDB accepts either a v3 key (as the `api_key` query param) or a v4 read
  /// token (as a Bearer header). v4 tokens are long JWTs starting with `eyJ`.
  Future<(Map<String, dynamic>, Options)> _auth() async {
    final k = (await key()) ?? '';
    if (k.startsWith('eyJ')) {
      return (
        <String, dynamic>{},
        Options(headers: {'Authorization': 'Bearer $k'})
      );
    }
    return (<String, dynamic>{'api_key': k}, Options());
  }

  /// Adaptive artwork quality: observed API latency decides between full
  /// 1080p-class art (w1280/w500) and lighter tiers (w780/w342), so slow
  /// connections still get instant-feeling rows instead of trickling images.
  static bool fastNet = true;

  static String? posterUrl(String? path, {String? size}) =>
      (path == null || path.isEmpty)
          ? null
          : '$_img/${size ?? (fastNet ? 'w500' : 'w342')}$path';
  static String? backdropUrl(String? path, {String? size}) =>
      (path == null || path.isEmpty)
          ? null
          : '$_img/${size ?? (fastNet ? 'w1280' : 'w780')}$path';

  /// Cached GET. List endpoints get a TTL so home rows refresh occasionally;
  /// pass ttl: null for permanent caching (per-title detail lookups).
  Future<dynamic> _cachedGet(
    String cacheKey,
    String path, {
    Map<String, dynamic> query = const {},
    Duration? ttl,
  }) async {
    final k = await key();
    if (k == null || k.isEmpty) return null;

    final cached = await _repo.getSetting(cacheKey);
    if (cached != null && cached.isNotEmpty) {
      try {
        final wrap = jsonDecode(cached) as Map<String, dynamic>;
        final at = wrap['at'] as int? ?? 0;
        final fresh = ttl == null ||
            DateTime.now().millisecondsSinceEpoch - at < ttl.inMilliseconds;
        if (fresh) return wrap['v'];
      } catch (_) {/* corrupt cache — refetch */}
    }

    try {
      final (q, opts) = await _auth();
      final sw = Stopwatch()..start();
      final res = await _dio.get('$_api$path',
          queryParameters: {...q, ...query}, options: opts);
      // Latency probe piggybacked on real requests: pick lighter artwork
      // tiers on slow links, recover to full quality when the network does.
      if (sw.elapsedMilliseconds > 1500) {
        fastNet = false;
      } else if (sw.elapsedMilliseconds < 400) {
        fastNet = true;
      }
      if (res.statusCode == 200) {
        final data = res.data is String ? jsonDecode(res.data) : res.data;
        await _repo.setSetting(
            cacheKey,
            jsonEncode(
                {'at': DateTime.now().millisecondsSinceEpoch, 'v': data}));
        return data;
      }
    } catch (_) {/* network hiccup — don't cache */}
    return null;
  }

  List<TmdbItem> _parseResults(dynamic data, {bool? forceShow}) {
    final results = data is Map ? data['results'] : null;
    final out = <TmdbItem>[];
    if (results is List) {
      for (final r in results) {
        if (r is! Map) continue;
        final isShow =
            forceShow ?? (r['media_type'] == 'tv' || r['name'] != null);
        final title =
            '${(isShow ? r['name'] : r['title']) ?? r['title'] ?? r['name'] ?? ''}';
        if (title.isEmpty) continue;
        final date =
            '${(isShow ? r['first_air_date'] : r['release_date']) ?? ''}';
        out.add(TmdbItem(
          tmdbId: (r['id'] as num?)?.toInt(),
          title: title,
          year: date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
          isShow: isShow,
          poster: posterUrl(r['poster_path'] as String?),
          backdrop: backdropUrl(r['backdrop_path'] as String?),
          rating: (r['vote_average'] as num?)?.toDouble(),
        ));
      }
    }
    return out;
  }

  /// Popular titles right now.
  Future<List<TmdbItem>> popular({bool show = false, int limit = 20}) async {
    final data = await _cachedGet('tmdb:popular:${show ? 'tv' : 'movie'}',
        '/${show ? 'tv' : 'movie'}/popular',
        ttl: const Duration(hours: 12));
    return _parseResults(data, forceShow: show).take(limit).toList();
  }

  /// Trending across the week (mixed movies + shows).
  Future<List<TmdbItem>> trending({int limit = 20}) async {
    final data = await _cachedGet('tmdb:trending:all', '/trending/all/week',
        ttl: const Duration(hours: 12));
    return _parseResults(data).take(limit).toList();
  }

  /// Movies trending this week — drives the featured banner.
  Future<List<TmdbItem>> trendingMoviesWeek({int limit = 30}) async {
    final data = await _cachedGet(
        'tmdb:trending:movieweek', '/trending/movie/week',
        ttl: const Duration(hours: 12));
    return _parseResults(data, forceShow: false).take(limit).toList();
  }

  /// The TMDB genre catalogue for movies (id → name).
  Future<List<TmdbGenre>> genres({bool show = false}) async {
    final data = await _cachedGet('tmdb:genres:${show ? 'tv' : 'movie'}',
        '/genre/${show ? 'tv' : 'movie'}/list',
        ttl: const Duration(days: 30));
    final list = data is Map ? data['genres'] : null;
    final out = <TmdbGenre>[];
    if (list is List) {
      for (final g in list) {
        if (g is Map && g['id'] != null && g['name'] != null) {
          out.add(TmdbGenre((g['id'] as num).toInt(), '${g['name']}', show));
        }
      }
    }
    return out;
  }

  /// Discover titles in a genre, most-popular first.
  Future<List<TmdbItem>> byGenre(int genreId,
      {bool show = false, int limit = 20}) async {
    final data = await _cachedGet(
        'tmdb:genre:${show ? 'tv' : 'movie'}:$genreId',
        '/discover/${show ? 'tv' : 'movie'}',
        query: {'with_genres': '$genreId', 'sort_by': 'popularity.desc'},
        ttl: const Duration(hours: 24));
    return _parseResults(data, forceShow: show).take(limit).toList();
  }

  /// Paged discovery for the browse grid. [genreId] null → popular overall.
  /// Each page is cached for a day so paging back and forth is instant. A
  /// modest vote-count floor keeps the grid free of empty/placeholder entries.
  Future<List<TmdbItem>> discover({
    required bool show,
    int? genreId,
    int page = 1,
  }) async {
    final gk = genreId == null ? 'pop' : 'g$genreId';
    final data = await _cachedGet(
      'tmdb:disc:${show ? 'tv' : 'movie'}:$gk:$page',
      '/discover/${show ? 'tv' : 'movie'}',
      query: {
        if (genreId != null) 'with_genres': '$genreId',
        'sort_by': 'popularity.desc',
        'page': '$page',
        'vote_count.gte': genreId == null ? '250' : '60',
      },
      ttl: const Duration(hours: 24),
    );
    return _parseResults(data, forceShow: show);
  }

  /// "Because you watched X" — TMDB's own recommendations for a title. Resolves
  /// the title to a TMDB id first (cached), then fetches recommendations.
  Future<List<TmdbItem>> recommendationsFor(String title,
      {bool show = false, int limit = 20}) async {
    final info = await lookup(title, isShow: show);
    if (info?.tmdbId == null) return [];
    final data = await _cachedGet(
        'tmdb:recs:${show ? 'tv' : 'movie'}:${info!.tmdbId}',
        '/${show ? 'tv' : 'movie'}/${info.tmdbId}/recommendations',
        ttl: const Duration(hours: 24));
    return _parseResults(data, forceShow: show).take(limit).toList();
  }

  /// Full detail for a title (overview, genres, runtime, cast, art). Cached
  /// permanently per title so each is fetched at most once.
  Future<TmdbInfo?> lookup(String rawTitle, {bool isShow = false}) async {
    final k = await key();
    if (k == null || k.isEmpty) return null;
    final (title, year) = _clean(rawTitle);
    if (title.isEmpty) return null;

    final type = isShow ? 'tv' : 'movie';
    final cacheKey = 'tmdb:detail:$type:${title.toLowerCase()}|${year ?? ''}';
    final cached = await _repo.getSetting(cacheKey);
    if (cached != null) {
      if (cached == '0') return null; // cached miss
      try {
        return TmdbInfo.fromJson(
            jsonDecode(cached) as Map<String, dynamic>, isShow);
      } catch (_) {/* refetch */}
    }

    try {
      final (q, opts) = await _auth();
      Future<List?> runSearch({required bool withYear}) async {
        final res = await _dio.get('$_api/search/$type',
            queryParameters: {
              ...q,
              'query': title,
              if (withYear && year != null)
                (isShow ? 'first_air_date_year' : 'year'): '$year',
            },
            options: opts);
        final sd = res.data is String ? jsonDecode(res.data) : res.data;
        final r = sd is Map ? sd['results'] : null;
        return r is List ? r : null;
      }

      // Year-filtered first for precision, then retry without it — a wrong /
      // missing provider year is a common reason a title comes back with no
      // metadata even though TMDB has it.
      var results = await runSearch(withYear: true);
      if ((results == null || results.isEmpty) && year != null) {
        results = await runSearch(withYear: false);
      }
      if (results == null || results.isEmpty) {
        await _repo.setSetting(cacheKey, '0');
        return null;
      }
      final id = (results.first as Map)['id'];
      // Detail call with credits appended so we get cast in one round-trip.
      final det = await _dio.get('$_api/$type/$id',
          queryParameters: {...q, 'append_to_response': 'credits,external_ids'},
          options: opts);
      final dd = det.data is String ? jsonDecode(det.data) : det.data;
      if (dd is Map && dd['id'] != null) {
        await _repo.setSetting(cacheKey, jsonEncode(dd));
        return TmdbInfo.fromJson(Map<String, dynamic>.from(dd), isShow);
      }
      await _repo.setSetting(cacheKey, '0');
    } catch (_) {/* network hiccup — don't cache */}
    return null;
  }

  /// Per-episode metadata for one season of a show: canonical episode names,
  /// overviews, stills and ratings. Resolves the show by title (cached), then
  /// fetches the season. Cached for a week.
  Future<List<TmdbEpisode>> seasonEpisodes(String showTitle, int season) async {
    final info = await lookup(showTitle, isShow: true);
    if (info?.tmdbId == null) return [];
    final data = await _cachedGet('tmdb:season:${info!.tmdbId}:$season',
        '/tv/${info.tmdbId}/season/$season',
        ttl: const Duration(days: 7));
    final list = data is Map ? data['episodes'] : null;
    final out = <TmdbEpisode>[];
    if (list is List) {
      for (final e in list) {
        if (e is! Map || e['episode_number'] == null) continue;
        out.add(TmdbEpisode(
          number: (e['episode_number'] as num).toInt(),
          name: '${e['name'] ?? ''}',
          overview:
              (e['overview'] is String && (e['overview'] as String).isNotEmpty)
                  ? e['overview'] as String
                  : null,
          still: posterUrl(e['still_path'] as String?, size: 'w300'),
          rating: (e['vote_average'] as num?)?.toDouble(),
        ));
      }
    }
    return out;
  }

  /// Strip provider noise (leading numbering, quality tags) and pull a year.
  (String, int?) _clean(String raw) {
    var s = raw.trim();
    int? year;
    final ym = RegExp(r'\((19|20)\d{2}\)').firstMatch(s);
    if (ym != null) {
      year = int.tryParse(ym.group(0)!.replaceAll(RegExp(r'[()]'), ''));
    }
    s = s
        .replaceAll(RegExp(r'^\s*\d{1,4}\s*[-.]\s*'), '')
        .replaceAll(RegExp(r'^[A-Z]{2,3}\s*[|:-]\s*'), '')
        .replaceAll(RegExp(r'\((19|20)\d{2}\)'), '')
        .replaceAll(RegExp(r'\[[^\]]*\]'), '')
        .replaceAll(
            RegExp(r'\b(4k|uhd|fhd|hd|sd|hevc|x265|1080p|720p|multi|vip)\b',
                caseSensitive: false),
            '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return (s, year);
  }
}

/// A lightweight discovery item from a TMDB list (poster + title + year).
class TmdbItem {
  final int? tmdbId;
  final String title;
  final int? year;
  final bool isShow;
  final String? poster;
  final String? backdrop;
  final double? rating;
  const TmdbItem({
    this.tmdbId,
    required this.title,
    this.year,
    this.isShow = false,
    this.poster,
    this.backdrop,
    this.rating,
  });
}

/// One episode's canonical metadata from TMDB.
class TmdbEpisode {
  final int number;
  final String name;
  final String? overview;
  final String? still;
  final double? rating;
  const TmdbEpisode({
    required this.number,
    required this.name,
    this.overview,
    this.still,
    this.rating,
  });
}

class TmdbGenre {
  final int id;
  final String name;
  final bool isShow;
  const TmdbGenre(this.id, this.name, this.isShow);
}

/// Full metadata for a title's detail screen.
class TmdbInfo {
  final int? tmdbId;
  final String title;
  final String? overview;
  final List<String> genres;
  final int? runtimeMins;
  final double? rating;
  final String? poster;
  final String? backdrop;
  final String? releaseDate;
  final List<String> cast;
  final String? imdbId;

  const TmdbInfo({
    this.tmdbId,
    required this.title,
    this.overview,
    this.genres = const [],
    this.runtimeMins,
    this.rating,
    this.poster,
    this.backdrop,
    this.releaseDate,
    this.cast = const [],
    this.imdbId,
  });

  factory TmdbInfo.fromJson(Map<String, dynamic> d, bool isShow) {
    final genreList = <String>[];
    if (d['genres'] is List) {
      for (final g in d['genres']) {
        if (g is Map && g['name'] != null) genreList.add('${g['name']}');
      }
    }
    // Movies expose `runtime`; shows expose `episode_run_time: [mins]`.
    int? runtime = (d['runtime'] as num?)?.toInt();
    if (runtime == null &&
        d['episode_run_time'] is List &&
        (d['episode_run_time'] as List).isNotEmpty) {
      runtime = ((d['episode_run_time'] as List).first as num?)?.toInt();
    }
    final cast = <String>[];
    final credits = d['credits'];
    if (credits is Map && credits['cast'] is List) {
      for (final c in (credits['cast'] as List).take(8)) {
        if (c is Map && c['name'] != null) cast.add('${c['name']}');
      }
    }
    return TmdbInfo(
      tmdbId: (d['id'] as num?)?.toInt(),
      title:
          '${(isShow ? d['name'] : d['title']) ?? d['title'] ?? d['name'] ?? ''}',
      overview:
          (d['overview'] is String && (d['overview'] as String).isNotEmpty)
              ? d['overview'] as String
              : null,
      genres: genreList,
      runtimeMins: runtime,
      rating: (d['vote_average'] as num?)?.toDouble(),
      poster: TmdbService.posterUrl(d['poster_path'] as String?),
      backdrop: TmdbService.backdropUrl(d['backdrop_path'] as String?),
      imdbId: (d['external_ids'] is Map
              ? d['external_ids']['imdb_id'] as String?
              : null) ??
          d['imdb_id'] as String?,
      releaseDate:
          '${(isShow ? d['first_air_date'] : d['release_date']) ?? ''}',
      cast: cast,
    );
  }
}

final tmdbServiceProvider = FutureProvider<TmdbService>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  return TmdbService(repo);
});

/// True when the user has entered a TMDB key — gates all TMDB UI.
final tmdbEnabledProvider = FutureProvider<bool>((ref) async {
  final svc = await ref.watch(tmdbServiceProvider.future);
  // Also re-runs when the key setting changes via invalidation.
  ref.watch(tmdbKeyRevProvider);
  return svc.enabled;
});

/// Bumped whenever the key is saved so dependent providers recompute.
final tmdbKeyRevProvider = StateProvider<int>((ref) => 0);

/// Episode number → TMDB metadata for one (show, season). autoDispose is fine
/// here — the underlying HTTP result is DB-cached, so re-entry is a local read.
final tmdbSeasonProvider = FutureProvider.autoDispose
    .family<Map<int, TmdbEpisode>, ({String title, int season})>(
        (ref, args) async {
  final svc = await ref.watch(tmdbServiceProvider.future);
  final eps = await svc.seasonEpisodes(args.title, args.season);
  return {for (final e in eps) e.number: e};
});

/// Lazily resolved TMDB metadata for a title's detail screen.
final tmdbDetailProvider = FutureProvider.autoDispose
    .family<TmdbInfo?, ({String title, bool isShow})>((ref, args) async {
  final svc = await ref.watch(tmdbServiceProvider.future);
  return svc.lookup(args.title, isShow: args.isShow);
});

// ---------------------------------------------------------------------------
// TMDB-driven home rows. Each resolves a TMDB discovery list to items that
// actually exist in the user's library (so they're playable), overlaying the
// TMDB poster + rating for richer art. Rows silently vanish when no key is set.
// ---------------------------------------------------------------------------

Future<List<StreamItem>> _matchToLibrary(
    LibraryRepository repo, int plId, List<TmdbItem> items) async {
  final out = <StreamItem>[];
  final seen = <int>{};
  for (final t in items) {
    final kind = t.isShow ? StreamKind.series : StreamKind.movie;
    final hits =
        await repo.search(playlistId: plId, kind: kind, query: t.title);
    // Prefer the English-labelled entry when a title exists in many languages.
    final hit = LibraryRepository.preferEnglish(hits);
    if (hit != null && hit.id != null && seen.add(hit.id!)) {
      // Backdrop first: home rows render these as wide landscape cards.
      out.add(hit.copyWith(logo: t.backdrop ?? t.poster, rating: t.rating));
    }
  }
  return out;
}

final tmdbPopularProvider = FutureProvider<List<StreamItem>>((ref) async {
  if (!await ref.watch(tmdbEnabledProvider.future)) return [];
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return [];
  final svc = await ref.watch(tmdbServiceProvider.future);
  return _matchToLibrary(repo, pl!.id!, await svc.popular());
});

final tmdbTrendingProvider = FutureProvider<List<StreamItem>>((ref) async {
  if (!await ref.watch(tmdbEnabledProvider.future)) return [];
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return [];
  final svc = await ref.watch(tmdbServiceProvider.future);
  return _matchToLibrary(repo, pl!.id!, await svc.trending());
});

/// TMDB movie genres available to browse.
final tmdbGenresProvider = FutureProvider<List<TmdbGenre>>((ref) async {
  if (!await ref.watch(tmdbEnabledProvider.future)) return [];
  final svc = await ref.watch(tmdbServiceProvider.future);
  return svc.genres();
});

/// Library items for a given TMDB genre id.
final tmdbGenreRowProvider =
    FutureProvider.family<List<StreamItem>, int>((ref, genreId) async {
  if (!await ref.watch(tmdbEnabledProvider.future)) return [];
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return [];
  final svc = await ref.watch(tmdbServiceProvider.future);
  return _matchToLibrary(repo, pl!.id!, await svc.byGenre(genreId));
});

/// "Because you watched X" — recommendations off the most recent watch.
final tmdbBecauseYouWatchedProvider =
    FutureProvider<({String? seed, List<StreamItem> items})>((ref) async {
  if (!await ref.watch(tmdbEnabledProvider.future)) {
    return (seed: null, items: <StreamItem>[]);
  }
  final repo = await ref.watch(repositoryProvider.future);
  final pl = ref.watch(activePlaylistProvider);
  if (pl?.id == null) return (seed: null, items: <StreamItem>[]);
  final recent = await repo.recentlyWatched(pl!.id!);
  if (recent.isEmpty) return (seed: null, items: <StreamItem>[]);
  final seed = recent.first;
  final svc = await ref.watch(tmdbServiceProvider.future);
  final recs = await svc.recommendationsFor(seed.name,
      show: seed.kind == StreamKind.series);
  return (seed: seed.name, items: await _matchToLibrary(repo, pl.id!, recs));
});
