import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/library_repository.dart';
import '../../state/providers.dart';

/// Looks up IMDb / Rotten Tomatoes / Metacritic ratings + plot from OMDb.
/// Results (including misses) are cached in app_settings so each title is
/// fetched at most once — staying well within the free 1,000/day quota.
///
/// Get a free key at https://www.omdbapi.com/apikey.aspx and either paste it in
/// Settings → Metadata, or bake it into [_embeddedKey] for all users.
class OmdbService {
  OmdbService(this._repo);
  final LibraryRepository _repo;

  static const _embeddedKey = ''; // paste your OMDb key here

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 12),
  ));

  Future<String?> key() async {
    if (_embeddedKey.isNotEmpty) return _embeddedKey;
    return _repo.getSetting('omdb_key');
  }

  Future<bool> get enabled async => (await key())?.isNotEmpty ?? false;

  Future<void> saveKey(String k) => _repo.setSetting('omdb_key', k.trim());

  /// Fast health probe: does the saved key authenticate against OMDb?
  Future<({bool configured, bool ok, String detail})> ping() async {
    final k = await key();
    if (k == null || k.isEmpty) {
      return (configured: false, ok: false, detail: 'No key set');
    }
    try {
      final res = await _dio.get('https://www.omdbapi.com/',
          queryParameters: {'apikey': k, 't': 'Batman'});
      final d = res.data is String ? jsonDecode(res.data) : res.data;
      if (d is Map && d['Response'] == 'True') {
        return (configured: true, ok: true, detail: 'OK');
      }
      return (
        configured: true,
        ok: false,
        detail: '${d is Map ? (d['Error'] ?? 'Invalid key') : 'Invalid key'}'
      );
    } catch (_) {
      return (configured: true, ok: false, detail: 'Unreachable');
    }
  }

  Future<OmdbInfo?> lookup(String rawTitle) async {
    final k = await key();
    if (k == null || k.isEmpty) return null;

    final (title, year) = _clean(rawTitle);
    if (title.isEmpty) return null;
    final cacheKey = 'omdb:${title.toLowerCase()}|${year ?? ''}';

    final cached = await _repo.getSetting(cacheKey);
    if (cached != null) {
      if (cached == '0') return null; // cached miss
      return OmdbInfo.fromJson(jsonDecode(cached) as Map<String, dynamic>);
    }

    try {
      final res = await _dio.get('https://www.omdbapi.com/', queryParameters: {
        'apikey': k,
        't': title,
        if (year != null) 'y': '$year',
        'plot': 'short',
      });
      final d = res.data is String ? jsonDecode(res.data) : res.data;
      if (d is Map && d['Response'] == 'True') {
        await _repo.setSetting(cacheKey, jsonEncode(d));
        return OmdbInfo.fromJson(Map<String, dynamic>.from(d));
      }
      await _repo.setSetting(cacheKey, '0'); // remember the miss
    } catch (_) {/* network hiccup — don't cache */}
    return null;
  }

  /// Strip provider noise: leading "07 - ", "EN| ", quality tags, and pull out
  /// a (YYYY) year if present.
  (String, int?) _clean(String raw) {
    var s = raw.trim();
    int? year;
    final ym = RegExp(r'\((19|20)\d{2}\)').firstMatch(s);
    if (ym != null) {
      year = int.tryParse(ym.group(0)!.replaceAll(RegExp(r'[()]'), ''));
    }
    s = s
        .replaceAll(RegExp(r'^\s*\d{1,4}\s*[-.]\s*'), '') // "07 - "
        .replaceAll(RegExp(r'^[A-Z]{2,3}\s*[|:-]\s*'), '') // "EN| ", "VIP| "
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

class OmdbRating {
  final String source; // IMDb | Rotten Tomatoes | Metacritic
  final String value;
  const OmdbRating(this.source, this.value);
}

class OmdbInfo {
  final String title;
  final String? year;
  final String? rated;
  final String? runtime;
  final String? genre;
  final String? plot;
  final String? poster;
  final String? imdb; // e.g. "8.1"
  final String? rotten; // e.g. "94%"
  final String? metacritic; // e.g. "76/100"

  const OmdbInfo({
    required this.title,
    this.year,
    this.rated,
    this.runtime,
    this.genre,
    this.plot,
    this.poster,
    this.imdb,
    this.rotten,
    this.metacritic,
  });

  factory OmdbInfo.fromJson(Map<String, dynamic> d) {
    String? imdb = d['imdbRating'] is String && d['imdbRating'] != 'N/A'
        ? d['imdbRating']
        : null;
    String? rotten, meta;
    final ratings = d['Ratings'];
    if (ratings is List) {
      for (final r in ratings) {
        if (r is Map) {
          switch ('${r['Source']}') {
            case 'Rotten Tomatoes':
              rotten = '${r['Value']}';
              break;
            case 'Metacritic':
              meta = '${r['Value']}';
              break;
          }
        }
      }
    }
    String? s(String k) =>
        d[k] is String && d[k] != 'N/A' ? d[k] as String : null;
    return OmdbInfo(
      title: '${d['Title'] ?? ''}',
      year: s('Year'),
      rated: s('Rated'),
      runtime: s('Runtime'),
      genre: s('Genre'),
      plot: s('Plot'),
      poster: s('Poster'),
      imdb: imdb,
      rotten: rotten,
      metacritic: meta,
    );
  }
}

final omdbServiceProvider = FutureProvider<OmdbService>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  return OmdbService(repo);
});

/// Lazily resolved metadata for a given raw title.
final omdbProvider =
    FutureProvider.autoDispose.family<OmdbInfo?, String>((ref, title) async {
  final svc = await ref.watch(omdbServiceProvider.future);
  return svc.lookup(title);
});
