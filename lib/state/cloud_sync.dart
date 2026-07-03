import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../data/repositories/library_repository.dart';
import 'providers.dart';
import 'sync_hooks.dart';

/// Google-account cloud backup — modern sign-in, zero backend of our own.
///
/// The user's whole setup is serialized into one JSON snapshot and stored in
/// their *own* Google Drive appData folder (hidden app storage only this app
/// can see): sources, every settings key (Trakt/RD/TMDB credentials, UI
/// choice, home layout), favorites, watch progress, per-episode progress and
/// pinned categories. Favorites/progress are keyed by stream **url** and pins
/// by playlist url, so a snapshot survives re-syncs and restores cleanly on a
/// brand-new device.
///
/// Behaviour:
/// - **First sign-in (no remote snapshot):** the current local setup is pushed
///   up immediately — "as soon as an account is created, save current info".
/// - **Returning sign-in (remote exists):** remote is merged into local
///   (newer-wins for progress), then the merged state is pushed back up.
/// - **Afterwards:** any user-data change marks the snapshot dirty and a
///   debounced upload runs ~20s later; a library re-sync re-applies any
///   pending restore against the fresh stream ids.
class CloudSync {
  CloudSync(this._repo) {
    instance = this;
    onUserDataChanged = markDirty;
    onLibrarySynced = _afterLibrarySync;
  }

  static CloudSync? instance;
  final LibraryRepository _repo;

  static const _fileName = 'lumen_backup.json';
  static const _drive = 'https://www.googleapis.com/drive/v3';
  static const _upload = 'https://www.googleapis.com/upload/drive/v3';
  static const _pendingKey = 'cloud_pending_apply';

