import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/library_repository.dart';
import '../models/models.dart';
import '../../state/providers.dart';
import '../../ui/title_utils.dart';

/// How many of Trakt's in-progress episodes get seeded into the local
/// `episode_progress` table per pass. Streaming-service integrations (Netflix
/// and friends) can push an account's in-progress list well past a hundred
/// rows; only the most recent handful are ever surfaced, so only those are
/// worth writing and re-grouping on every home build.
const kResumeSeedLimit = 40;

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
  static const _embeddedClientId = 'YGCLH5Z-Uy2kOy4BcKnOFccFwOlDcTnGWaNn3LS7M6w';
  static const _embeddedClientSecret =
      'A-8sJv32VFIUAACM6MfDlhoMZKHq1mFMoaU2765KX_8';

  static const _api = 'https://api.trakt.tv';
  final _dio = Dio(BaseOptions(
    headers: {'Content-Type': 'application/json', 'trakt-api-version': '2'},
    validateStatus: (s) => s != null && s < 500,
  ));

  // User-entered credentials take precedence over the embedded ones, so a
  // revoked/deleted embedded Trakt app (Trakt replies 401 "client not found")
  // never hard-blocks connect — the user can paste their own app's id/secret
  // and override it. Falls back to the embedded pair when nothing is saved.
  Future<String?> _clientId() async {
    final saved = await _repo.getSetting('trakt_client_id');
    if (saved != null && saved.isNotEmpty) return saved;
    return _embeddedClientId.isNotEmpty ? _embeddedClientId : null;
  }

  Future<String?> _clientSecret() async {
    final saved = await _repo.getSetting('trakt_client_secret');
    if (saved != null && saved.isNotEmpty) return saved;
    return _embeddedClientSecret.isNotEmpty ? _embeddedClientSecret : null;
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
    await _clearCaches();
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
        await _clearCaches(); // fresh account — drop any prior snapshots
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

  /// Exchange the saved refresh token for a fresh access token. Trakt access
  /// tokens expire (3 months), and without this every authenticated call
  /// silently 401s and returns nothing — which reads as "all my Trakt content
  /// disappeared". Returns true if a new token was obtained.
  Future<bool> _refreshToken() async {
    final refresh = await _repo.getSetting('trakt_refresh_token');
    final clientId = await _clientId();
    final clientSecret = await _clientSecret();
    if (refresh == null ||
        refresh.isEmpty ||
        clientId == null ||
        clientSecret == null) {
      return false;
    }
    try {
      final res = await _dio.post('$_api/oauth/token',
          data: jsonEncode({
            'refresh_token': refresh,
            'client_id': clientId,
            'client_secret': clientSecret,
            // Trakt requires redirect_uri on the refresh exchange too; the app
            // is registered with the device-flow OOB uri, so match it here.
            'redirect_uri': 'urn:ietf:wg:oauth:2.0:oob',
            'grant_type': 'refresh_token',
          }));
      if (res.statusCode == 200) {
        final d = res.data is String ? jsonDecode(res.data) : res.data;
        await _repo.setSetting('trakt_access_token', d['access_token']);
        await _repo.setSetting('trakt_refresh_token', d['refresh_token']);
        return true;
      }
      // Refresh token itself is dead — clear so the UI stops claiming
      // "Connected" and the user can re-auth.
      if (res.statusCode == 401) await disconnect();
    } catch (_) {/* network hiccup — keep the token, try again later */}
    return false;
  }

  /// Authenticated GET that transparently refreshes an expired access token
  /// once and retries. All read endpoints go through here so a stale token
  /// self-heals instead of blanking the user's Trakt rows.
  Future<Response<dynamic>> _authGet(String url,
      {Map<String, dynamic>? queryParameters}) async {
    Future<Response<dynamic>> go() async => _dio.get(url,
        queryParameters: queryParameters,
        options: Options(headers: await _authHeaders()));
    var res = await go();
    if (res.statusCode == 401 && await _refreshToken()) {
      res = await go();
    }
    return res;
  }

  /// Authenticated POST with the same self-healing 401 → refresh → retry as
  /// [_authGet]. Every WRITE goes through here: the old raw posts treated an
  /// expired-token 401 as success (validateStatus < 500 never throws), so for
  /// up to three months of token age every watch event was silently lost.
  /// Returns the HTTP status, or null on a transport failure (offline / DNS /
  /// timeout) — callers use that distinction to decide queue vs drop.
  Future<int?> _authPostStatus(String url, Object body) async {
    try {
      Future<Response<dynamic>> go() async => _dio.post(url,
          data: body is String ? body : jsonEncode(body),
          options: Options(headers: await _authHeaders()));
      var res = await go();
      if (res.statusCode == 401 && await _refreshToken()) {
        res = await go();
      }
      return res.statusCode;
    } catch (_) {
      return null; // offline / DNS / timeout — caller queues if it matters
    }
  }

  /// True on a 2xx response. See [_authPostStatus].
  Future<bool> _authPost(String url, Object body) async {
    final code = await _authPostStatus(url, body) ?? 0;
    return code >= 200 && code < 300;
  }

  /// DB-backed **stale-while-revalidate** cache for a Trakt read.
  ///
  /// Returns the cached response instantly when present — even if stale — and
  /// kicks a background refresh so the next launch is up to date (the "content
  /// is populated the moment the app opens, updates land on the once-a-day
  /// strategy" behaviour). Only a cold cache blocks on the network; a failed
  /// refresh keeps the last good snapshot, so the home stays populated offline.
  Future<dynamic> _cachedJson(
    String cacheKey,
    Future<Response<dynamic>> Function() fetcher, {
    Duration ttl = const Duration(hours: 24),
    bool requireConnected = true,
  }) async {
    if (requireConnected && !await isConnected()) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    dynamic stale;
    final raw = await _repo.getSetting(cacheKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final wrap = jsonDecode(raw) as Map<String, dynamic>;
        stale = wrap['v'];
        if (now - (wrap['at'] as int? ?? 0) < ttl.inMilliseconds) return stale;
      } catch (_) {/* corrupt — refetch */}
    }

    Future<dynamic> fetchStore() async {
      try {
        final res = await fetcher();
        if (res.statusCode != 200) return stale;
        final data = res.data is String ? jsonDecode(res.data) : res.data;
        await _repo.setSetting(
            cacheKey, jsonEncode({'at': now, 'v': data}));
        return data;
      } catch (_) {
        return stale; // keep showing the last good snapshot
      }
    }

    // Have a stale copy → show it now, refresh in the background.
    if (stale != null) {
      unawaited(fetchStore());
      return stale;
    }
    return fetchStore();
  }

  /// Clear all cached Trakt snapshots (on connect/disconnect so a different or
  /// freshly-linked account never shows the previous one's rows).
  Future<void> _clearCaches() => _repo.db.deleteSettingsPrefix('trakt:cache:');

  // ---- Write outbox --------------------------------------------------------
  //
  // The invariant: anything marked watched locally MUST eventually exist on
  // Trakt. A write that fails (offline, expired token mid-refresh, search
  // miss) is queued here as a self-describing op and replayed on the next app
  // open / flush — instead of being silently dropped forever.

  Future<void> _enqueue(Map<String, dynamic> op) async {
    try {
      await _repo.db.outboxAdd(jsonEncode(op));
    } catch (_) {/* the local DB failing is beyond rescue here */}
  }

  bool _flushing = false;

  /// Outcome of replaying one queued op.
  static const _opDone = 0; // sent (or already recorded) — delete the row
  static const _opRetry = 1; // deterministic failure — bump, try NEXT row
  static const _opOffline = 2; // transport failure — bump, stop the flush

  /// Replay every queued write. Called on app open (after the token refresh
  /// path has run) and after a successful stop scrobble (connectivity just
  /// proved itself). A transport failure stops the flush (offline — retry
  /// later); a deterministic failure (title with no Trakt match, deleted
  /// show) moves ON to the next row so one bad op can't block every valid
  /// watch event queued behind it. Deterministic failures drop after 5
  /// attempts, transport failures after 25.
  Future<void> flushOutbox() async {
    if (_flushing || !await isConnected()) return;
    _flushing = true;
    try {
      final rows = await _repo.db.outboxAll();
      for (final row in rows) {
        Map<String, dynamic> op;
        try {
          op = Map<String, dynamic>.from(jsonDecode(row.payload) as Map);
        } catch (_) {
          await _repo.db.outboxDelete(row.id); // corrupt — drop
          continue;
        }
        final outcome = await _executeOp(op);
        if (outcome == _opDone) {
          await _repo.db.outboxDelete(row.id);
        } else if (outcome == _opRetry) {
          if (row.attempts >= 5) {
            await _repo.db.outboxDelete(row.id);
          } else {
            await _repo.db.outboxBumpAttempts(row.id);
          }
          // fall through to the next row — this failure is op-specific
        } else {
          if (row.attempts >= 25) {
            await _repo.db.outboxDelete(row.id);
          } else {
            await _repo.db.outboxBumpAttempts(row.id);
          }
          break; // offline — stop hammering, retry next flush
        }
      }
    } catch (_) {/* next flush retries */} finally {
      _flushing = false;
    }
  }

  /// Execute one queued op. Ids are resolved at REPLAY time (the enqueue may
  /// have happened fully offline, when no search was possible).
  Future<int> _executeOp(Map<String, dynamic> op) async {
    final title = '${op['title'] ?? ''}';
    if (title.isEmpty) return _opDone; // malformed — treat as done
    final isShow = op['isShow'] == true;
    final year = (op['year'] as num?)?.toInt();
    switch ('${op['op']}') {
      case 'history_add':
        final ids = await idsFor(title, year: year, isShow: isShow);
        if (ids == null) return _opRetry; // no Trakt match (yet)
        final season = (op['season'] as num?)?.toInt();
        final episode = (op['episode'] as num?)?.toInt();
        final watchedAt = '${op['watched_at'] ?? ''}';
        final isEpisode = isShow && season != null && episode != null;
        final Map<String, dynamic> body;
        if (isEpisode) {
          body = {
            'shows': [
              {
                'ids': ids,
                'seasons': [
                  {
                    'number': season,
                    'episodes': [
                      {
                        'number': episode,
                        if (watchedAt.isNotEmpty) 'watched_at': watchedAt,
                      }
                    ],
                  }
                ],
              }
            ]
          };
        } else {
          body = {
            'movies': [
              {'ids': ids, if (watchedAt.isNotEmpty) 'watched_at': watchedAt}
            ]
          };
        }
        final status = await _authPostStatus('$_api/sync/history', body);
        if (status == null) return _opOffline;
        if (status >= 200 && status < 300) {
          // Invalidate the snapshot the write actually changed, so the synced
          // watch shows up on the next read instead of after the 24h TTL.
          if (isEpisode) {
            await _repo.setSetting('trakt:cache:watched:shows', null);
            final sid = ids['trakt'] ?? ids['slug'];
            if (sid != null) {
              await _repo.setSetting('trakt:cache:show_progress:$sid', null);
            }
          } else {
            await _repo.setSetting('trakt:cache:watched:movies', null);
          }
          return _opDone;
        }
        return status >= 500 ? _opOffline : _opRetry;
      case 'season':
        return await _postSeason(title, (op['season'] as num?)?.toInt() ?? 0,
                watched: op['watched'] == true)
            ? _opDone
            : _opRetry;
      case 'watchlist':
        return await _postWatchlist(title,
                year: year, isShow: isShow, inList: op['inList'] == true)
            ? _opDone
            : _opRetry;
    }
    return _opDone; // unknown op — drop
  }

  /// Force-refresh the snapshots behind the home rows (resume points, watched
  /// history, watchlist), ignoring their TTLs. Called once per app open so
  /// activity from other devices shows up within seconds of launch instead of
  /// whenever the 6h/24h cache windows happen to lapse. Returns true when any
  /// payload actually changed — the caller invalidates the dependent providers
  /// only then, so an unchanged account costs zero rebuilds.
  Future<bool> refreshHomeSnapshots() async {
    if (!await isConnected()) return false;
    var changed = false;
    Future<void> pull(String cacheKey, String url) async {
      try {
        // The sync endpoints are paginated since the June 2026 API change; an
        // explicit large limit keeps big histories intact in one request.
        final res = await _authGet(url, queryParameters: {'limit': '1000'});
        if (res.statusCode != 200) return;
        final data = res.data is String ? jsonDecode(res.data) : res.data;
        final fresh = jsonEncode(data);
        final old = await _repo.getSetting(cacheKey);
        var same = false;
        if (old != null && old.isNotEmpty) {
          try {
            same = jsonEncode((jsonDecode(old) as Map)['v']) == fresh;
          } catch (_) {/* corrupt old snapshot — treat as changed */}
        }
        await _repo.setSetting(
            cacheKey,
            jsonEncode(
                {'at': DateTime.now().millisecondsSinceEpoch, 'v': data}));
        if (!same) changed = true;
      } catch (_) {/* offline — keep the old snapshot */}
    }

    await Future.wait([
      pull('trakt:cache:playback', '$_api/sync/playback'),
      pull('trakt:cache:watched:movies', '$_api/sync/watched/movies'),
      pull('trakt:cache:watched:shows', '$_api/sync/watched/shows'),
      pull('trakt:cache:watchlist', '$_api/sync/watchlist'),
    ]);
    return changed;
  }

  /// Re-pull just the cross-device resume points. Chained after a stop
  /// scrobble so the cached playback snapshot reflects the session that just
  /// ended — without this, "continue watching" overlays could stay up to six
  /// hours behind what the user just watched.
  ///
  /// Returns true when the payload actually differs from what was cached, so
  /// callers can skip invalidating providers on a no-op refresh.
  Future<bool> refreshPlaybackCache() async {
    if (!await isConnected()) return false;
    try {
      final res =
          await _authGet('$_api/sync/playback', queryParameters: {'limit': '1000'});
      if (res.statusCode != 200) return false;
      final data = res.data is String ? jsonDecode(res.data) : res.data;
      final fresh = jsonEncode(data);
      var same = false;
      final old = await _repo.getSetting('trakt:cache:playback');
      if (old != null && old.isNotEmpty) {
        try {
          same = jsonEncode((jsonDecode(old) as Map)['v']) == fresh;
        } catch (_) {/* corrupt — treat as changed */}
      }
      await _repo.setSetting('trakt:cache:playback',
          jsonEncode({'at': DateTime.now().millisecondsSinceEpoch, 'v': data}));
      return !same;
    } catch (_) {
      return false; // best effort
    }
  }

  // ---- Per-title sync ------------------------------------------------------

  /// When each title was last reconciled with Trakt, so opening and closing a
  /// page repeatedly (or bouncing through a series' episodes) can't turn into
  /// a request storm on a slow TV box.
  static final Map<String, int> _titleSyncedAt = {};
  static const _titleSyncCooldown = Duration(seconds: 25);

  /// How stale the cached resume points must be before *opening* a title
  /// re-pulls them.
  static const _playbackMaxAge = Duration(minutes: 2);

  Future<bool> _playbackCacheOlderThan(Duration d) async {
    try {
      final raw = await _repo.getSetting('trakt:cache:playback');
      if (raw == null || raw.isEmpty) return true;
      final at = ((jsonDecode(raw) as Map)['at'] as num?)?.toInt() ?? 0;
      return DateTime.now().millisecondsSinceEpoch - at > d.inMilliseconds;
    } catch (_) {
      return true;
    }
  }

  /// Reconcile ONE title with Trakt, on the way into or out of its page.
  ///
  /// The app-open refresh is a whole-account pull on a schedule; this is the
  /// targeted version — it costs one or two small requests and makes the title
  /// you are actually looking at correct *now*. That matters most on TV boxes,
  /// where the background pull can be minutes behind by the time you've
  /// navigated somewhere.
  ///
  /// * `push` (leaving a title) first drains the write outbox, so anything
  ///   just watched reaches Trakt before we read back.
  /// * Resume points come from a single `/sync/playback` pull.
  /// * For shows the per-show watched-progress cache is dropped so the next
  ///   `watchedEpisodesFor` re-reads it — that's what keeps episode ticks
  ///   honest after watching on another device.
  ///
  /// Returns true when something changed and the caller should refresh its
  /// providers. Rate-limited per title; never throws.
  Future<bool> syncTitle(
    String title, {
    required bool isShow,
    int? year,
    bool push = false,
    bool force = false,
  }) async {
    if (!await isConnected()) return false;
    final key = '${isShow ? 's' : 'm'}:${title.toLowerCase().trim()}';
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force) {
      final last = _titleSyncedAt[key] ?? 0;
      if (now - last < _titleSyncCooldown.inMilliseconds) return false;
    }
    _titleSyncedAt[key] = now;
    try {
      // Local watch events must land on Trakt BEFORE we read state back, or a
      // just-finished episode reads as still-unwatched and the page flickers
      // back to its old marks.
      if (push) await flushOutbox();
      // Opening a title only re-pulls resume points when the snapshot has
      // actually gone stale — browsing through several titles in a minute
      // shouldn't refetch a 100+ entry playback list each time. Leaving one
      // always refetches: we just changed the state ourselves.
      final changed = (push || await _playbackCacheOlderThan(_playbackMaxAge))
          ? await refreshPlaybackCache()
          : false;
      var refreshedEpisodes = false;
      if (isShow) {
        final ids = await idsFor(title, year: year, isShow: true);
        final showId = ids?['trakt'] ?? ids?['slug'];
        if (showId != null) {
          // Drop the 6h cache and re-read now — one request for one show.
          await _repo.setSetting('trakt:cache:show_progress:$showId', null);
          await watchedEpisodesFor(title, year: year);
          refreshedEpisodes = true;
        }
      }
      // A show always reports true: its episode marks were just re-read, and
      // the provider that renders them has to be told to pick them up. The
      // cooldown above is what keeps that from being expensive.
      return changed || refreshedEpisodes;
    } catch (_) {
      return false;
    }
  }

  Future<void> _fetchUsername() async {
    try {
      final res = await _authGet('$_api/users/settings');
      final d = res.data is String ? jsonDecode(res.data) : res.data;
      final name = d['user']?['username'] ?? d['user']?['name'];
      if (name != null) await _repo.setSetting('trakt_username', '$name');
    } catch (_) {/* non-fatal */}
  }

  Future<String?> username() => _repo.getSetting('trakt_username');

  /// Fast health probe for the top-bar/Sources status: is the account linked
  /// and actually serving data (refreshing the token if needed)?
  Future<({bool configured, bool ok, String detail})> ping() async {
    final tok = await token();
    if (tok == null || tok.isEmpty) {
      return (configured: false, ok: false, detail: 'Not connected');
    }
    try {
      final res = await _authGet('$_api/users/settings');
      if (res.statusCode == 200) {
        final d = res.data is String ? jsonDecode(res.data) : res.data;
        final name =
            d is Map ? (d['user']?['username'] ?? d['user']?['name']) : null;
        return (
          configured: true,
          ok: true,
          detail: name != null ? '@$name' : 'Connected'
        );
      }
      return (
        configured: true,
        ok: false,
        detail: res.statusCode == 401
            ? 'Token expired — reconnect'
            : 'HTTP ${res.statusCode}'
      );
    } catch (_) {
      return (configured: true, ok: false, detail: 'Unreachable');
    }
  }

  /// Currently-popular movies (Trakt trending). Public endpoint — needs only
  /// the app's api key, so it works even before the user connects.
  Future<List<TraktItem>> trendingMovies({int limit = 30}) async {
    final clientId = await _clientId();
    if (clientId == null || clientId.isEmpty) return [];
    final list = await _cachedJson(
      'trakt:cache:trending',
      () => _dio.get('$_api/movies/trending',
          queryParameters: {'limit': '$limit'},
          options: Options(headers: {'trakt-api-key': clientId})),
      requireConnected: false, // public endpoint
    );
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
  /// Same explicit limit as refreshHomeSnapshots' pull of the SAME cache key:
  /// a bare fetch here got page one only (the endpoint paginates now), which
  /// truncated My List after every watchlist toggle AND made the byte-compare
  /// in refreshHomeSnapshots flag a phantom change on every open.
  Future<List<TraktItem>> watchlist() => _itemsFrom(
      '$_api/sync/watchlist', 'trakt:cache:watchlist',
      queryParameters: {'limit': '1000'});

  /// Movies the user has marked watched on Trakt.
  Future<List<TraktItem>> watchedMovies() async {
    try {
      final list = await _cachedJson(
          'trakt:cache:watched:movies',
          () => _authGet('$_api/sync/watched/movies',
              queryParameters: {'limit': '1000'}));
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
    } catch (_) {
      return [];
    }
  }

  /// Shows the user has watched (any episodes) on Trakt.
  Future<List<TraktItem>> watchedShows() async {
    try {
      final list = await _cachedJson(
          'trakt:cache:watched:shows',
          () => _authGet('$_api/sync/watched/shows',
              queryParameters: {'limit': '1000'}));
      final out = <TraktItem>[];
      if (list is List) {
        for (final e in list) {
          final m = e is Map ? e['show'] : null;
          if (m is Map && m['title'] != null) {
            out.add(TraktItem(
                title: '${m['title']}',
                year: (m['year'] as num?)?.toInt(),
                type: 'show'));
          }
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// The (season, episode) pairs the user has completed on Trakt for the show
  /// matching [title]. Empty when disconnected or the show can't be resolved.
  ///
  /// Uses the per-show progress endpoint (`/shows/{id}/progress/watched`), NOT
  /// `/sync/watched/shows`: as of the June 2026 Trakt API change the sync
  /// endpoint no longer returns any season/episode breakdown by default (and is
  /// now paginated), so the old approach reported every episode as un-watched
  /// for every show. The progress endpoint returns the full season → episode
  /// `completed` map for one show in a single call, always current.
  Future<Set<(int, int)>> watchedEpisodesFor(String title, {int? year}) async {
    if (!await isConnected()) return {};
    try {
      final ids = await idsFor(title, year: year, isShow: true);
      final showId = ids?['trakt'] ?? ids?['slug'];
      if (showId == null) return {};
      final data = await _cachedJson(
        'trakt:cache:show_progress:$showId',
        () => _authGet('$_api/shows/$showId/progress/watched'),
        ttl: const Duration(hours: 6),
      );
      if (data is! Map) return {};
      final out = <(int, int)>{};
      final seasons = data['seasons'];
      if (seasons is List) {
        for (final s in seasons) {
          final sn = (s is Map ? s['number'] : null) as num?;
          final eps = s is Map ? s['episodes'] : null;
          if (sn == null || eps is! List) continue;
          for (final ep in eps) {
            if (ep is! Map) continue;
            final en = (ep['number'] as num?)?.toInt();
            if (en != null && ep['completed'] == true) out.add((sn.toInt(), en));
          }
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  /// The user's custom Trakt lists.
  Future<List<TraktList>> lists() async {
    try {
      final list = await _cachedJson(
          'trakt:cache:lists', () => _authGet('$_api/users/me/lists'));
      final out = <TraktList>[];
      if (list is List) {
        for (final e in list) {
          if (e is Map && e['ids'] is Map) {
            out.add(TraktList(
                id: '${(e['ids'] as Map)['trakt']}',
                name: '${e['name'] ?? 'List'}',
                count: (e['item_count'] as num?)?.toInt() ?? 0));
          }
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<List<TraktItem>> listItems(String listId) => _itemsFrom(
      '$_api/users/me/lists/$listId/items/movies,shows',
      'trakt:cache:list:$listId',
      queryParameters: {'limit': '1000'});

  /// Live end-to-end sanity check: verifies the token, forces a refresh if the
  /// account call 401s, and reports real HTTP status + counts for each Trakt
  /// endpoint the home screen depends on. Nothing here is swallowed, so the
  /// user can actually see *why* rows are empty.
  Future<List<TraktCheck>> diagnostics() async {
    final out = <TraktCheck>[];

    final tok = await token();
    out.add(TraktCheck('Access token',
        ok: tok != null && tok.isNotEmpty,
        detail: (tok == null || tok.isEmpty)
            ? 'none saved — not connected'
            : 'present'));
    final cid = await _clientId();
    out.add(TraktCheck('API key (client id)',
        ok: cid != null && cid.isNotEmpty,
        detail: (cid == null || cid.isEmpty) ? 'missing' : 'present'));

    if (tok == null || tok.isEmpty) return out;

    Future<void> probe(String label, String url,
        {bool countList = true}) async {
      try {
        final res = await _authGet(url);
        final d = res.data is String ? jsonDecode(res.data) : res.data;
        final count = countList && d is List ? d.length : null;
        out.add(TraktCheck(label,
            ok: res.statusCode == 200,
            status: res.statusCode,
            count: count,
            detail: res.statusCode == 200
                ? null
                : (res.statusCode == 401
                    ? 'unauthorized — token refresh failed; reconnect'
                    : 'HTTP ${res.statusCode}')));
      } catch (e) {
        out.add(TraktCheck(label, ok: false, detail: '$e'));
      }
    }

    // Account: also confirms who we're linked to.
    try {
      final res = await _authGet('$_api/users/settings');
      final d = res.data is String ? jsonDecode(res.data) : res.data;
      final name =
          d is Map ? (d['user']?['username'] ?? d['user']?['name']) : null;
      if (name != null) await _repo.setSetting('trakt_username', '$name');
      out.add(TraktCheck('Account',
          ok: res.statusCode == 200 && name != null,
          status: res.statusCode,
          detail: name != null ? '@$name' : 'no user in response'));
    } catch (e) {
      out.add(TraktCheck('Account', ok: false, detail: '$e'));
    }

    await probe('Watchlist', '$_api/sync/watchlist');
    await probe('Custom lists', '$_api/users/me/lists');
    await probe('In-progress (playback)', '$_api/sync/playback');
    await probe('Watched movies', '$_api/sync/watched/movies');
    await probe('Watched shows', '$_api/sync/watched/shows');
    return out;
  }

  /// In-progress playback (resume points) across the user's devices. Cached
  /// for a few hours — local watch progress covers the current session, this
  /// only adds cross-device resume points.
  Future<List<TraktPlayback>> playback() async {
    try {
      final list = await _cachedJson(
          'trakt:cache:playback',
          () => _authGet('$_api/sync/playback',
              queryParameters: {'limit': '1000'}),
          ttl: const Duration(hours: 6));
      final out = <TraktPlayback>[];
      if (list is List) {
        for (final e in list) {
          if (e is! Map) continue;
          final prog = (e['progress'] as num?)?.toDouble();
          if (prog == null) continue;
          final pausedAt =
              DateTime.tryParse('${e['paused_at'] ?? ''}')?.millisecondsSinceEpoch ??
                  0;
          // Trakt returns an in-progress episode as type 'episode' with the
          // title split across a `show` node (the series) and an `episode` node
          // (season/number + the episode's own title). Continue Watching groups
          // on the SHOW title, so read that — reading e[type] here grabbed the
          // episode title ("Ozymandias"), which never matched the library and
          // silently dropped every show.
          final source = _sourceOf(e);
          if ('${e['type']}' == 'episode' || e['show'] is Map) {
            final show = e['show'];
            final ep = e['episode'];
            if (show is! Map || show['title'] == null) continue;
            out.add(TraktPlayback(
              item: TraktItem(
                  title: '${show['title']}',
                  year: (show['year'] as num?)?.toInt(),
                  type: 'show'),
              progress: prog / 100.0,
              season: ep is Map ? (ep['season'] as num?)?.toInt() : null,
              episode: ep is Map ? (ep['number'] as num?)?.toInt() : null,
              pausedAt: pausedAt,
              source: source,
            ));
          } else {
            final node = e['movie'];
            if (node is Map && node['title'] != null) {
              out.add(TraktPlayback(
                item: TraktItem(
                    title: '${node['title']}',
                    year: (node['year'] as num?)?.toInt(),
                    type: 'movie'),
                progress: prog / 100.0,
                pausedAt: pausedAt,
                source: source,
              ));
            }
          }
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Which outside service produced a `/sync/playback` row, when Trakt says so.
  ///
  /// Trakt's documented playback payload carries no provider field — resume
  /// points scrobbled by a player are anonymous. But rows imported by a
  /// streaming-service connection (the Netflix integration, and whatever
  /// follows it) are tagged, and Trakt has moved that tag around, so this
  /// sniffs the plausible spellings rather than hard-coding one. A row that
  /// declares nothing is treated as first-party — never guessed at.
  static const _sourceKeys = ['source', 'provider', 'service', 'app', 'via'];

  static String? _sourceOf(Map e) {
    for (final k in _sourceKeys) {
      final v = e[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      // Some shapes nest it: {"source": {"name": "Netflix"}}.
      if (v is Map) {
        final n = v['name'] ?? v['title'] ?? v['slug'];
        if (n is String && n.trim().isNotEmpty) return n.trim();
      }
    }
    return null;
  }

  /// Seed the local per-episode progress table from Trakt's cross-device resume
  /// points. A show the user is mid-way through on another device — or before a
  /// reinstall — then surfaces in Continue Watching through the exact same local
  /// path as on-device activity, with an accurate resume point, and persists
  /// because relinking Trakt re-seeds it. Never overwrites a fresher local row
  /// (compared on Trakt's `paused_at`) or one already finished locally. Returns
  /// true when at least one row was written, so the caller can re-emit the row.
  Future<bool> hydrateEpisodeProgress({int limit = kResumeSeedLimit}) async {
    if (!await isConnected()) return false;
    try {
      final resume = await playback();
      // Newest checkpoints first, then capped. Trakt's streaming-service
      // integrations can push an account's in-progress list into the hundreds;
      // seeding every one of them writes hundreds of rows into
      // `episode_progress` on every open, and Continue Watching then has to
      // group all of them on every build. Only the recent tail is ever shown,
      // so only the recent tail is worth storing.
      final recent = [...resume]
        ..sort((a, b) => b.pausedAt.compareTo(a.pausedAt));
      final existing = await _repo.db.episodeProgressAll();
      var changed = false;
      var seeded = 0;
      for (final p in recent) {
        if (seeded >= limit) break;
        if (!p.isShow || p.season == null || p.episode == null) continue;
        if (p.progress <= 0.02 || p.progress >= 0.97) continue;
        seeded++;
        final ek =
            episodeKey(cleanTitle(p.item.title).title, p.season!, p.episode!);
        final have = existing[ek];
        if (have != null && have.watched) continue; // finished locally already
        // A local row with a real position wins unless Trakt's checkpoint is
        // newer (watched elsewhere since). paused_at == 0 → unknown, don't clobber.
        if (have != null && (p.pausedAt == 0 || have.updatedAt >= p.pausedAt)) {
          continue;
        }
        await _repo.db
            .saveEpisodeProgressFraction(ek, p.progress, updatedAt: p.pausedAt);
        changed = true;
      }
      return changed;
    } catch (_) {
      return false;
    }
  }

  Future<List<TraktItem>> _itemsFrom(String url, String cacheKey,
      {Map<String, dynamic>? queryParameters}) async {
    final list = await _cachedJson(
        cacheKey, () => _authGet(url, queryParameters: queryParameters));
    final out = <TraktItem>[];
    if (list is List) {
      for (final e in list) {
        if (e is! Map) continue;
        final type = '${e['type']}';
        final node = e[type];
        if (node is Map && node['title'] != null) {
          out.add(TraktItem(
            title: '${node['title']}',
            year: (node['year'] as num?)?.toInt(),
            type: type,
          ));
        }
      }
    }
    return out;
  }

  /// Resume point (0..1) for a title from Trakt's cross-device playback store.
  /// Served from the CACHED playback snapshot (refreshed at every app open and
  /// after every stop scrobble) — the old live HTTP call here ran inside the
  /// player's load path, so on a slow link playback visibly started at 0:00
  /// and then jumped when the response landed. Title-matched, best-effort.
  Future<double?> resumeProgress(String title, {bool isShow = false}) async {
    if (!await isConnected()) return null;
    try {
      final needle = title.toLowerCase();
      for (final p in await playback()) {
        if (p.isShow != isShow) continue;
        final t = p.item.title.toLowerCase();
        if (t.isNotEmpty && (needle.contains(t) || t.contains(needle))) {
          return p.progress;
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
      final list =
          search.data is String ? jsonDecode(search.data) : search.data;
      if (list is! List || list.isEmpty) return;
      final node = (list.first as Map)[type];
      if (node is! Map) return;
      await _dio.post('$_api/scrobble/pause',
          data: jsonEncode({
            type: {'ids': node['ids']},
            'progress': progressPct
          }),
          options: Options(headers: await _authHeaders()));
    } catch (_) {/* best effort */}
  }

  /// Best-effort: mark a title watched on Trakt by searching for it first.
  /// IPTV items aren't tied to Trakt ids, so we match on title/year.
  Future<void> markWatched(String title,
      {int? year, bool isShow = false}) async {
    if (!await isConnected()) return;
    try {
      final type = isShow ? 'show' : 'movie';
      final search = await _dio.get('$_api/search/$type',
          queryParameters: {'query': title, if (year != null) 'years': '$year'},
          options: Options(headers: await _authHeaders()));
      final list =
          search.data is String ? jsonDecode(search.data) : search.data;
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

  /// Mark (or un-mark) an entire season watched on Trakt for the show matching
  /// [title]. Never blocks the local toggle; a failed write is QUEUED and
  /// replayed on the next flush instead of silently vanishing.
  Future<void> setSeasonWatched(String title, int season,
      {required bool watched}) async {
    if (!await isConnected()) return;
    final ok = await _postSeason(title, season, watched: watched);
    if (!ok) {
      await _enqueue({
        'op': 'season',
        'title': title,
        'isShow': true,
        'season': season,
        'watched': watched,
      });
    }
  }

  /// Raw season write (also the outbox replay path — must not re-enqueue).
  /// Posts the season to /sync/history (or /remove) — Trakt expands a bare
  /// season to all its episodes — then drops the affected snapshots so the
  /// next read reflects the change instead of the pre-toggle 6h cache.
  Future<bool> _postSeason(String title, int season,
      {required bool watched}) async {
    try {
      final ids = await idsFor(title, isShow: true);
      if (ids == null) return false;
      final ok = await _authPost(
        watched ? '$_api/sync/history' : '$_api/sync/history/remove',
        {
          'shows': [
            {
              'ids': ids,
              'seasons': [
                {'number': season}
              ],
            }
          ]
        },
      );
      if (!ok) return false;
      await _repo.setSetting('trakt:cache:watched:shows', null);
      // Drop the per-show progress snapshot too, or the season's episode checks
      // would keep reading the pre-toggle state for up to the 6h TTL.
      final sid = ids['trakt'] ?? ids['slug'];
      if (sid != null) {
        await _repo.setSetting('trakt:cache:show_progress:$sid', null);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Session cache of title → Trakt ids so pause/resume/stop cycles don't
  /// re-hit the search endpoint every time.
  final _idsCache = <String, Map<String, dynamic>?>{};

  /// Real-time scrobbling per the Trakt protocol. [action] is start | pause |
  /// stop. Trakt records the exact progress: a `stop` below 80% is stored as
  /// a paused checkpoint (shows at that timestamp in continue watching); at or
  /// above 80% the play is scrobbled as watched. Shows require the episode's
  /// season+number. Never throws into playback — but a WATCHED play (a stop at
  /// >=80%) that fails to send is queued as a history write and replayed
  /// later, so a flaky connection or expired token can't lose the watch.
  /// start/pause scrobbles stay fire-and-forget: replaying a stale "watching
  /// now" hours later would corrupt the user's live state.
  Future<void> scrobble(
    String action,
    String title, {
    bool isShow = false,
    int? season,
    int? episode,
    required double progressPct,
  }) async {
    if (!await isConnected()) return;
    // A show scrobble without an episode is meaningless to Trakt.
    if (isShow && (season == null || episode == null)) return;
    final isWatchedStop = action == 'stop' && progressPct >= 80;
    var sent = false;
    try {
      final key = '${isShow ? 's' : 'm'}:${title.toLowerCase()}';
      final ids = _idsCache.containsKey(key)
          ? _idsCache[key]
          : _idsCache[key] = await idsFor(title, isShow: isShow);
      if (ids != null) {
        final body = <String, dynamic>{
          'progress': progressPct.clamp(0, 100),
          if (!isShow) 'movie': {'ids': ids},
          if (isShow) 'show': {'ids': ids},
          if (isShow) 'episode': {'season': season, 'number': episode},
        };
        final status = await _authPostStatus('$_api/scrobble/$action', body);
        // 409 = Trakt already has this exact scrobble (a rewatch of the same
        // ending within its dedupe window) — the play IS recorded; queueing a
        // history add on top would double-count it.
        sent = status != null &&
            (status >= 200 && status < 300 || status == 409);
      }
    } catch (_) {/* fall through to the queue check */}
    if (isWatchedStop) {
      if (!sent) {
        await _enqueue({
          'op': 'history_add',
          'title': title,
          'isShow': isShow,
          'season': season,
          'episode': episode,
          'watched_at': DateTime.now().toUtc().toIso8601String(),
        });
      } else {
        // Connectivity just proved itself — drain anything queued earlier.
        // This runs in BOTH experiences (classic + Aurora scrobble through
        // this same service), so queued events never sit forever.
        unawaited(flushOutbox());
      }
    }
  }

  /// Resolve a title to its Trakt id node (contains imdb/tmdb/trakt ids).
  /// Public search endpoint — works with just the api key. Hits persist in
  /// the DB for 30 days: repeat scrobbles, watched-episode checks and season
  /// toggles for known titles cost ZERO search round-trips (misses are not
  /// cached — they may be transient). The TTL bounds the damage of a wrong
  /// first search hit for an ambiguous title: it self-corrects within a
  /// month rather than mis-attributing that title's activity forever.
  Future<Map<String, dynamic>?> idsFor(String title,
      {int? year, bool isShow = false}) async {
    final type = isShow ? 'show' : 'movie';
    final cacheKey =
        'trakt:cache:ids:$type:${title.trim().toLowerCase()}${year != null ? ':$year' : ''}';
    const ttlMs = 30 * 24 * 3600 * 1000;
    try {
      final cached = await _repo.getSetting(cacheKey);
      if (cached != null && cached.isNotEmpty) {
        final wrap = jsonDecode(cached);
        if (wrap is Map && wrap['v'] is Map) {
          final at = (wrap['at'] as num?)?.toInt() ?? 0;
          if (DateTime.now().millisecondsSinceEpoch - at < ttlMs) {
            return Map<String, dynamic>.from(wrap['v'] as Map);
          }
        }
      }
    } catch (_) {/* corrupt — refetch */}
    try {
      final search = await _dio.get('$_api/search/$type',
          queryParameters: {'query': title, if (year != null) 'years': '$year'},
          options: Options(headers: await _authHeaders()));
      final list =
          search.data is String ? jsonDecode(search.data) : search.data;
      if (list is! List || list.isEmpty) return null;
      final node = (list.first as Map)[type];
      if (node is! Map || node['ids'] is! Map) return null;
      final ids = Map<String, dynamic>.from(node['ids'] as Map);
      try {
        await _repo.setSetting(
            cacheKey,
            jsonEncode(
                {'at': DateTime.now().millisecondsSinceEpoch, 'v': ids}));
      } catch (_) {/* non-fatal */}
      return ids;
    } catch (_) {
      return null;
    }
  }

  /// Keep the Trakt watchlist in sync with the in-app "My List": add/remove a
  /// title (matched by name/year, like scrobbling). Never blocks the local
  /// favorite; a failed write is queued for the next flush.
  Future<void> setInWatchlist(String title,
      {int? year, bool isShow = false, required bool inList}) async {
    if (!await isConnected()) return;
    final ok =
        await _postWatchlist(title, year: year, isShow: isShow, inList: inList);
    if (!ok) {
      await _enqueue({
        'op': 'watchlist',
        'title': title,
        'year': year,
        'isShow': isShow,
        'inList': inList,
      });
    }
  }

  /// Raw watchlist write (also the outbox replay path — must not re-enqueue).
  Future<bool> _postWatchlist(String title,
      {int? year, bool isShow = false, required bool inList}) async {
    try {
      final ids = await idsFor(title, year: year, isShow: isShow);
      if (ids == null) return false;
      final type = isShow ? 'show' : 'movie';
      final ok = await _authPost(
          inList ? '$_api/sync/watchlist' : '$_api/sync/watchlist/remove', {
        '${type}s': [
          {'ids': ids}
        ]
      });
      if (!ok) return false;
      // The watchlist changed — drop its snapshot so the next read reflects it.
      await _repo.setSetting('trakt:cache:watchlist', null);
      return true;
    } catch (_) {
      return false;
    }
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

class TraktList {
  final String id;
  final String name;
  final int count;
  const TraktList({required this.id, required this.name, this.count = 0});
}

class TraktPlayback {
  final TraktItem item; // for shows, item.title is the SHOW title (type 'show')
  final double progress; // 0..1
  final int? season; // set for episode resume points
  final int? episode; // set for episode resume points
  final int pausedAt; // Trakt paused_at in ms since epoch (0 if unknown)

  /// Where the entry came from, when Trakt says. Trakt's own scrobbles carry
  /// no provider, but rows synced in by a streaming-service connection (the
  /// Netflix integration and friends) identify themselves — see
  /// [TraktService._sourceOf] for the keys we look at. null = "Trakt didn't
  /// tell us", which we treat as first-party.
  final String? source;

  const TraktPlayback({
    required this.item,
    required this.progress,
    this.season,
    this.episode,
    this.pausedAt = 0,
    this.source,
  });
  bool get isShow => item.type == 'show';

  /// True when this resume point was imported from an outside service rather
  /// than scrobbled by a player.
  bool get isExternal => source != null && source!.isNotEmpty;
}

/// One line of the Trakt connectivity sanity check.
class TraktCheck {
  final String name;
  final bool ok;
  final int? status;
  final int? count;
  final String? detail;
  const TraktCheck(this.name,
      {required this.ok, this.status, this.count, this.detail});
}

// ---- Providers -------------------------------------------------------------

final traktServiceProvider = FutureProvider<TraktService>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  return TraktService(repo);
});

/// Connection state, refreshable after connect/disconnect.
final traktConnectedProvider = FutureProvider<bool>((ref) async {
  final svc = await ref.watch(traktServiceProvider.future);
  return svc.isConnected();
});

final traktUsernameProvider = FutureProvider<String?>((ref) async {
  final svc = await ref.watch(traktServiceProvider.future);
  return svc.username();
});

final traktWatchlistProvider = FutureProvider<List<TraktItem>>((ref) async {
  final connected = await ref.watch(traktConnectedProvider.future);
  if (!connected) return [];
  final svc = await ref.watch(traktServiceProvider.future);
  return svc.watchlist();
});

final traktListsProvider = FutureProvider<List<TraktList>>((ref) async {
  final connected = await ref.watch(traktConnectedProvider.future);
  if (!connected) return [];
  final svc = await ref.watch(traktServiceProvider.future);
  return svc.lists();
});

final traktListItemsProvider =
    FutureProvider.family<List<TraktItem>, String>((ref, listId) async {
  final svc = await ref.watch(traktServiceProvider.future);
  return svc.listItems(listId);
});
