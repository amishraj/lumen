import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/library_repository.dart';
import '../models/models.dart';
import '../../state/providers.dart';
import '../../ui/title_utils.dart';

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
        final res = await _authGet(url);
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
  Future<void> refreshPlaybackCache() async {
    if (!await isConnected()) return;
    try {
      final res = await _authGet('$_api/sync/playback');
      if (res.statusCode != 200) return;
      final data = res.data is String ? jsonDecode(res.data) : res.data;
      await _repo.setSetting('trakt:cache:playback',
          jsonEncode({'at': DateTime.now().millisecondsSinceEpoch, 'v': data}));
    } catch (_) {/* best effort */}
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
  Future<List<TraktItem>> watchlist() =>
      _itemsFrom('$_api/sync/watchlist', 'trakt:cache:watchlist');

  /// Movies the user has marked watched on Trakt.
  Future<List<TraktItem>> watchedMovies() async {
    try {
      final list = await _cachedJson('trakt:cache:watched:movies',
          () => _authGet('$_api/sync/watched/movies'));
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
      final list = await _cachedJson('trakt:cache:watched:shows',
          () => _authGet('$_api/sync/watched/shows'));
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

  /// The (season, episode) pairs the user has watched on Trakt for the show
  /// matching [title]. Empty when disconnected, on a cache miss, or when no
  /// show matches. Reuses the same cached `/sync/watched/shows` payload as
  /// [watchedShows], so it's effectively free once that's warm.
  Future<Set<(int, int)>> watchedEpisodesFor(String title) async {
    try {
      final list = await _cachedJson('trakt:cache:watched:shows',
          () => _authGet('$_api/sync/watched/shows'));
      if (list is! List) return {};
      final want = _titleKeyVariants(title);
      for (final e in list) {
        final show = e is Map ? e['show'] : null;
        if (show is! Map || show['title'] == null) continue;
        // Tolerant match: a bare trailing year ("Gen V 2023") or a leading
        // "The" in the library's name must still line up with Trakt's clean
        // title, or every episode silently reads as un-watched. Mirrors the
        // article/year tolerance the library TitleIndex already uses.
        if (want.intersection(_titleKeyVariants('${show['title']}')).isEmpty) {
          continue;
        }
        final out = <(int, int)>{};
        final seasons = e['seasons'];
        if (seasons is List) {
          for (final s in seasons) {
            final sn = (s is Map ? s['number'] : null) as num?;
            final eps = s is Map ? s['episodes'] : null;
            if (sn == null || eps is! List) continue;
            for (final ep in eps) {
              final en = (ep is Map ? ep['number'] : null) as num?;
              if (en != null) out.add((sn.toInt(), en.toInt()));
            }
          }
        }
        return out;
      }
      return {};
    } catch (_) {
      return {};
    }
  }

  /// Loose title key for matching a library show against a Trakt show —
  /// l-case, alphanumerics only (drops punctuation and spacing).
  static String _titleKey(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static final _trailingYearKey = RegExp(r'(19|20)\d{2}$');

  /// Equivalent title keys for a show name: the base key plus leading-"the"
  /// and trailing-year variants, so "The Office"/"Office" and "Gen V"/"Gen V
  /// 2023" match. Two shows match when their variant sets intersect. Mirrors
  /// [TitleIndex]'s `_bucketFor` tolerance so watched-episode marks line up
  /// with the same shows the library already reconciles.
  static Set<String> _titleKeyVariants(String s) {
    final k = _titleKey(s);
    if (k.isEmpty) return const {};
    final out = <String>{k};
    if (k.startsWith('the') && k.length > 3) {
      out.add(k.substring(3));
    } else {
      out.add('the$k');
    }
    final m = _trailingYearKey.firstMatch(k);
    if (m != null && m.start > 0) out.add(k.substring(0, m.start));
    return out;
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
      'trakt:cache:list:$listId');

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
      final list = await _cachedJson('trakt:cache:playback',
          () => _authGet('$_api/sync/playback'),
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

  /// Seed the local per-episode progress table from Trakt's cross-device resume
  /// points. A show the user is mid-way through on another device — or before a
  /// reinstall — then surfaces in Continue Watching through the exact same local
  /// path as on-device activity, with an accurate resume point, and persists
  /// because relinking Trakt re-seeds it. Never overwrites a fresher local row
  /// (compared on Trakt's `paused_at`) or one already finished locally. Returns
  /// true when at least one row was written, so the caller can re-emit the row.
  Future<bool> hydrateEpisodeProgress() async {
    if (!await isConnected()) return false;
    try {
      final resume = await playback();
      final existing = await _repo.db.episodeProgressAll();
      var changed = false;
      for (final p in resume) {
        if (!p.isShow || p.season == null || p.episode == null) continue;
        if (p.progress <= 0.02 || p.progress >= 0.97) continue;
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

  Future<List<TraktItem>> _itemsFrom(String url, String cacheKey) async {
    final list = await _cachedJson(cacheKey, () => _authGet(url));
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
  /// Title-matched, so best-effort for IPTV items.
  Future<double?> resumeProgress(String title, {bool isShow = false}) async {
    if (!await isConnected()) return null;
    try {
      final type = isShow ? 'episodes' : 'movies';
      final res = await _authGet('$_api/sync/playback/$type');
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
  /// [title]. Resolves the show's ids by search, then posts the season to
  /// /sync/history (or /sync/history/remove) — Trakt expands a bare season to
  /// all its episodes. Best-effort: a failure never blocks the local toggle.
  /// Invalidates the cached watched-shows snapshot so the next read reflects it.
  Future<void> setSeasonWatched(String title, int season,
      {required bool watched}) async {
    if (!await isConnected()) return;
    try {
      final ids = await idsFor(title, isShow: true);
      if (ids == null) return;
      await _dio.post(
        watched ? '$_api/sync/history' : '$_api/sync/history/remove',
        data: jsonEncode({
          'shows': [
            {
              'ids': ids,
              'seasons': [
                {'number': season}
              ],
            }
          ]
        }),
        options: Options(headers: await _authHeaders()),
      );
      await _repo.setSetting('trakt:cache:watched:shows', null);
    } catch (_) {/* best effort */}
  }

  /// Session cache of title → Trakt ids so pause/resume/stop cycles don't
  /// re-hit the search endpoint every time.
  final _idsCache = <String, Map<String, dynamic>?>{};

  /// Real-time scrobbling per the Trakt protocol. [action] is start | pause |
  /// stop. Trakt records the exact progress: a `stop` below 80% is stored as
  /// a paused checkpoint (shows at that timestamp in continue watching); at or
  /// above 80% the play is scrobbled as watched. Shows require the episode's
  /// season+number. Best-effort — never throws into playback.
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
    try {
      final key = '${isShow ? 's' : 'm'}:${title.toLowerCase()}';
      final ids = _idsCache.containsKey(key)
          ? _idsCache[key]
          : _idsCache[key] = await idsFor(title, isShow: isShow);
      if (ids == null) return;
      final body = <String, dynamic>{
        'progress': progressPct.clamp(0, 100),
        if (!isShow) 'movie': {'ids': ids},
        if (isShow) 'show': {'ids': ids},
        if (isShow) 'episode': {'season': season, 'number': episode},
      };
      await _dio.post('$_api/scrobble/$action',
          data: jsonEncode(body),
          options: Options(headers: await _authHeaders()));
    } catch (_) {/* best effort */}
  }

  /// Resolve a title to its Trakt id node (contains imdb/tmdb/trakt ids).
  /// Public search endpoint — works with just the api key.
  Future<Map<String, dynamic>?> idsFor(String title,
      {int? year, bool isShow = false}) async {
    try {
      final type = isShow ? 'show' : 'movie';
      final search = await _dio.get('$_api/search/$type',
          queryParameters: {'query': title, if (year != null) 'years': '$year'},
          options: Options(headers: await _authHeaders()));
      final list =
          search.data is String ? jsonDecode(search.data) : search.data;
      if (list is! List || list.isEmpty) return null;
      final node = (list.first as Map)[type];
      if (node is! Map || node['ids'] is! Map) return null;
      return Map<String, dynamic>.from(node['ids'] as Map);
    } catch (_) {
      return null;
    }
  }

  /// Keep the Trakt watchlist in sync with the in-app "My List": add/remove a
  /// title (matched by name/year, like scrobbling). Best effort — a failure
  /// never blocks the local favorite.
  Future<void> setInWatchlist(String title,
      {int? year, bool isShow = false, required bool inList}) async {
    if (!await isConnected()) return;
    try {
      final ids = await idsFor(title, year: year, isShow: isShow);
      if (ids == null) return;
      final type = isShow ? 'show' : 'movie';
      await _dio.post(
          inList ? '$_api/sync/watchlist' : '$_api/sync/watchlist/remove',
          data: jsonEncode({
            '${type}s': [
              {'ids': ids}
            ]
          }),
          options: Options(headers: await _authHeaders()));
      // The watchlist changed — drop its snapshot so the next read reflects it.
      await _repo.setSetting('trakt:cache:watchlist', null);
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
  const TraktPlayback({
    required this.item,
    required this.progress,
    this.season,
    this.episode,
    this.pausedAt = 0,
  });
  bool get isShow => item.type == 'show';
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
