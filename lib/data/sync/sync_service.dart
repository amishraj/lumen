import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:dio/dio.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../db/app_database.dart';
import '../models/models.dart';
import '../repositories/library_repository.dart';
import 'apply.dart';
import 'auth_service.dart';
import 'sync_clock.dart';
import 'synced_settings.dart';

/// The push/pull engine against the Worker's /v1/sync.
///
/// Ordering invariant (Trakt coexistence): push → pull → THEN any Trakt
/// work. A pulled prog row must be in place before hydrateEpisodeProgress
/// evaluates its freshness guard, or it re-seeds a row a peer superseded.
/// This class never touches Trakt (and apply.dart can't import it).
class SyncService {
  SyncService(this._repo, this._auth);
  final LibraryRepository _repo;
  final AuthService _auth;

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 30),
    validateStatus: (s) => s != null && s < 500,
  ));

  bool _running = false;
  Timer? _debounce;
  bool sourcesChanged = false;

  /// Install the outbox listener (3s debounce — favorites/pins/settings push
  /// soon after the action; progress rides the player-close push).
  void installAutoPush() {
    AppDatabase.onOutboxChanged = () {
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 3), () {
        unawaited(pushPull());
      });
    };
  }

  Future<int> _cursor() async =>
      int.tryParse(await _syncState('cursor') ?? '') ?? 0;

  Future<String?> _syncState(String key) async {
    final rows = await _repo.db.db
        .query('sync_state', where: 'key=?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> _setSyncState(String key, String? value) async {
    if (value == null) {
      await _repo.db.db.delete('sync_state', where: 'key=?', whereArgs: [key]);
    } else {
      await _repo.db.db.insert('sync_state', {'key': key, 'value': value},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// One full round: drain the outbox, apply the change pages, converge.
  /// Returns true when anything changed locally (caller invalidates).
  Future<bool> pushPull({bool force = false, bool forceComplete = false}) async {
    if (_running) return false;
    if (!await _auth.signedIn) return false;
    final base = await _auth.apiBase();
    if (base == null) return false;
    _running = true;
    sourcesChanged = false;
    try {
      var anyChange = false;
      var more = true;
      var first = true;
      while (more) {
        // Coalesced outbox rows (only on the first page — later pages are
        // pull-only so a slow loop can't re-send).
        final outbox = first
            ? await _repo.db.db.query('sync_outbox',
                where: 'attempts<25', orderBy: 'updated_at', limit: 200)
            : const <Map<String, Object?>>[];
        first = false;
        final ops = [
          for (final r in outbox)
            {
              'ns': r['ns'],
              'k': r['k'],
              'v': r['v'] == null ? null : jsonDecode(r['v'] as String),
              'deleted': (r['deleted'] as int? ?? 0) != 0,
              'updated_at': r['updated_at'],
            }
        ];

        final epoch = int.tryParse(await _syncState('epoch') ?? '') ?? 0;
        final t0 = DateTime.now();
        final res = await _dio.post(
          '$base/v1/sync${force ? '?force=1' : ''}',
          data: jsonEncode({
            'cursor': await _cursor(),
            'epoch': epoch,
            'device_id': await _repo.getSetting('lumen_device_id'),
            'ops': ops,
            if (forceComplete && !more) 'force_complete': true,
            if (forceComplete) 'force_complete': true,
          }),
          options: Options(headers: {
            'authorization': 'Bearer ${await _auth.token()}',
            'content-type': 'application/json',
          }),
        );

        // Clock offset from the server's Date header — the thing that makes
        // LWW stamps trustworthy on NTP-less TV boxes.
        final dateHeader = res.headers.value('date');
        if (dateHeader != null) {
          try {
            final serverNow = HttpDate.parse(dateHeader);
            final rtt = DateTime.now().difference(t0);
            SyncClock.offsetMs = serverNow
                .add(rtt ~/ 2)
                .difference(DateTime.now())
                .inMilliseconds;
            await _setSyncState('clock_offset', '${SyncClock.offsetMs}');
          } catch (_) {}
        }

        if (res.statusCode == 409) {
          // Force-mode epoch bump elsewhere: adopt it and retry once.
          final d = res.data is String ? jsonDecode(res.data) : res.data;
          await _setSyncState('epoch', '${d['epoch'] ?? 0}');
          continue;
        }
        if (res.statusCode == 401) {
          // Token revoked — stop quietly; the account screen shows state.
          return anyChange;
        }
        if (res.statusCode != 200) {
          // Transport/server trouble: bump attempts and give up this round
          // (same shape as the Trakt outbox's offline path).
          for (final r in outbox) {
            await _repo.db.db.rawUpdate(
                'UPDATE sync_outbox SET attempts=attempts+1 '
                'WHERE ns=? AND k=? AND updated_at=?',
                [r['ns'], r['k'], r['updated_at']]);
          }
          return anyChange;
        }

        final d = res.data is String ? jsonDecode(res.data) : res.data;
        await _setSyncState('epoch', '${d['epoch'] ?? epoch}');

        // Delete pushed outbox rows — ONLY those whose stamp is unchanged
        // (a newer local write may have coalesced in mid-flight; that one
        // stays for the next round).
        for (final r in outbox) {
          await _repo.db.db.delete('sync_outbox',
              where: 'ns=? AND k=? AND updated_at=?',
              whereArgs: [r['ns'], r['k'], r['updated_at']]);
        }

        // Losing ops: apply the inlined current doc — the only path by
        // which this device would otherwise silently keep a losing value.
        final results = (d['results'] as List? ?? const []);
        final losers = [
          for (final r in results)
            if (r['ok'] == false && r['current'] != null)
              SyncDoc.fromJson({...r['current'] as Map<String, dynamic>, 'seq': 0})
        ];
        // Pulled changes (includes this push's own accepted docs — apply is
        // idempotent, our stamps match, so they no-op).
        final changes = [
          for (final c in (d['changes'] as List? ?? const []))
            SyncDoc.fromJson(c as Map<String, dynamic>)
        ];
        final stats = await applyRemoteDocs(_repo, [...losers, ...changes]);
        if (stats.any) anyChange = true;
        if (stats.sources) sourcesChanged = true;

        if (d['full'] == true) {
          // Compaction outran our cursor: walk the snapshot, then adopt the
          // watermark. full_after cursors the keyset pagination.
          more = d['more'] == true;
          if (!more) {
            await _setSyncState('cursor', '${d['full_cursor'] ?? 0}');
          }
          // (keyset continuation rides the next request's body)
          continue;
        }

        await _setSyncState('cursor', '${d['cursor'] ?? 0}');
        await _setSyncState('last_sync_at', '${DateTime.now().millisecondsSinceEpoch}');
        more = d['more'] == true;
      }
      return anyChange;
    } catch (_) {
      return false; // offline — local state is already painted
    } finally {
      _running = false;
    }
  }

  /// First sign-in on a device with existing data: seed the outbox with ALL
  /// local durable state so Merge pushes it up. (Trakt-synthetic rows are
  /// excluded — Trakt already reaches every device on the account.)
  Future<void> seedOutboxFromLocal() async {
    final db = _repo.db.db;
    final batchAt = SyncClock.now();
    // prog — this device's OWN rows only. Trakt-derived marks are excluded
    // for the same reason they never journal: every device on the account
    // shares the Trakt link and re-derives them itself, so pushing them
    // duplicates the fact along a second path with a worse timestamp.
    for (final r in await db.query('episode_progress',
        where: "synthetic=0 AND origin<>'trakt'")) {
      await db.insert(
        'sync_outbox',
        {
          'ns': 'prog',
          'k': r['ep_key'],
          'v': (r['deleted'] as int? ?? 0) != 0
              ? null
              : jsonEncode({
                  'p': r['position_ms'],
                  'd': r['duration_ms'],
                  'w': r['watched'],
                }),
          'deleted': r['deleted'] ?? 0,
          'updated_at': r['updated_at'] ?? batchAt,
          'attempts': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    for (final r in await db.query('favorites_v2')) {
      await db.insert(
        'sync_outbox',
        {
          'ns': 'fav',
          'k': r['fav_key'],
          'v': (r['deleted'] as int? ?? 0) != 0
              ? null
              : jsonEncode({'kind': r['kind'], 'at': r['added_at']}),
          'deleted': r['deleted'] ?? 0,
          'updated_at': r['updated_at'] ?? batchAt,
          'attempts': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    for (final r in await db.query('pinned_v2')) {
      await db.insert(
        'sync_outbox',
        {
          'ns': 'pin',
          'k': '${r['source_key']}|${r['kind']}|${r['name']}',
          'v': (r['deleted'] as int? ?? 0) != 0
              ? null
              : jsonEncode({'position': r['position']}),
          'deleted': r['deleted'] ?? 0,
          'updated_at': r['updated_at'] ?? batchAt,
          'attempts': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    for (final key in kSyncedSettings) {
      final v = await _repo.getSetting(key);
      if (v == null) continue;
      await db.insert(
        'sync_outbox',
        {
          'ns': 'set',
          'k': key,
          'v': jsonEncode({'s': v}),
          'deleted': 0,
          'updated_at': batchAt,
          'attempts': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    for (final pl in await _repo.playlists()) {
      if (isDebridSentinel(pl)) continue;
      await db.insert(
        'sync_outbox',
        {
          'ns': 'src',
          'k': playlistSourceKey(pl),
          'v': jsonEncode({
            'name': pl.name,
            'kind': pl.kind.name,
            'url': pl.url,
            'username': pl.username,
            'password': pl.password,
            'epg_url': pl.epgUrl,
          }),
          'deleted': 0,
          'updated_at': batchAt,
          'attempts': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    final raw = await _repo.getSetting('cw_hidden');
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in map.entries) {
          await db.insert(
            'sync_outbox',
            {
              'ns': 'cwh',
              'k': e.key,
              'v': jsonEncode({'at': e.value}),
              'deleted': 0,
              'updated_at': (e.value as num).toInt(),
              'attempts': 0,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      } catch (_) {}
    }
  }

  /// Sign-in policy "Use the account": archive every synced namespace, then
  /// wipe local so the pull repopulates. The archive is the promise that
  /// "I signed in and it ate my data" can never happen silently.
  Future<void> replaceLocalWithAccount() async {
    final db = _repo.db.db;
    await db.execute(
        'CREATE TABLE IF NOT EXISTS episode_progress_preauth AS '
        'SELECT * FROM episode_progress');
    await db.execute(
        'CREATE TABLE IF NOT EXISTS favorites_v2_preauth AS '
        'SELECT * FROM favorites_v2');
    await db.execute(
        'CREATE TABLE IF NOT EXISTS pinned_v2_preauth AS '
        'SELECT * FROM pinned_v2');
    await db.execute(
        'CREATE TABLE IF NOT EXISTS playlists_preauth AS SELECT * FROM playlists');
    await db.delete('sync_outbox');
    await db.delete('episode_progress');
    await db.delete('favorites_v2');
    await db.delete('pinned_v2');
    await _setSyncState('cursor', '0');
    await pushPull();
  }

  /// Sign-in policy "Upload this device": authoritative replacement. Clears
  /// any pre-auth outbox, seeds from local, pushes with the merge predicate
  /// dropped, tombstones server docs absent locally, bumps the epoch.
  Future<void> uploadThisDevice() async {
    await _repo.db.db.delete('sync_outbox');
    await seedOutboxFromLocal();
    // Pull first (normal) to learn which server keys need tombstoning.
    final base = await _auth.apiBase();
    if (base == null) return;
    await _setSyncState('cursor', '0');
    final serverKeys = <String, Set<String>>{};
    var cursor = 0;
    for (;;) {
      final res = await _dio.post('$base/v1/sync',
          data: jsonEncode({
            'cursor': cursor,
            'epoch': int.tryParse(await _syncState('epoch') ?? '') ?? 0,
            'device_id': await _repo.getSetting('lumen_device_id'),
            'ops': const [],
          }),
          options: Options(headers: {
            'authorization': 'Bearer ${await _auth.token()}',
            'content-type': 'application/json',
          }));
      if (res.statusCode != 200) break;
      final d = res.data is String ? jsonDecode(res.data) : res.data;
      for (final c in (d['changes'] as List? ?? const [])) {
        if ((c['deleted'] as num? ?? 0) == 0) {
          (serverKeys[c['ns'] as String] ??= {}).add(c['k'] as String);
        }
      }
      cursor = (d['cursor'] as num? ?? 0).toInt();
      if (d['more'] != true) break;
    }
    final localKeys = <String>{};
    for (final r in await _repo.db.db.query('sync_outbox')) {
      localKeys.add('${r['ns']}:${r['k']}');
    }
    final now = SyncClock.now();
    serverKeys.forEach((ns, keys) {
      for (final k in keys) {
        if (!localKeys.contains('$ns:$k')) {
          _repo.db.db.insert(
            'sync_outbox',
            {
              'ns': ns, 'k': k, 'v': null, 'deleted': 1,
              'updated_at': now, 'attempts': 0,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
    });
    await pushPull(force: true, forceComplete: true);
  }

  /// True when this device has meaningful local data (drives the sign-in
  /// three-way prompt: silently auto-picking would dent trust).
  Future<bool> hasLocalData() async {
    final db = _repo.db.db;
    final prog = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM episode_progress WHERE synthetic=0');
    final pls = await db.rawQuery('SELECT COUNT(*) AS c FROM playlists');
    return ((prog.first['c'] as int?) ?? 0) > 0 ||
        ((pls.first['c'] as int?) ?? 0) > 0;
  }
}
