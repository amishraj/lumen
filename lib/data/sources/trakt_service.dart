import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/library_repository.dart';
import '../../state/providers.dart';

/// Minimal Trakt client using the OAuth **device flow** — ideal for a
/// sideloaded app: the user enters a short code at trakt.tv/activate, no
/// redirect URI needed. Credentials + tokens are persisted in app_settings.
///
/// To use it you create a free API app at https://trakt.tv/oauth/applications
/// (redirect uri can be urn:ietf:wg:oauth:2.0:oob) and paste the client id +
/// secret into Settings → Trakt.
class TraktService {
  TraktService(this._repo);
  final LibraryRepository _repo;

  // Kodi-style embedded credentials. Fill these in (from a single Trakt API app
  // you register once at trakt.tv/oauth/applications) and every user — you and
  // your friends — connects with just a code, no per-user app registration.
  // Leave empty to fall back to in-app credential entry.
  static const _embeddedClientId =
      '351218759d9c05f412c54ba1edeb61144f8aa238270671d54d80a2e5f6aa626e';
  static const _embeddedClientSecret =
      '468da7a135dbf1bce84a072a543cfbfef27a9c6f07b2f995d424e66e8ae463db';

  static const _api = 'https://api.trakt.tv';
  final _dio = Dio(BaseOptions(
    headers: {'Content-Type': 'application/json', 'trakt-api-version': '2'},
    validateStatus: (s) => s != null && s < 500,
  ));

  Future<String?> _clientId() async {
    if (_embeddedClientId.isNotEmpty) return _embeddedClientId;
    return _repo.getSetting('trakt_client_id');
  }

  Future<String?> _clientSecret() async {
    if (_embeddedClientSecret.isNotEmpty) return _embeddedClientSecret;
    return _repo.getSetting('trakt_client_secret');
  }

  Future<String?> token() => _repo.getSetting('trakt_access_token');

  Future<bool> isConnected() async => (await token()) != null;

  /// True when credentials are baked in — the UI can then skip the setup form
  /// and offer a single "Connect with Trakt" button (Kodi-style).
  bool get hasEmbeddedCredentials => _embeddedClientId.isNotEmpty;

  /// Exposes the saved client id for prefilling the settings form.
  Future<String?> getClientIdForUi() => _clientId();

  Future<void> saveCredentials(String clientId, String clientSecret) async {
    await _repo.setSetting('trakt_client_id', clientId.trim());
    await _repo.setSetting('trakt_client_secret', clientSecret.trim());
  }

  Future<void> disconnect() async {
    await _repo.setSetting('trakt_access_token', null);
    await _repo.setSetting('trakt_refresh_token', null);
    await _repo.setSetting('trakt_username', null);
  }

  /// Step 1 of the device flow — get a code for the user to enter.
  Future<TraktDeviceCode> requestDeviceCode() async {
    final clientId = await _clientId();
    if (clientId == null || clientId.isEmpty) {
      throw Exception('Add your Trakt client id & secret first.');
    }
    final res = await _dio.post('$_api/oauth/device/code',
        data: jsonEncode({'client_id': clientId}));
    if (res.statusCode != 200) {
      throw Exception('Trakt rejected the client id (${res.statusCode}).');
    }
    final d = res.data is String ? jsonDecode(res.data) : res.data;
    return TraktDeviceCode(
      deviceCode: d['device_code'],
      userCode: d['user_code'],
      verificationUrl: d['verification_url'],
      intervalSecs: (d['interval'] ?? 5) as int,
      expiresInSecs: (d['expires_in'] ?? 600) as int,
    );
  }

  /// Step 2 — poll once for the token. Returns true when authorised, false
  /// while still pending, throws on hard failure (expired/denied).
  Future<bool> pollToken(String deviceCode) async {
    final clientId = await _clientId();
    final clientSecret = await _clientSecret();
    final res = await _dio.post('$_api/oauth/device/token',
        data: jsonEncode({
          'code': deviceCode,
          'client_id': clientId,
          'client_secret': clientSecret,
        }));
    switch (res.statusCode) {
      case 200:
        final d = res.data is String ? jsonDecode(res.data) : res.data;
        await _repo.setSetting('trakt_access_token', d['access_token']);
        await _repo.setSetting('trakt_refresh_token', d['refresh_token']);
        await _fetchUsername();
        return true;
      case 400:
        return false; // pending — keep polling
      case 429:
        return false; // slow down — caller already waits the interval
      case 404:
      case 409:
      case 410:
      case 418:
        throw Exception('Trakt authorisation failed (${res.statusCode}).');
      default:
        throw Exception('Trakt error ${res.statusCode}.');
    }
  }

  Future<Map<String, String>> _authHeaders() async {
    final clientId = await _clientId();
    final tok = await token();
    return {
      'trakt-api-key': clientId ?? '',
      if (tok != null) 'Authorization': 'Bearer $tok',
    };
  }

  Future<void> _fetchUsername() async {
    try {
      final res = await _dio.get('$_api/users/settings',
          options: Options(headers: await _authHeaders()));
      final d = res.data is String ? jsonDecode(res.data) : res.data;
      final name = d['user']?['username'] ?? d['user']?['name'];
      if (name != null) await _repo.setSetting('trakt_username', '$name');
    } catch (_) {/* non-fatal */}
  }

  Future<String?> username() => _repo.getSetting('trakt_username');