  final GoogleSignIn _google = GoogleSignIn(scopes: const [
    'email',
    'https://www.googleapis.com/auth/drive.appdata',
  ]);

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    validateStatus: (s) => s != null && s < 500,
  ));

  GoogleSignInAccount? account;
  Timer? _debounce;
  bool _busy = false;

  /// Last backup wall-clock ms (session-scoped, for the settings subtitle).
  int? lastBackupAt;

  // ---- Session lifecycle ---------------------------------------------------

  /// Restore the signed-in session without UI (app start). Never throws.
  Future<GoogleSignInAccount?> silent() async {
    try {
      account = await _google.signInSilently();
    } catch (_) {/* not configured / offline — stay signed out */}
    return account;
  }

  /// Interactive sign-in. On success runs the first-sync handshake
  /// (restore-if-exists, then push). Throws with a readable message when the
  /// platform isn't configured for Google sign-in.
  Future<GoogleSignInAccount?> signIn() async {
    try {
      account = await _google.signIn();
    } catch (e) {
      throw Exception(
          'Google sign-in isn\'t available on this build ($e). '
          'The app needs an OAuth client registered for its signing key — '
          'see the README\'s "Google account backup" section.');
    }
    if (account != null) await _handshake();
    return account;
  }

  Future<void> signOut() async {
    _debounce?.cancel();
    try {
      await _google.signOut();
    } catch (_) {/* best effort */}
    account = null;
  }

  /// First contact after an interactive sign-in.
  Future<void> _handshake() async {
    try {
      final remote = await _downloadSnapshot();
      if (remote != null) {
        await _applySnapshot(remote);
        // Stash it so favorites/progress re-apply after the next library
        // sync reassigns stream ids.
        await _repo.setSetting(_pendingKey, jsonEncode(remote));
      }
      await pushNow(); // local (possibly merged) state becomes the backup
    } catch (_) {/* offline — the debounced push will retry later */}
  }

  Future<void> _afterLibrarySync() async {
    try {
      final pending = await _repo.getSetting(_pendingKey);
      if (pending != null && pending.isNotEmpty) {
        await _applySnapshot(jsonDecode(pending) as Map<String, dynamic>);
        await _repo.setSetting(_pendingKey, null);
      }
    } catch (_) {/* keep pending for the next sync */}
    markDirty();
  }

  /// Debounced auto-backup — call whenever user data changes.
  void markDirty() {
    if (account == null) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 20), pushNow);
  }

  // ---- Drive I/O -----------------------------------------------------------

  Future<Map<String, String>?> _headers() async {
    final a = account;
    if (a == null) return null;
    try {
      return await a.authHeaders;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _fileId(Map<String, String> headers) async {
    final res = await _dio.get(
      '$_drive/files',
      queryParameters: {
        'spaces': 'appDataFolder',
        'q': "name='$_fileName'",
        'fields': 'files(id,name)',
      },
      options: Options(headers: headers),
    );
    if (res.statusCode != 200) return null;
    final d = res.data is String ? jsonDecode(res.data) : res.data;
    final files = d is Map ? d['files'] : null;
    if (files is List && files.isNotEmpty) {
      return '${(files.first as Map)['id']}';
    }
    return null;
  }

  Future<Map<String, dynamic>?> _downloadSnapshot() async {
    final headers = await _headers();
    if (headers == null) return null;
    final id = await _fileId(headers);
    if (id == null) return null;
    final res = await _dio.get(
      '$_drive/files/$id',
      queryParameters: {'alt': 'media'},
      options: Options(headers: headers, responseType: ResponseType.plain),
    );
    if (res.statusCode != 200) return null;
    try {
      final d = jsonDecode('${res.data}');
      return d is Map<String, dynamic> ? d : null;
    } catch (_) {
      return null;
    }
  }

  /// Serialize + upload the snapshot right now. Safe to call repeatedly.
  Future<bool> pushNow() async {
    if (account == null || _busy) return false;
    _busy = true;
    try {
      final headers = await _headers();
      if (headers == null) return false;
      final body = jsonEncode(await _buildSnapshot());

      var id = await _fileId(headers);
      if (id == null) {
        final created = await _dio.post(
          '$_drive/files',
          data: jsonEncode({
            'name': _fileName,
            'parents': ['appDataFolder'],
          }),
          options: Options(
              headers: {...headers, 'Content-Type': 'application/json'}),
        );
        if (created.statusCode != 200) return false;
        final d = created.data is String
            ? jsonDecode(created.data)
            : created.data;
        id = d is Map ? '${d['id']}' : null;
        if (id == null) return false;
      }
      final up = await _dio.patch(
        '$_upload/files/$id',
        queryParameters: {'uploadType': 'media'},
        data: body,
        options: Options(
            headers: {...headers, 'Content-Type': 'application/json'}),
      );
      final ok = up.statusCode == 200;
      if (ok) lastBackupAt = DateTime.now().millisecondsSinceEpoch;
      return ok;
    } catch (_) {
      return false;
    } finally {
      _busy = false;
    }
  }

  // ---- Snapshot build / apply ------------------------------------------------

  Future<Map<String, dynamic>> _buildSnapshot() async {
    final d = _repo.db.db;
    final playlists = await d.rawQuery(
        'SELECT name, kind, url, username, password, epg_url, created_at '
        'FROM playlists');
    // Skip bulky HTTP caches (tmdb:*) and our own bookkeeping key; everything
    // else — credentials, UI choice, layout — travels with the account.
    final settings = await d.rawQuery(
        "SELECT key, value FROM app_settings "
        "WHERE key NOT LIKE 'tmdb:%' AND key != ?",
        [_pendingKey]);
    final favorites = await d.rawQuery(
        'SELECT s.url AS url, f.added_at AS added_at '
        'FROM favorites f JOIN streams s ON s.id = f.stream_id');
    final progress = await d.rawQuery(
        'SELECT s.url AS url, p.position_ms, p.duration_ms, p.watched, '
        'p.updated_at FROM progress p JOIN streams s ON s.id = p.stream_id');
    final episodes = await d.rawQuery('SELECT * FROM episode_progress');
    final pins = await d.rawQuery(
        'SELECT pl.url AS playlist_url, pc.kind, pc.name, pc.position '
        'FROM pinned_categories pc JOIN playlists pl ON pl.id = pc.playlist_id');

    return {
      'v': 1,
      'at': DateTime.now().millisecondsSinceEpoch,
      'playlists': playlists,
      'settings': {
        for (final r in settings) '${r['key']}': r['value'],
      },
      'favorites': favorites,
      'progress': progress,
      'episodes': episodes,
      'pins': pins,
    };
  }

  /// Merge a snapshot into the local database. Idempotent; favorites and pins
  /// union, progress is newest-wins, missing streams are skipped silently
  /// (they re-apply after the next library sync via [_afterLibrarySync]).
  Future<void> _applySnapshot(Map<String, dynamic> snap) async {
    final d = _repo.db.db;

    // Playlists: add any source we don't already have (matched by url).
    final localPls = await d.query('playlists', columns: ['id', 'url']);
    final localUrls = {for (final r in localPls) '${r['url']}'};
    final pls = snap['playlists'];
    if (pls is List) {
      for (final p in pls) {
        if (p is! Map || localUrls.contains('${p['url']}')) continue;
        await d.insert('playlists', {
          'name': '${p['name'] ?? 'Restored source'}',
          'kind': '${p['kind'] ?? 'm3u'}',
          'url': '${p['url']}',
          'username': p['username'],
          'password': p['password'],
          'epg_url': p['epg_url'],
          'created_at':
              (p['created_at'] as num?)?.toInt() ??
                  DateTime.now().millisecondsSinceEpoch,
        });
      }
    }

    // Settings: the account's values win (that's what restore means).
    final settings = snap['settings'];
    if (settings is Map) {
      for (final e in settings.entries) {
        if ('${e.key}' == _pendingKey) continue;
        await _repo.setSetting('${e.key}', e.value?.toString());
      }
    }

    // Favorites by stream url — union.
    final favs = snap['favorites'];
    if (favs is List) {
      for (final f in favs) {
        if (f is! Map || f['url'] == null) continue;
        await d.rawInsert(
            'INSERT OR IGNORE INTO favorites(stream_id, added_at) '
            'SELECT id, ? FROM streams WHERE url = ? LIMIT 1',
            [
              (f['added_at'] as num?)?.toInt() ??
                  DateTime.now().millisecondsSinceEpoch,
              '${f['url']}',
            ]);
      }
    }

    // Watch progress by stream url — newest-wins.
    final prog = snap['progress'];
    if (prog is List) {
      for (final p in prog) {
        if (p is! Map || p['url'] == null) continue;
        final rows = await d.rawQuery(
            'SELECT s.id AS id, pr.updated_at AS at FROM streams s '
            'LEFT JOIN progress pr ON pr.stream_id = s.id '
            'WHERE s.url = ? LIMIT 1',
            ['${p['url']}']);
        if (rows.isEmpty) continue;
        final id = rows.first['id'] as int?;
        final localAt = (rows.first['at'] as num?)?.toInt() ?? -1;
        final remoteAt = (p['updated_at'] as num?)?.toInt() ?? 0;
        if (id == null || remoteAt <= localAt) continue;
        await d.rawInsert(
            'INSERT OR REPLACE INTO progress'
            '(stream_id, position_ms, duration_ms, watched, updated_at) '
            'VALUES(?,?,?,?,?)',
            [
              id,
              (p['position_ms'] as num?)?.toInt() ?? 0,
              (p['duration_ms'] as num?)?.toInt() ?? 0,
              (p['watched'] as num?)?.toInt() ?? 0,
              remoteAt,
            ]);
      }
    }

    // Episode progress — keyed independently of stream ids; newest-wins.
    final eps = snap['episodes'];
    if (eps is List) {
      for (final e in eps) {
        if (e is! Map || e['ep_key'] == null) continue;
        final rows = await d.query('episode_progress',
            columns: ['updated_at'],
            where: 'ep_key = ?',
            whereArgs: ['${e['ep_key']}'],
            limit: 1);
        final localAt = rows.isEmpty
            ? -1
            : (rows.first['updated_at'] as num?)?.toInt() ?? -1;
        final remoteAt = (e['updated_at'] as num?)?.toInt() ?? 0;
        if (remoteAt <= localAt) continue;
        await d.rawInsert(
            'INSERT OR REPLACE INTO episode_progress'
            '(ep_key, position_ms, duration_ms, watched, updated_at) '
            'VALUES(?,?,?,?,?)',
            [
              '${e['ep_key']}',
              (e['position_ms'] as num?)?.toInt() ?? 0,
              (e['duration_ms'] as num?)?.toInt() ?? 0,
              (e['watched'] as num?)?.toInt() ?? 0,
              remoteAt,
            ]);
      }
    }

    // Pinned categories — mapped back via playlist url; union.
    final pins = snap['pins'];
    if (pins is List) {
      final byUrl = {
        for (final r in await d.query('playlists', columns: ['id', 'url']))
          '${r['url']}': r['id'] as int,
      };
      for (final p in pins) {
        if (p is! Map) continue;
        final plId = byUrl['${p['playlist_url']}'];
        if (plId == null || p['name'] == null || p['kind'] == null) continue;
        await d.insert(
          'pinned_categories',
          {
            'playlist_id': plId,
            'kind': '${p['kind']}',
            'name': '${p['name']}',
            'position': (p['position'] as num?)?.toInt() ?? 0,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// The signed-in Google account (null = signed out). UI watches this.
final cloudAccountProvider =
    StateProvider<GoogleSignInAccount?>((ref) => null);

/// Constructs the singleton and restores the session silently on app start;
/// if a session exists, schedules a fresh backup of the current state.
final cloudSyncProvider = FutureProvider<CloudSync>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final cs = CloudSync(repo);
  final acct = await cs.silent();
  if (acct != null) {
    Future.microtask(() {
      try {
        ref.read(cloudAccountProvider.notifier).state = acct;
      } catch (_) {/* container disposed */}
    });
    cs.markDirty();
  }
  return cs;
});