  /// Currently-popular movies (Trakt trending). Public endpoint — needs only
  /// the app's api key, so it works even before the user connects.
  Future<List<TraktItem>> trendingMovies({int limit = 30}) async {
    final clientId = await _clientId();
    if (clientId == null || clientId.isEmpty) return [];
    final res = await _dio.get('$_api/movies/trending',
        queryParameters: {'limit': '$limit'},
        options: Options(headers: {'trakt-api-key': clientId}));
    if (res.statusCode != 200) return [];
    final list = res.data is String ? jsonDecode(res.data) : res.data;
    final out = <TraktItem>[];
    if (list is List) {
      for (final e in list) {
        final m = e is Map ? e['movie'] : null;
        if (m is Map && m['title'] != null) {
          out.add(TraktItem(
              title: '${m['title']}',
              year: (m['year'] as num?)?.toInt(),
              type: 'movie'));
        }
      }
    }
    return out;
  }

  /// The user's Trakt watchlist (movies + shows), as discovery items.
  Future<List<TraktItem>> watchlist() async {
    if (!await isConnected()) return [];
    final res = await _dio.get('$_api/sync/watchlist',
        options: Options(headers: await _authHeaders()));
    if (res.statusCode != 200) return [];
    final list = res.data is String ? jsonDecode(res.data) : res.data;
    final out = <TraktItem>[];
    if (list is List) {
      for (final e in list) {
        if (e is! Map) continue;
        final type = '${e['type']}';
        final node = e[type];
        if (node is Map) {
          out.add(TraktItem(
            title: '${node['title'] ?? ''}',
            year: (node['year'] as num?)?.toInt(),
            type: type,
          ));
        }
      }
    }
    return out;
  }

  /// Resume point (0..1) for a title from Trakt's cross-device playback store.
  /// Title-matched, so best-effort for IPTV items.
  Future<double?> resumeProgress(String title, {bool isShow = false}) async {
    if (!await isConnected()) return null;
    try {
      final type = isShow ? 'episodes' : 'movies';
      final res = await _dio.get('$_api/sync/playback/$type',
          options: Options(headers: await _authHeaders()));
      final list = res.data is String ? jsonDecode(res.data) : res.data;
      if (list is! List) return null;
      final needle = title.toLowerCase();
      for (final e in list) {
        if (e is! Map) continue;
        final node = e[isShow ? 'show' : 'movie'];
        final t = node is Map ? '${node['title']}'.toLowerCase() : '';
        if (t.isNotEmpty && (needle.contains(t) || t.contains(needle))) {
          final p = (e['progress'] as num?)?.toDouble();
          if (p != null) return p / 100.0;
        }
      }
    } catch (_) {/* best effort */}
    return null;
  }

  /// Push a playback progress checkpoint (pause scrobble) so other devices can
  /// resume. progress is 0..100.
  Future<void> savePlayback(String title,
      {int? year, bool isShow = false, required double progressPct}) async {
    if (!await isConnected()) return;
    if (progressPct < 1 || progressPct > 95) return;
    try {
      final type = isShow ? 'show' : 'movie';
      final search = await _dio.get('$_api/search/$type',
          queryParameters: {'query': title, if (year != null) 'years': '$year'},
          options: Options(headers: await _authHeaders()));
      final list = search.data is String ? jsonDecode(search.data) : search.data;
      if (list is! List || list.isEmpty) return;
      final node = (list.first as Map)[type];
      if (node is! Map) return;
      await _dio.post('$_api/scrobble/pause',
          data: jsonEncode({type: {'ids': node['ids']}, 'progress': progressPct}),
          options: Options(headers: await _authHeaders()));
    } catch (_) {/* best effort */}
  }

  /// Best-effort: mark a title watched on Trakt by searching for it first.
  /// IPTV items aren't tied to Trakt ids, so we match on title/year.
  Future<void> markWatched(String title, {int? year, bool isShow = false}) async {
    if (!await isConnected()) return;
    try {
      final type = isShow ? 'show' : 'movie';
      final search = await _dio.get('$_api/search/$type',
          queryParameters: {'query': title, if (year != null) 'years': '$year'},
          options: Options(headers: await _authHeaders()));
      final list = search.data is String ? jsonDecode(search.data) : search.data;
      if (list is! List || list.isEmpty) return;
      final node = (list.first as Map)[type];
      if (node is! Map) return;
      final ids = node['ids'];
      await _dio.post('$_api/sync/history',
          data: jsonEncode({
            '${type}s': [
              {'ids': ids}
            ]
          }),
          options: Options(headers: await _authHeaders()));
    } catch (_) {/* best effort */}
  }
}

class TraktDeviceCode {
  final String deviceCode;
  final String userCode;
  final String verificationUrl;
  final int intervalSecs;
  final int expiresInSecs;
  const TraktDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.intervalSecs,
    required this.expiresInSecs,
  });
}

class TraktItem {
  final String title;
  final int? year;
  final String type; // movie | show
  const TraktItem({required this.title, this.year, required this.type});
}

// ---- Providers -------------------------------------------------------------

final traktServiceProvider = FutureProvider<TraktService>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  return TraktService(repo);
});

/// Connection state, refreshable after connect/disconnect.
final traktConnectedProvider = FutureProvider.autoDispose<bool>((ref) async {
  final svc = await ref.watch(traktServiceProvider.future);
  return svc.isConnected();
});

final traktUsernameProvider = FutureProvider.autoDispose<String?>((ref) async {
  final svc = await ref.watch(traktServiceProvider.future);
  return svc.username();
});

final traktWatchlistProvider =
    FutureProvider.autoDispose<List<TraktItem>>((ref) async {
  final connected = await ref.watch(traktConnectedProvider.future);
  if (!connected) return [];
  final svc = await ref.watch(traktServiceProvider.future);
  return svc.watchlist();
});
