import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../shared/title_keys.dart' as tk;
import '../models/models.dart';
import '../sync/merge.dart';
import '../sync/sync_clock.dart';
import '../sync/synced_settings.dart';
import 'sync_origin.dart';

/// Single SQLite database. This is the source of truth — the UI never holds the
/// full channel set in memory; it queries indexed, paginated windows from here.
class AppDatabase {
  AppDatabase._(this.db, this.ftsAvailable);
  final Database db;

  /// Whether the device's SQLite has the FTS5 module. Many Android TV boxes
  /// ship SQLite without it, so we degrade to LIKE search instead of crashing.
  final bool ftsAvailable;

  static AppDatabase? _instance;

  // Set in onConfigure (runs before onCreate) so schema creation can branch.
  static bool _fts = false;

  static Future<bool> _detectFts5(Database db) async {
    try {
      await db.execute(
          'CREATE VIRTUAL TABLE IF NOT EXISTS temp.__fts_probe USING fts5(x)');
      await db.execute('DROP TABLE IF EXISTS temp.__fts_probe');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Tests only: clear the singleton so each test opens a fresh database.
  @visibleForTesting
  static void resetForTest() => _instance = null;

  /// [overridePath] is for tests (sqflite_common_ffi + a temp file); the app
  /// always resolves the platform support directory.
  static Future<AppDatabase> open({String? overridePath}) async {
    if (_instance != null) return _instance!;
    final path = overridePath ??
        p.join((await getApplicationSupportDirectory()).path, 'lumen.db');
    final db = await openDatabase(
      path,
      version: 5,
      // Forward-compat: a future schema version must not brick this binary.
      // With onDowngrade unset, sqflite treats opening a NEWER db as an error,
      // so rolling back an APK after a schema bump would make the app
      // unopenable. No-op is safe: schema changes are additive by policy.
      onDowngrade: (db, from, to) async {},
      onConfigure: (db) async {
        // journal_mode returns a row ("wal"); on sqflite_darwin (iOS/macOS)
        // running it via execute() throws "not an error" — must use rawQuery.
        // synchronous and foreign_keys return nothing, so execute() is fine.
        await db.rawQuery('PRAGMA journal_mode=WAL');
        await db.execute('PRAGMA synchronous=NORMAL');
        await db.execute('PRAGMA foreign_keys=ON');
        _fts = await _detectFts5(db);
      },
      onCreate: (db, v) async {
        await _createSchema(db, v);
        await _createV2(db);
        await _createV3(db);
        await _createV4(db);
        await _createV5(db);
      },
      onUpgrade: (db, from, to) async {
        if (from < 2) await _createV2(db);
        if (from < 3) await _createV3(db);
        if (from < 4) await _createV4(db);
        if (from < 5) await _createV5(db);
      },
    );
    // The v5 backfill runs OUTSIDE onUpgrade, gated on a marker: if it
    // crashes midway the DDL is already in place (re-entrant) and the
    // merge-based fold is idempotent, so the next open simply retries.
    final done = Sqflite.firstIntValue(await db.rawQuery(
        "SELECT COUNT(*) FROM sync_state WHERE key='v5_migrated_at'"));
    if ((done ?? 0) == 0) {
      await _backfillV5(db);
      await db.insert(
          'sync_state',
          {
            'key': 'v5_migrated_at',
            'value': '${DateTime.now().millisecondsSinceEpoch}'
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    return _instance = AppDatabase._(db, _fts);
  }

  static Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE playlists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        kind TEXT NOT NULL,
        url TEXT NOT NULL,
        username TEXT,
        password TEXT,
        epg_url TEXT,
        created_at INTEGER NOT NULL,
        last_synced_at INTEGER,
        stream_count INTEGER NOT NULL DEFAULT 0
      )''');

    await db.execute('''
      CREATE TABLE streams (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        name TEXT NOT NULL,
        logo TEXT,
        url TEXT NOT NULL,
        group_title TEXT,
        tvg_id TEXT,
        num INTEGER,
        rating REAL
      )''');

    // Sharding index: category browsing slices 40k into small per-group windows.
    await db.execute(
        'CREATE INDEX idx_streams_cat ON streams(playlist_id, kind, group_title, num)');
    await db.execute('CREATE INDEX idx_streams_tvg ON streams(tvg_id)');

    // FTS5 over channel names for instant search — only where the device's
    // SQLite actually has the fts5 module (some Android TV boxes don't).
    if (_fts) {
      await db.execute(
          "CREATE VIRTUAL TABLE streams_fts USING fts5(name, tokenize='unicode61')");
    }

    await db.execute('''
      CREATE TABLE favorites (
        stream_id INTEGER PRIMARY KEY REFERENCES streams(id) ON DELETE CASCADE,
        added_at INTEGER NOT NULL
      )''');

    await db.execute('''
      CREATE TABLE progress (
        stream_id INTEGER PRIMARY KEY REFERENCES streams(id) ON DELETE CASCADE,
        position_ms INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL,
        watched INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
      )''');
    await db
        .execute('CREATE INDEX idx_progress_updated ON progress(updated_at)');
  }

  /// v2: key/value settings (home layout, Trakt tokens) + pinned categories.
  static Future<void> _createV2(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY,
        value TEXT
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pinned_categories (
        playlist_id INTEGER NOT NULL,
        kind TEXT NOT NULL,
        name TEXT NOT NULL,
        position INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (playlist_id, kind, name)
      )''');
    // progress index may not exist on installs created before this index line.
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_progress_updated ON progress(updated_at)');
  }

  /// v3: per-episode watch progress. Series episodes are resolved on demand
  /// (no DB stream row) and may play from IPTV or a changing Real-Debrid url,
  /// so we key on the show title + season/episode (see [episodeKey]). Small
  /// table — only episodes the user has actually started.
  static Future<void> _createV3(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS episode_progress (
        ep_key TEXT PRIMARY KEY,
        position_ms INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL,
        watched INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
      )''');
  }

  /// v4: playback memory + reliable Trakt sync.
  /// - `stream_choice`: the exact debrid link last played per title/episode
  ///   (keyed like episode_progress) so a replay starts instantly instead of
  ///   re-scraping.
  /// - `trakt_outbox`: watch events that couldn't reach Trakt (offline,
  ///   expired token) queued for retry — the "if it exists locally it exists
  ///   on Trakt" guarantee.
  /// - `streams_staging`: scratch table for the re-sync so the multi-minute
  ///   bulk insert happens outside the swap transaction and reads interleave.
  static Future<void> _createV4(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS stream_choice (
        choice_key TEXT PRIMARY KEY,
        url TEXT NOT NULL,
        label TEXT,
        quality TEXT,
        updated_at INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS trakt_outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        payload TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS streams_staging (
        playlist_id INTEGER NOT NULL,
        kind TEXT NOT NULL,
        name TEXT NOT NULL,
        logo TEXT,
        url TEXT NOT NULL,
        group_title TEXT,
        tvg_id TEXT,
        num INTEGER,
        rating REAL
      )''');
  }

  /// Re-entrant ALTER: adding a column that already exists (a crashed v5
  /// upgrade being retried) throws — swallow it and move on.
  static Future<void> _addCol(
      Database db, String table, String col, String decl) async {
    try {
      await db.execute('ALTER TABLE $table ADD COLUMN $col $decl');
    } catch (_) {/* already present */}
  }

  /// v5: portable watch state.
  ///
  /// - `episode_progress` becomes the SINGLE source of truth for all watch
  ///   state, keyed on the canonical title key ([tk.titleKey]). Three
  ///   namespaces, mutually exclusive:
  ///     `movie:<tk>`     a film (library-backed OR debrid-only — same key)
  ///     `show:<tk>`      a show-level watched marker (Trakt reconciliation)
  ///     `<tk>|s{n}e{n}`  one episode (episode keys always contain `|`)
  /// - `progress` and `favorites` are demoted to id-keyed PROJECTIONS,
  ///   rebuilt from the key space. Nothing writes them independently, so the
  ///   re-sync swap wiping them via ON DELETE CASCADE is harmless — which is
  ///   what let the url capture/re-map dance inside the swap be deleted. A
  ///   downgraded binary still reads them as real data (dual-purpose).
  /// - `deleted=1` is a TOMBSTONE. The old contract was "row absent means
  ///   unwatched"; that cannot survive sync — a peer that never saw the
  ///   delete would re-push its stale row and resurrect it. Reads filter
  ///   `deleted=0`.
  /// - `synthetic=1` marks Trakt-seeded fraction rows (fake 100000ms
  ///   duration). They are never pushed to the sync server (Trakt already
  ///   reaches every device) and Continue Watching exempts them from the
  ///   60-second floor, which would otherwise drop every seeded resume
  ///   point under 60%.
  static Future<void> _createV5(Database db) async {
    // Widen watch state.
    await _addCol(db, 'episode_progress', 'synthetic',
        'INTEGER NOT NULL DEFAULT 0');
    await _addCol(
        db, 'episode_progress', 'deleted', 'INTEGER NOT NULL DEFAULT 0');
    await _addCol(
        db, 'episode_progress', 'origin', "TEXT NOT NULL DEFAULT 'local'");
    await db.execute('CREATE INDEX IF NOT EXISTS idx_ep_updated '
        'ON episode_progress(updated_at)');

    // Retro-tag Trakt-seeded rows. saveEpisodeProgressFraction is the only
    // writer of duration_ms==100000 with watched==0; a real 100-second clip
    // is a false positive whose only cost is not being pushed to sync.
    await db.execute("UPDATE episode_progress SET synthetic=1, origin='trakt' "
        'WHERE duration_ms=100000 AND watched=0');

    // The join bridge: the portable key, materialised on the library row at
    // ingest (SQLite can't run cleanTitle, and computing it at read time
    // would put six regex passes on the frame path).
    await _addCol(db, 'streams', 'title_key', 'TEXT');
    await _addCol(db, 'streams_staging', 'title_key', 'TEXT');
    await _addCol(db, 'playlists', 'source_key', 'TEXT');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_streams_tkey ON streams(title_key)');

    // The projection needs the synthetic bit too (Continue Watching's floor).
    await _addCol(db, 'progress', 'synthetic', 'INTEGER NOT NULL DEFAULT 0');

    // Portable favorites + pins.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS favorites_v2 (
        fav_key TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        added_at INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pinned_v2 (
        source_key TEXT NOT NULL,
        kind TEXT NOT NULL,
        name TEXT NOT NULL,
        position INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (source_key, kind, name)
      )''');

    // One-release safety net: the only real undo if titleKey has a bad regex.
    await db.execute('CREATE TABLE IF NOT EXISTS progress_v4_backup '
        'AS SELECT * FROM progress');
    await db.execute('CREATE TABLE IF NOT EXISTS favorites_v4_backup '
        'AS SELECT * FROM favorites');

    // Sync plumbing (consumed by the Phase-3 engine; created here so the
    // backfill marker has somewhere to live).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_outbox (
        ns TEXT NOT NULL,
        k TEXT NOT NULL,
        v TEXT,
        deleted INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (ns, k)
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_state (
        key TEXT PRIMARY KEY,
        value TEXT
      )''');

    // The epg table shipped in v1 with readers and NO writer, ever — the
    // now/next UI it fed never rendered a row. Feature honestly removed.
    await db.execute('DROP TABLE IF EXISTS epg');
  }

  /// The v5 data fold. Merge decisions run in Dart through [mergeWatch] — the
  /// same function the sync engine uses — because the platform SQLite on old
  /// TV boxes (3.8–3.19, the same ones lacking FTS5) has no upsert.
  static Future<void> _backfillV5(Database db) async {
    const chunk = 2000;

    // 1. streams.title_key — movies/series only; live has no title identity.
    while (true) {
      final rows = await db.query('streams',
          columns: ['id', 'name'],
          where: "kind IN ('movie','series') AND title_key IS NULL",
          orderBy: 'id',
          limit: chunk);
      if (rows.isEmpty) break;
      final batch = db.batch();
      for (final r in rows) {
        final k = tk.titleKey(r['name'] as String);
        batch.rawUpdate('UPDATE streams SET title_key=? WHERE id=?',
            [k.isEmpty ? '' : k, r['id']]);
      }
      await batch.commit(noResult: true, continueOnError: true);
      if (rows.length < chunk) break;
    }

    // 2. playlists.source_key.
    for (final r in await db.query('playlists')) {
      await db.rawUpdate('UPDATE playlists SET source_key=? WHERE id=?',
          [playlistSourceKey(Playlist.fromRow(r)), r['id']]);
    }

    // 3. Re-key existing episode_progress rows into the canonical alphabet
    //    (the old keys kept punctuation; titleKey is idempotent so unchanged
    //    keys fold onto themselves), then fold id-keyed `progress` in:
    //    movies -> movie:<tk>, series flag rows -> show:<tk>.
    final out = <String, WatchRow>{};
    void fold(WatchRow row) => out[row.key] = mergeWatch(out[row.key], row);

    for (final r in await db.query('episode_progress')) {
      final old = WatchRow.fromDb(r);
      final bar = old.key.lastIndexOf('|');
      final String newKey;
      if (old.key.startsWith('movie:')) {
        newKey = tk.movieKey(old.key.substring(6));
      } else if (old.key.startsWith('show:')) {
        newKey = tk.showKey(old.key.substring(5));
      } else if (bar > 0) {
        newKey = '${tk.titleKey(old.key.substring(0, bar))}'
            '${old.key.substring(bar)}';
      } else {
        newKey = old.key;
      }
      fold(WatchRow(
        key: newKey,
        positionMs: old.positionMs,
        durationMs: old.durationMs,
        watched: old.watched,
        updatedAt: old.updatedAt,
        deleted: old.deleted,
        synthetic: old.synthetic,
        origin: old.origin,
      ));
    }
    final legacy = await db.rawQuery(
        'SELECT s.kind AS kind, s.title_key AS tk2, p.position_ms, '
        'p.duration_ms, p.watched, p.updated_at FROM progress p '
        'JOIN streams s ON s.id=p.stream_id '
        "WHERE s.title_key IS NOT NULL AND s.title_key<>''");
    for (final r in legacy) {
      final key = r['kind'] == 'series'
          ? 'show:${r['tk2']}'
          : 'movie:${r['tk2']}';
      fold(WatchRow(
        key: key,
        positionMs: (r['position_ms'] as int?) ?? 0,
        durationMs: (r['duration_ms'] as int?) ?? 0,
        watched: (r['watched'] as int? ?? 0) == 1,
        updatedAt: (r['updated_at'] as int?) ?? 0,
      ));
    }
    await db.transaction((txn) async {
      await txn.delete('episode_progress');
      final b = txn.batch();
      for (final row in out.values) {
        b.insert('episode_progress', row.toDb(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await b.commit(noResult: true, continueOnError: true);
    });

    // 4. favorites -> favorites_v2. Oldest added_at wins a collision ("I
    //    favorited this in 2024" is the truer fact).
    final favs = await db.rawQuery(
        'SELECT s.kind, s.name, s.url, s.tvg_id, s.title_key AS tk2, '
        'f.added_at FROM favorites f JOIN streams s ON s.id=f.stream_id');
    final favOut = <String, ({String kind, int addedAt})>{};
    for (final r in favs) {
      final kind = r['kind'] as String;
      final String key;
      if (kind == 'live') {
        key = tk.liveFavKeyFor(
            tvgId: r['tvg_id'] as String?, url: r['url'] as String);
      } else if ((r['tk2'] as String?)?.isNotEmpty == true) {
        key = kind == 'series' ? 'show:${r['tk2']}' : 'movie:${r['tk2']}';
      } else {
        continue;
      }
      final added = (r['added_at'] as int?) ?? 0;
      final have = favOut[key];
      if (have == null || added < have.addedAt) {
        favOut[key] = (kind: kind, addedAt: added);
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final e in favOut.entries) {
      await db.insert(
          'favorites_v2',
          {
            'fav_key': e.key,
            'kind': e.value.kind,
            'added_at': e.value.addedAt,
            'deleted': 0,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    // 5. pinned_categories -> pinned_v2, keyed by the portable source key.
    await db.execute(
        'INSERT OR IGNORE INTO pinned_v2'
        '(source_key,kind,name,position,deleted,updated_at) '
        'SELECT pl.source_key, pc.kind, pc.name, pc.position, 0, ? '
        'FROM pinned_categories pc JOIN playlists pl ON pl.id=pc.playlist_id '
        'WHERE pl.source_key IS NOT NULL',
        [now]);

    // 6. Re-key the cw_hidden dismissals blob. The old alphabet was
    //    alnum-only (TitleIndex.normalize) — spaces are unrecoverable, so map
    //    keys back through the library (alnum(title_key) == old key body) and
    //    drop the rest: a lost dismissal just resurfaces a card.
    final rawHidden = await db.query('app_settings',
        where: "key='cw_hidden'", limit: 1);
    if (rawHidden.isNotEmpty) {
      try {
        final blob = rawHidden.first['value'] as String?;
        if (blob != null && blob.isNotEmpty) {
          final Map<String, Object?> old0 =
              (jsonDecode(blob) as Map).cast<String, Object?>();
          final alnum = RegExp('[^a-z0-9]');
          final byAlnum = <String, String>{};
          for (final r in await db.query('streams',
              columns: ['title_key'],
              where: "title_key IS NOT NULL AND title_key<>''",
              distinct: true)) {
            final tk2 = r['title_key'] as String;
            byAlnum[tk2.replaceAll(alnum, '')] = tk2;
          }
          final rekeyed = <String, Object?>{};
          old0.forEach((k, v) {
            final isShow = k.startsWith('show:');
            final isMovie = k.startsWith('movie:');
            if (!isShow && !isMovie) return;
            final body = isShow ? k.substring(5) : k.substring(6);
            final mapped =
                byAlnum[body.replaceAll(alnum, '')] ?? tk.titleKey(body);
            if (mapped.isEmpty) return;
            rekeyed['${isShow ? 'show' : 'movie'}:$mapped'] = v;
          });
          await db.insert(
              'app_settings',
              {'key': 'cw_hidden', 'value': jsonEncode(rekeyed)},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      } catch (_) {/* corrupt blob — dismissals reset, cards resurface */}
    }

    // 6b. Re-key the remembered debrid links (same key space as watch state).
    for (final r in await db.query('stream_choice')) {
      final old = r['choice_key'] as String;
      final bar = old.lastIndexOf('|');
      final String newKey;
      if (old.startsWith('movie:')) {
        newKey = tk.movieKey(old.substring(6));
      } else if (bar > 0) {
        newKey = '${tk.titleKey(old.substring(0, bar))}${old.substring(bar)}';
      } else {
        continue;
      }
      if (newKey != old) {
        await db.rawUpdate(
            'UPDATE OR IGNORE stream_choice SET choice_key=? WHERE choice_key=?',
            [newKey, old]);
      }
    }

    // 7. Build the projections.
    await _rebuildProjections(db);
  }

  /// Rebuild the id-keyed projections (`progress`, `favorites`) from the
  /// portable key space. Called after the v5 fold and inside every library
  /// swap — which is why the swap no longer needs the url capture/re-map.
  /// Live rows in `progress` are direct writes (live never syncs and has no
  /// title identity), so only the VOD slice is dropped and rebuilt.
  static Future<void> _rebuildProjections(DatabaseExecutor db) async {
    await db.execute('DELETE FROM progress WHERE stream_id IN '
        "(SELECT id FROM streams WHERE kind IN ('movie','series'))");
    await db.execute(
        'INSERT OR REPLACE INTO progress'
        '(stream_id,position_ms,duration_ms,watched,synthetic,updated_at) '
        'SELECT s.id, w.position_ms, w.duration_ms, w.watched, w.synthetic, '
        'w.updated_at FROM streams s JOIN episode_progress w ON w.ep_key='
        "(CASE s.kind WHEN 'series' THEN 'show:' ELSE 'movie:' END)"
        '||s.title_key '
        "WHERE s.kind IN ('movie','series') AND s.title_key IS NOT NULL "
        "AND s.title_key<>'' AND w.deleted=0");
    // Episode rows deliberately do NOT project onto the series poster row:
    // an in-progress episode must never clear a show-level watched mark (the
    // Trakt reconciliation would re-add it hourly — an oscillation), and in
    // the pre-v5 world episode activity never touched the id-keyed row
    // either. Show cards in Continue Watching come from the episode keys
    // directly (providers.dart synthesis), not from this projection.

    await db.execute('DELETE FROM favorites WHERE stream_id IN '
        "(SELECT id FROM streams WHERE kind IN ('movie','series'))");
    await db.execute(
        'INSERT OR IGNORE INTO favorites(stream_id, added_at) '
        'SELECT s.id, f.added_at FROM favorites_v2 f JOIN streams s '
        "ON f.fav_key=(CASE s.kind WHEN 'series' THEN 'show:' ELSE 'movie:' "
        "END)||s.title_key "
        "WHERE f.deleted=0 AND s.kind IN ('movie','series') "
        "AND s.title_key IS NOT NULL AND s.title_key<>''");

    // Live favorites: the key shapes need Dart (regex on the url), but the
    // set is tiny — dozens, not thousands.
    final liveFavs = await db.query('favorites_v2',
        where: "kind='live' AND deleted=0");
    await db.execute('DELETE FROM favorites WHERE stream_id IN '
        "(SELECT id FROM streams WHERE kind='live')");
    for (final f in liveFavs) {
      final key = f['fav_key'] as String;
      final added = f['added_at'];
      if (key.startsWith('live:tvg:')) {
        await db.execute(
            'INSERT OR IGNORE INTO favorites(stream_id, added_at) '
            "SELECT id, ? FROM streams WHERE kind='live' AND tvg_id=?",
            [added, key.substring(9)]);
      } else if (key.startsWith('live:xt:')) {
        await db.execute(
            'INSERT OR IGNORE INTO favorites(stream_id, added_at) '
            "SELECT id, ? FROM streams WHERE kind='live' AND url LIKE ?",
            [added, '%/${key.substring(8)}.%']);
      } else if (key.startsWith('live:url:')) {
        await db.execute(
            'INSERT OR IGNORE INTO favorites(stream_id, added_at) '
            "SELECT id, ? FROM streams WHERE kind='live' AND url=?",
            [added, key.substring(9)]);
      }
    }
  }

  /// Refresh the `progress` projection rows for ONE portable key after a
  /// write — a targeted indexed statement instead of a full rebuild.
  Future<void> _projectProgressKey(String key) async {
    // Episode keys never project (see _rebuildProjections for why).
    if (key.contains('|')) return;
    final isShow = key.startsWith('show:');
    final tkey = isShow ? key.substring(5) : key.substring(6);
    final kind = isShow ? 'series' : 'movie';
    final rows = await db.query('episode_progress',
        where: 'ep_key=? AND deleted=0', whereArgs: [key], limit: 1);
    if (rows.isEmpty) {
      await db.execute(
          'DELETE FROM progress WHERE stream_id IN '
          '(SELECT id FROM streams WHERE kind=? AND title_key=?)',
          [kind, tkey]);
      return;
    }
    await db.execute(
        'INSERT OR REPLACE INTO progress'
        '(stream_id,position_ms,duration_ms,watched,synthetic,updated_at) '
        'SELECT s.id, w.position_ms, w.duration_ms, w.watched, w.synthetic, '
        'w.updated_at FROM streams s JOIN episode_progress w ON w.ep_key=? '
        'WHERE s.kind=? AND s.title_key=?',
        [key, kind, tkey]);
  }

  /// Bounded caches: the per-title tmdb:/omdb: families are permanent and
  /// grew without limit, and home-row snapshots for deleted playlists were
  /// orphaned forever. Called from the shell's post-boot slot — cheap when
  /// there's nothing to do.
  Future<void> pruneOrphanCaches() async {
    final ids = (await db.query('playlists', columns: ['id']))
        .map((r) => '${r['id']}')
        .toSet();
    final snaps = await db.query('app_settings',
        columns: ['key'], where: "key LIKE 'home:snap:%'");
    for (final r in snaps) {
      final key = r['key'] as String;
      final parts = key.split(':');
      if (parts.length >= 3 && !ids.contains(parts[2])) {
        await db.delete('app_settings', where: 'key=?', whereArgs: [key]);
      }
    }
    // The per-title rows carry no timestamp, so there's no LRU to run —
    // above a generous cap the whole family is dropped and rebuilds lazily
    // on demand (each read re-caches).
    final n = Sqflite.firstIntValue(await db.rawQuery(
            "SELECT COUNT(*) FROM app_settings WHERE key LIKE 'tmdb:%' "
            "OR key LIKE 'omdb:%'")) ??
        0;
    if (n > 6000) {
      await deleteSettingsPrefix('tmdb:');
      await deleteSettingsPrefix('omdb:');
    }
  }

  /// Remote-apply entry points (lib/data/sync/apply.dart) — the projections
  /// must refresh after a pulled write exactly as after a local one.
  Future<void> projectProgressKeyRemote(String key) => _projectProgressKey(key);
  Future<void> projectFavoriteKeyRemote(
          String key, StreamKind kind, int? addedAt) =>
      _projectFavoriteKey(key, kind, addedAt);

  /// Dismiss one Continue Watching entry: updates the local cw_hidden blob
  /// AND journals a per-key `cwh` doc — the blob itself must never sync
  /// (blob-level LWW would silently drop other devices' dismissals).
  Future<void> dismissCw(String key, int at,
      {SyncOrigin origin = SyncOrigin.local}) async {
    await db.transaction((txn) async {
      Map<String, dynamic> map;
      final rows = await txn.query('app_settings',
          where: "key='cw_hidden'", limit: 1);
      try {
        final raw = rows.isEmpty ? null : rows.first['value'] as String?;
        map = raw == null || raw.isEmpty
            ? {}
            : jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        map = {};
      }
      map[key] = at;
      await txn.insert('app_settings',
          {'key': 'cw_hidden', 'value': jsonEncode(map)},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await _journal(txn, origin, 'cwh', key, {'at': at}, updatedAt: at);
    });
    _notifyOutbox();
  }

  // ---- Sync journal --------------------------------------------------------

  /// Fired (post-commit, debounced by the listener) whenever a local write
  /// lands in `sync_outbox`. The sync engine installs itself here — same
  /// pattern as CredentialVault's onSettingChanged.
  static void Function()? onOutboxChanged;

  /// Journal one op into the outbox, inside the caller's transaction. The
  /// PRIMARY KEY (ns,k) deliberately COALESCES — progress checkpoints fire
  /// every 5 seconds, and an append-only outbox would accrue ~720 rows per
  /// film; last-local-write-wins per key IS the LWW semantics anyway.
  Future<void> _journal(DatabaseExecutor txn, SyncOrigin origin, String ns,
      String k, Map<String, Object?>? v,
      {bool deleted = false, int? updatedAt}) async {
    if (!origin.journals) return;
    if (ns == 'set' && !isSyncedSettingKey(k)) return; // before any encoding
    await txn.insert(
      'sync_outbox',
      {
        'ns': ns,
        'k': k,
        'v': v == null ? null : jsonEncode(v),
        'deleted': deleted ? 1 : 0,
        'updated_at': updatedAt ?? SyncClock.now(),
        'attempts': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // Progress deliberately does NOT wake the 3-second auto-push: the player
    // checkpoints every 5s, so it would fire between checkpoints and turn a
    // two-hour film into a request every few seconds. Progress rides the
    // push at player close, plus app open / resume / pause. Everything else
    // (favorites, pins, settings, sources) is a discrete user action and
    // should reach the account promptly.
    if (ns != 'prog') _outboxDirty = true;
  }

  bool _outboxDirty = false;

  /// Call after the enclosing write completes to notify the sync engine.
  void _notifyOutbox() {
    if (_outboxDirty) {
      _outboxDirty = false;
      onOutboxChanged?.call();
    }
  }

  // ---- Remembered stream choice (last-played link per title) ---------------

  Future<({String url, String? label, String? quality, int updatedAt})?>
      getStreamChoice(String key) async {
    final rows = await db.query('stream_choice',
        where: 'choice_key=?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return (
      url: r['url'] as String,
      label: r['label'] as String?,
      quality: r['quality'] as String?,
      updatedAt: (r['updated_at'] as int?) ?? 0,
    );
  }

  Future<void> saveStreamChoice(String key, String url,
      {String? label, String? quality}) async {
    await db.insert(
      'stream_choice',
      {
        'choice_key': key,
        'url': url,
        'label': label,
        'quality': quality,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Forget a remembered link (it stopped working — the next play re-resolves).
  Future<void> deleteStreamChoice(String key) =>
      db.delete('stream_choice', where: 'choice_key=?', whereArgs: [key]);

  // ---- Trakt outbox (queued writes) ----------------------------------------

  Future<void> outboxAdd(String payload) async {
    await db.insert('trakt_outbox', {
      'payload': payload,
      'attempts': 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<({int id, String payload, int attempts})>> outboxAll(
      {int limit = 50}) async {
    final rows =
        await db.query('trakt_outbox', orderBy: 'id', limit: limit);
    return [
      for (final r in rows)
        (
          id: r['id'] as int,
          payload: r['payload'] as String,
          attempts: (r['attempts'] as int?) ?? 0,
        ),
    ];
  }

  Future<void> outboxDelete(int id) =>
      db.delete('trakt_outbox', where: 'id=?', whereArgs: [id]);

  Future<void> outboxBumpAttempts(int id) => db.rawUpdate(
      'UPDATE trakt_outbox SET attempts=attempts+1 WHERE id=?', [id]);

  // ---- Episode progress ----------------------------------------------------

  /// Watched threshold. Matches Trakt's scrobble convention (a stop at >=80%
  /// records a watched play) so the local check and Trakt's never disagree —
  /// a mismatched 90% local bar left an 85% session "in progress" here but
  /// "watched" on Trakt for up to an hour.
  static const watchedThreshold = 0.8;

  Future<void> saveEpisodeProgress(String key, int posMs, int durMs,
      {SyncOrigin origin = SyncOrigin.local}) async {
    final watched = durMs > 0 && posMs / durMs >= watchedThreshold ? 1 : 0;
    final at = SyncClock.now();
    await db.transaction((txn) async {
      await txn.insert(
        'episode_progress',
        {
          'ep_key': key,
          'position_ms': posMs,
          'duration_ms': durMs,
          'watched': watched,
          'updated_at': at,
          // A real checkpoint overrides a tombstone (the user is watching it
          // again) and clears any synthetic Trakt seed.
          'deleted': 0,
          'synthetic': 0,
          'origin': origin.name,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      // The stamp is CHECKPOINT time (not send time): a device offline for
      // two hours pushes an old stamp and correctly loses to a newer
      // completion elsewhere.
      await _journal(txn, origin, 'prog', key,
          {'p': posMs, 'd': durMs, 'w': watched},
          updatedAt: at);
    });
    await _projectProgressKey(key);
    _notifyOutbox();
  }

  /// Seed an episode's progress from a known fraction (a Trakt cross-device
  /// resume point) rather than a real position/duration. The player resumes by
  /// fraction (dur * frac), so a synthetic position/duration whose ratio is the
  /// fraction restores the right spot; the first local checkpoint then overwrites
  /// it with the true position. [updatedAt] carries Trakt's `paused_at` so this
  /// orders correctly against local activity in Continue Watching (0 → now).
  Future<void> saveEpisodeProgressFraction(String key, double fraction,
      {int updatedAt = 0}) async {
    final frac = fraction.clamp(0.0, 1.0);
    final at =
        updatedAt > 0 ? updatedAt : DateTime.now().millisecondsSinceEpoch;
    // Respect a fresher tombstone: an explicit local un-watch must not be
    // resurrected by a Trakt resume point that predates it.
    final have = await db.query('episode_progress',
        columns: ['deleted', 'updated_at'],
        where: 'ep_key=?',
        whereArgs: [key],
        limit: 1);
    if (have.isNotEmpty &&
        (have.first['deleted'] as int? ?? 0) == 1 &&
        ((have.first['updated_at'] as int?) ?? 0) >= at) {
      return;
    }
    await db.insert(
      'episode_progress',
      {
        'ep_key': key,
        'position_ms': (frac * 100000).round(),
        'duration_ms': 100000,
        // Never watched=1: these are Trakt PAUSED checkpoints — items sit in
        // /sync/playback precisely because Trakt did NOT count them watched.
        // Flagging high fractions here marked cross-device "quit near the
        // end" sessions as seen locally, and the flag was sticky (hydrate
        // skips already-watched rows, so no fresher checkpoint could fix it).
        'watched': 0,
        'updated_at': at,
        'deleted': 0,
        // Trakt-derived: never pushed to the sync server (Trakt already
        // reaches every device), and exempt from Continue Watching's
        // 60-second floor (the 100000ms denominator is fake).
        'synthetic': 1,
        'origin': 'trakt',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _projectProgressKey(key);
  }

  /// Explicitly set the watched flag for a batch of episode keys (the "mark
  /// season watched" toggle). Watched rows are stored flag-only (0/0 pos/dur);
  /// un-watching writes a TOMBSTONE (deleted=1) rather than removing the row —
  /// "absent means unwatched" cannot survive sync, where a peer that never
  /// saw the delete would re-push its stale row and resurrect it. One
  /// transaction for the whole season.
  Future<void> setEpisodesWatched(Iterable<String> keys, bool watched,
      {SyncOrigin origin = SyncOrigin.local}) async {
    final list = keys.toList();
    if (list.isEmpty) return;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final key in list) {
        batch.insert(
          'episode_progress',
          {
            'ep_key': key,
            'position_ms': 0,
            'duration_ms': 0,
            'watched': watched ? 1 : 0,
            'updated_at': SyncClock.now(),
            'deleted': watched ? 0 : 1,
            'synthetic': 0,
            'origin': origin.name,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true, continueOnError: true);
      for (final key in list) {
        await _journal(txn, origin, 'prog', key,
            watched ? {'p': 0, 'd': 0, 'w': 1} : null,
            deleted: !watched);
      }
    });
    for (final key in list) {
      await _projectProgressKey(key);
    }
    _notifyOutbox();
  }

  /// Seed Trakt's WATCHED episode history into the local table.
  ///
  /// Trakt's per-show progress used to render only as green checks on the
  /// series screen, while Continue Watching, resume and next-episode read
  /// the local table — so an episode finished on another device showed a
  /// check but was still offered as "up next". These are the same fact and
  /// must live in one place.
  ///
  /// Flag-only rows (0/0), `origin: trakt` so they never enter the sync
  /// outbox — every device on the account shares the Trakt link and derives
  /// them itself. Returns true when anything changed.
  ///
  /// Two things are deliberately NOT overwritten:
  ///  - a tombstone: an explicit local un-watch outranks Trakt until the
  ///    user actually rewatches, otherwise the next fetch resurrects it;
  ///  - a row already watched: nothing to do, and rewriting it would churn
  ///    updated_at and reshuffle Continue Watching's ordering.
  Future<bool> markEpisodesWatchedFromTrakt(Iterable<String> keys) async {
    final list = keys.toList();
    if (list.isEmpty) return false;
    final existing = <String, ({bool watched, bool deleted})>{};
    for (final r in await db.query('episode_progress',
        columns: ['ep_key', 'watched', 'deleted'])) {
      existing[r['ep_key'] as String] = (
        watched: (r['watched'] as int? ?? 0) == 1,
        deleted: (r['deleted'] as int? ?? 0) == 1,
      );
    }
    final todo = [
      for (final k in list)
        if (!(existing[k]?.watched ?? false) && !(existing[k]?.deleted ?? false))
          k
    ];
    if (todo.isEmpty) return false;
    final now = SyncClock.now();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final k in todo) {
        batch.insert(
          'episode_progress',
          {
            'ep_key': k,
            'position_ms': 0,
            'duration_ms': 0,
            'watched': 1,
            'updated_at': now,
            'deleted': 0,
            'synthetic': 0,
            'origin': SyncOrigin.trakt.name,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true, continueOnError: true);
    });
    return true;
  }

  /// ep_key → (completed fraction 0..1, watched, last-touched ms) for every
  /// episode the user has started. Drives the series screen's seen marks,
  /// resume overlays and "jump to next episode".
  Future<Map<String, ({double fraction, bool watched, int updatedAt})>>
      episodeProgressAll() async {
    final rows = await db.query('episode_progress', where: 'deleted=0');
    final out = <String, ({double fraction, bool watched, int updatedAt})>{};
    for (final r in rows) {
      final pos = (r['position_ms'] as num?)?.toDouble() ?? 0;
      final dur = (r['duration_ms'] as num?)?.toDouble() ?? 0;
      out[r['ep_key'] as String] = (
        fraction: dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0,
        watched: (r['watched'] as int? ?? 0) == 1,
        updatedAt: (r['updated_at'] as int?) ?? 0,
      );
    }
    return out;
  }

  // ---- Settings (key/value) ------------------------------------------------

  Future<String?> getSetting(String key) async {
    final rows = await db.query('app_settings',
        where: 'key=?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String? value,
      {SyncOrigin origin = SyncOrigin.local}) async {
    // The allowlist check inside _journal keeps cache/snapshot writes cheap —
    // only the ~15 kSyncedSettings keys ever reach the outbox.
    if (value == null) {
      await db.transaction((txn) async {
        await txn.delete('app_settings', where: 'key=?', whereArgs: [key]);
        await _journal(txn, origin, 'set', key, null, deleted: true);
      });
    } else {
      await db.transaction((txn) async {
        await txn.insert('app_settings', {'key': key, 'value': value},
            conflictAlgorithm: ConflictAlgorithm.replace);
        await _journal(txn, origin, 'set', key, {'s': value});
      });
    }
    _notifyOutbox();
  }

  /// Drop every setting whose key starts with [prefix] — used to invalidate a
  /// whole family of caches (e.g. all `trakt:*` snapshots on disconnect).
  Future<void> deleteSettingsPrefix(String prefix) =>
      db.delete('app_settings', where: 'key LIKE ?', whereArgs: ['$prefix%']);

  // ---- Pinned categories ---------------------------------------------------

  /// Pins live in `pinned_v2`, keyed by the portable source key so they
  /// survive re-sync and travel between devices. The legacy id-keyed
  /// `pinned_categories` is dual-written for one release so a downgraded
  /// binary still reads real data.
  Future<List<String>> pinnedCategories(
      Playlist playlist, StreamKind kind) async {
    final rows = await db.query(
      'pinned_v2',
      columns: ['name'],
      where: 'source_key=? AND kind=? AND deleted=0',
      whereArgs: [playlistSourceKey(playlist), kind.name],
      orderBy: 'position, name',
    );
    return rows.map((r) => r['name'] as String).toList();
  }

  Future<void> setPinned(
      Playlist playlist, StreamKind kind, String name, bool pinned,
      {SyncOrigin origin = SyncOrigin.local}) async {
    final now = SyncClock.now();
    final sourceKey = playlistSourceKey(playlist);
    await db.transaction((txn) async {
      await txn.insert(
        'pinned_v2',
        {
          'source_key': sourceKey,
          'kind': kind.name,
          'name': name,
          'position': now ~/ 1000,
          'deleted': pinned ? 0 : 1,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _journal(txn, origin, 'pin', '$sourceKey|${kind.name}|$name',
          pinned ? {'position': now ~/ 1000} : null,
          deleted: !pinned, updatedAt: now);
    });
    _notifyOutbox();
    // Legacy dual-write (drop with the v4 tables).
    final plId = playlist.id;
    if (plId == null) return;
    if (pinned) {
      await db.insert(
        'pinned_categories',
        {
          'playlist_id': plId,
          'kind': kind.name,
          'name': name,
          'position': now ~/ 1000,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } else {
      await db.delete('pinned_categories',
          where: 'playlist_id=? AND kind=? AND name=?',
          whereArgs: [plId, kind.name, name]);
    }
  }

  // ---- Home feed rows ------------------------------------------------------

  /// Providers carry the same film in several languages/qualities, and since
  /// v5 the STATE deliberately spans them all (favoriting "EN - Dune" stars
  /// "FR - Dune" and "Dune 4K" too, and they share one progress row). The
  /// LISTS must still show one card per title, so collapse variants here —
  /// preferring the English-labelled row, matching how playback picks a match.
  ///
  /// Live rows have no title identity (cleanTitle strips the quality tags
  /// that separate regional feeds), so they collapse on url instead, i.e.
  /// not at all in practice.
  static final _enLabel =
      RegExp(r'^\s*(en|eng|english)\b', caseSensitive: false);

  static List<StreamItem> _oneCardPerTitle(
      List<Map<String, Object?>> rows, int limit) {
    final best = <String, Map<String, Object?>>{};
    final order = <String>[];
    for (final r in rows) {
      final tkey = (r['title_key'] as String?) ?? '';
      final key = tkey.isEmpty
          ? 'url:${r['url']}'
          : '${r['kind']}:$tkey';
      final have = best[key];
      if (have == null) {
        best[key] = r;
        order.add(key);
      } else if (!_enLabel.hasMatch('${have['name']}') &&
          _enLabel.hasMatch('${r['name']}')) {
        best[key] = r; // upgrade to the English variant, keep row order
      }
      if (order.length >= limit && best.length >= limit) break;
    }
    return [
      for (final k in order.take(limit)) StreamItem.fromRow(best[k]!),
    ];
  }


  /// In-progress VOD (started but not finished), most recent first.
  Future<List<StreamItem>> continueWatching(int playlistId,
      {int limit = 20}) async {
    final rows = await db.rawQuery(
      'SELECT s.* FROM progress pr JOIN streams s ON s.id=pr.stream_id '
      'WHERE s.playlist_id=? AND pr.watched=0 '
      // Synthetic Trakt seeds carry a fake 100000ms denominator, so the
      // 60-second floor would drop every seeded resume point under 60%.
      'AND (pr.position_ms>60000 OR pr.synthetic=1) '
      // Over-fetch: variants of one title collapse below, so the caller's
      // limit must apply to CARDS, not to rows.
      'ORDER BY pr.updated_at DESC LIMIT ?',
      [playlistId, limit * 4],
    );
    return _oneCardPerTitle(rows, limit);
  }

  /// Anything touched recently (watched or not).
  Future<List<StreamItem>> recentlyWatched(int playlistId,
      {int limit = 20}) async {
    final rows = await db.rawQuery(
      'SELECT s.* FROM progress pr JOIN streams s ON s.id=pr.stream_id '
      'WHERE s.playlist_id=? ORDER BY pr.updated_at DESC LIMIT ?',
      [playlistId, limit * 4],
    );
    return _oneCardPerTitle(rows, limit);
  }

  /// Featured picks for the hero banner — items that have artwork, sampled
  /// pseudo-randomly but cheaply (no full-table sort).
  Future<List<StreamItem>> featured(int playlistId, {int limit = 8}) async {
    final rows = await db.rawQuery(
      "SELECT * FROM streams WHERE playlist_id=? AND kind IN ('movie','series') "
      "AND logo IS NOT NULL AND logo!='' "
      'ORDER BY (id * 2654435761) % 100000 LIMIT ?',
      [playlistId, limit],
    );
    return rows.map(StreamItem.fromRow).toList();
  }

  /// A preview strip for a category (first N items) for home rows.
  Future<List<StreamItem>> categoryPreview({
    required int playlistId,
    required StreamKind kind,
    required String groupTitle,
    int limit = 20,
  }) async {
    final rows = await db.query(
      'streams',
      where: 'playlist_id=? AND kind=? AND group_title=?',
      whereArgs: [playlistId, kind.name, groupTitle],
      orderBy: 'num IS NULL, num, name COLLATE NOCASE',
      limit: limit,
    );
    return rows.map(StreamItem.fromRow).toList();
  }

  // ---- Playlists -----------------------------------------------------------

  Future<int> insertPlaylist(Playlist pl,
      {SyncOrigin origin = SyncOrigin.local}) async {
    final sourceKey = playlistSourceKey(pl);
    late int id;
    await db.transaction((txn) async {
      id = await txn.insert(
          'playlists',
          pl.toRow()
            ..remove('id')
            ..['source_key'] = sourceKey);
      await _journal(txn, origin, 'src', sourceKey, {
        'name': pl.name,
        'kind': pl.kind.name,
        'url': pl.url,
        'username': pl.username,
        'password': pl.password,
        'epg_url': pl.epgUrl,
      });
    });
    _notifyOutbox();
    return id;
  }

  Future<List<Playlist>> playlists() async {
    final rows = await db.query('playlists', orderBy: 'created_at DESC');
    return rows.map(Playlist.fromRow).toList();
  }

  Future<void> deletePlaylist(int id,
      {SyncOrigin origin = SyncOrigin.local}) async {
    // Retire the source's pins in the portable table (tombstones, so the
    // delete can sync); the legacy CASCADE handles the id-keyed leftovers.
    final pl = await db.query('playlists',
        where: 'id=?', whereArgs: [id], limit: 1);
    if (pl.isNotEmpty) {
      await db.update(
          'pinned_v2',
          {
            'deleted': 1,
            'updated_at': DateTime.now().millisecondsSinceEpoch
          },
          where: 'source_key=?',
          whereArgs: [playlistSourceKey(Playlist.fromRow(pl.first))]);
      await db.delete('pinned_categories',
          where: 'playlist_id=?', whereArgs: [id]);
    }
    if (pl.isNotEmpty) {
      await _journal(db, origin, 'src',
          playlistSourceKey(Playlist.fromRow(pl.first)), null,
          deleted: true);
      _notifyOutbox();
    }
    await db.delete('playlists', where: 'id=?', whereArgs: [id]);
    if (ftsAvailable) {
      await db.execute(
          'DELETE FROM streams_fts WHERE rowid IN (SELECT id FROM streams WHERE playlist_id=?)',
          [id]);
    }
    await db.delete('streams', where: 'playlist_id=?', whereArgs: [id]);
  }

  Future<void> markSynced(int playlistId, int count) async {
    await db.update(
      'playlists',
      {
        'last_synced_at': DateTime.now().millisecondsSinceEpoch,
        'stream_count': count
      },
      where: 'id=?',
      whereArgs: [playlistId],
    );
  }

  // ---- Bulk ingest ---------------------------------------------------------

  /// Replace all streams for a playlist.
  ///
  /// Two phases, because sqflite serializes every query through ONE connection:
  /// a single giant transaction (the old approach) held that connection for the
  /// whole multi-minute ingest, so every read — home rows, browsing, metadata
  /// caches — queued behind it and the app felt frozen while a sync ran.
  ///
  /// 1. **Stage**: rows land in `streams_staging` in small batched
  ///    transactions. Between batches the connection is released, so UI reads
  ///    interleave freely; browsing keeps working off the old library.
  /// 2. **Swap**: one SHORT transaction moves staging → streams entirely in
  ///    SQL (no Dart marshalling), rebuilds FTS, and re-maps favorites +
  ///    progress onto the new ids by their stable urls. Readers see the old
  ///    library until the commit, then the new one — never a half state.
  /// Serializes [replaceStreams] runs. Staging now spans many independent
  /// commits, so two overlapping replaces (weekly auto-resync + a manual
  /// re-sync, or two sources) would interleave their staging writes — worst
  /// case one swap finds an empty staging table and wipes the library along
  /// with the favorites/progress being remapped. One at a time, always.
  static Future<void>? _replaceLock;

  Future<int> replaceStreams(
    int playlistId,
    Iterable<StreamItem> items, {
    void Function(int written)? onProgress,
    int batchSize = 800,
  }) async {
    while (_replaceLock != null) {
      await _replaceLock;
    }
    final lock = Completer<void>();
    _replaceLock = lock.future;
    try {
      return await _replaceStreamsLocked(playlistId, items,
          onProgress: onProgress, batchSize: batchSize);
    } finally {
      _replaceLock = null;
      lock.complete();
    }
  }

  Future<int> _replaceStreamsLocked(
    int playlistId,
    Iterable<StreamItem> items, {
    void Function(int written)? onProgress,
    int batchSize = 800,
  }) async {
    // Phase 1: stage. Each batch is its own transaction — the gaps between
    // them are where queued reads get to run. Scoped to THIS playlist so
    // leftovers from a crashed run are cleared without touching anything else.
    await db.delete('streams_staging',
        where: 'playlist_id=?', whereArgs: [playlistId]);
    int written = 0;
    final iter = items.iterator;
    var done = false;
    while (!done) {
      final batch = db.batch();
      int n = 0;
      while (n < batchSize) {
        if (!iter.moveNext()) {
          done = true;
          break;
        }
        final it = iter.current;
        batch.rawInsert(
          'INSERT INTO streams_staging(playlist_id,kind,name,logo,url,group_title,tvg_id,num,rating,title_key) '
          'VALUES(?,?,?,?,?,?,?,?,?,?)',
          [
            playlistId,
            it.kind.name,
            it.name,
            it.logo,
            it.url,
            it.groupTitle,
            it.tvgId,
            it.num,
            it.rating,
            // The portable key, materialised at ingest — live channels have
            // no title identity (cleanTitle strips the quality tags that
            // separate regional feeds).
            it.kind == StreamKind.live ? null : tk.titleKey(it.name),
          ],
        );
        n++;
      }
      if (n == 0) break;
      await batch.commit(noResult: true, continueOnError: true);
      written += n;
      onProgress?.call(written);
    }

    // Phase 2: the swap — pure in-SQL row moves, hundreds of ms not minutes.
    await db.transaction((txn) async {
      // VOD watch state and favorites live in the portable key space
      // (episode_progress / favorites_v2), so the CASCADE wiping the
      // id-keyed projections is harmless — they're rebuilt below. Only LIVE
      // progress rows are direct id-keyed writes (recent-channels recency),
      // so they alone are captured by url and re-mapped.
      final liveProg = await txn.rawQuery(
          'SELECT s.url AS url, p.position_ms AS position_ms, '
          'p.duration_ms AS duration_ms, p.watched AS watched, '
          'p.updated_at AS updated_at FROM progress p '
          'JOIN streams s ON s.id=p.stream_id '
          "WHERE s.playlist_id=? AND s.kind='live'",
          [playlistId]);

      if (ftsAvailable) {
        await txn.execute(
            'DELETE FROM streams_fts WHERE rowid IN (SELECT id FROM streams WHERE playlist_id=?)',
            [playlistId]);
      }
      await txn
          .delete('streams', where: 'playlist_id=?', whereArgs: [playlistId]);
      await txn.execute(
          'INSERT INTO streams(playlist_id,kind,name,logo,url,group_title,tvg_id,num,rating,title_key) '
          'SELECT playlist_id,kind,name,logo,url,group_title,tvg_id,num,rating,title_key '
          'FROM streams_staging WHERE playlist_id=? ORDER BY rowid',
          [playlistId]);

      // Populate the FTS shadow in one pass over the freshly inserted rows.
      // A single INSERT..SELECT is far faster than per-row FTS writes.
      if (ftsAvailable) {
        await txn.execute(
            'INSERT INTO streams_fts(rowid, name) '
            'SELECT id, name FROM streams WHERE playlist_id=?',
            [playlistId]);
      }

      for (final p in liveProg) {
        await txn.rawInsert(
            'INSERT OR REPLACE INTO progress'
            '(stream_id, position_ms, duration_ms, watched, updated_at) '
            'SELECT id, ?, ?, ?, ? FROM streams '
            'WHERE playlist_id=? AND url=? LIMIT 1',
            [
              p['position_ms'],
              p['duration_ms'],
              p['watched'],
              p['updated_at'],
              playlistId,
              p['url'],
            ]);
      }
      await txn.delete('streams_staging',
          where: 'playlist_id=?', whereArgs: [playlistId]);

      // Rebuild the id-keyed projections from the key space against the
      // fresh ids — this replaces the old url capture/re-map entirely.
      await _rebuildProjections(txn);
    });

    return written;
  }

  // ---- Queries -------------------------------------------------------------

  Future<List<Category>> categories(int playlistId, StreamKind kind) async {
    final rows = await db.rawQuery(
      'SELECT group_title AS name, COUNT(*) AS count FROM streams '
      'WHERE playlist_id=? AND kind=? GROUP BY group_title ORDER BY name',
      [playlistId, kind.name],
    );
    return rows
        .map((r) => Category(
              id: '$playlistId:${kind.name}:${r['name']}',
              playlistId: playlistId,
              kind: kind,
              name: (r['name'] as String?)?.trim().isNotEmpty == true
                  ? r['name'] as String
                  : 'Uncategorized',
              count: (r['count'] as int?) ?? 0,
            ))
        .toList();
  }

  /// Paged window into a single category — the heart of buttery scrolling.
  Future<List<StreamItem>> streamsInCategory({
    required int playlistId,
    required StreamKind kind,
    String? groupTitle,
    required int offset,
    required int limit,
  }) async {
    final where = StringBuffer('playlist_id=? AND kind=?');
    final args = <Object?>[playlistId, kind.name];
    if (groupTitle != null) {
      where.write(' AND group_title=?');
      args.add(groupTitle);
    }
    final rows = await db.query(
      'streams',
      where: where.toString(),
      whereArgs: args,
      orderBy: 'num IS NULL, num, name COLLATE NOCASE',
      limit: limit,
      offset: offset,
    );
    return rows.map(StreamItem.fromRow).toList();
  }

  /// Search within a single category (LIKE over a small shard — cheap).
  Future<List<StreamItem>> searchInCategory({
    required int playlistId,
    required StreamKind kind,
    required String groupTitle,
    required String query,
    int limit = 300,
  }) async {
    final rows = await db.query(
      'streams',
      where: 'playlist_id=? AND kind=? AND group_title=? AND name LIKE ?',
      whereArgs: [playlistId, kind.name, groupTitle, '%$query%'],
      orderBy: 'num IS NULL, num, name COLLATE NOCASE',
      limit: limit,
    );
    return rows.map(StreamItem.fromRow).toList();
  }

  /// Event-style live channels for the Sports tab: "TEAM vs TEAM" names plus
  /// anything in a sports-flavoured category. (LIKE is case-insensitive for
  /// ASCII, so "% vs %" also catches "VS".)
  Future<List<StreamItem>> sportsEvents(int playlistId,
      {int limit = 1200}) async {
    final rows = await db.rawQuery(
      "SELECT * FROM streams WHERE playlist_id=? AND kind='live' AND ("
      "  name LIKE '% vs %' OR name LIKE '% v %'"
      "  OR group_title LIKE '%sport%' OR group_title LIKE '%world cup%'"
      "  OR group_title LIKE '%football%' OR group_title LIKE '%soccer%'"
      "  OR group_title LIKE '%basket%' OR group_title LIKE '%nba%'"
      "  OR group_title LIKE '%nfl%' OR group_title LIKE '%nhl%'"
      "  OR group_title LIKE '%hockey%' OR group_title LIKE '%tennis%'"
      "  OR group_title LIKE '%ufc%' OR group_title LIKE '%boxing%'"
      "  OR group_title LIKE '%olympic%' OR group_title LIKE '%espn%'"
      "  OR group_title LIKE '%dazn%' OR group_title LIKE '%sky spor%'"
      "  OR group_title LIKE '%cricket%' OR group_title LIKE '%rugby%'"
      "  OR group_title LIKE '%motogp%' OR group_title LIKE '%formula%' OR group_title LIKE '% f1%'"
      ") ORDER BY group_title, num, name COLLATE NOCASE LIMIT ?",
      [playlistId, limit],
    );
    return rows.map(StreamItem.fromRow).toList();
  }

  /// Search across names. Uses FTS5 when available (instant prefix match),
  /// otherwise falls back to indexed LIKE so devices without fts5 still search.
  Future<List<StreamItem>> search({
    required int playlistId,
    StreamKind? kind,
    required String query,
    int limit = 200,
  }) async {
    final rawTokens =
        query.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (rawTokens.isEmpty) return [];

    if (!ftsAvailable) {
      // LIKE fallback: AND together each token as a substring match.
      final where = StringBuffer('playlist_id=?');
      final args = <Object?>[playlistId];
      if (kind != null) {
        where.write(' AND kind=?');
        args.add(kind.name);
      }
      for (final t in rawTokens) {
        where.write(' AND name LIKE ?');
        args.add('%$t%');
      }
      final rows = await db.query(
        'streams',
        where: where.toString(),
        whereArgs: args,
        orderBy: 'name COLLATE NOCASE',
        limit: limit,
      );
      return rows.map(StreamItem.fromRow).toList();
    }

    final match = rawTokens.map((t) => '"${t.replaceAll('"', '')}"*').join(' ');
    final args = <Object?>[match, playlistId];
    var kindClause = '';
    if (kind != null) {
      kindClause = ' AND s.kind=?';
      args.add(kind.name);
    }
    args.add(limit);
    final rows = await db.rawQuery(
      'SELECT s.* FROM streams_fts f JOIN streams s ON s.id=f.rowid '
      'WHERE streams_fts MATCH ? AND s.playlist_id=?$kindClause '
      'ORDER BY rank LIMIT ?',
      args,
    );
    return rows.map(StreamItem.fromRow).toList();
  }

  // ---- Favorites / progress ------------------------------------------------

  /// Favorite/unfavorite by the portable key. Writes `favorites_v2` (the
  /// durable, syncable truth) and refreshes the id-keyed `favorites`
  /// projection for every library row matching the key — so favoriting
  /// "EN - Dune" also stars "Dune 4K", matching the search dedupe.
  Future<void> toggleFavorite(StreamItem item, bool fav,
      {SyncOrigin origin = SyncOrigin.local}) async {
    final key = favKeyForItem(item);
    final now = SyncClock.now();
    await db.transaction((txn) async {
      await txn.insert(
        'favorites_v2',
        {
          'fav_key': key,
          'kind': item.kind.name,
          'added_at': now,
          'deleted': fav ? 0 : 1,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _journal(txn, origin, 'fav', key,
          fav ? {'kind': item.kind.name, 'at': now} : null,
          deleted: !fav, updatedAt: now);
    });
    await _projectFavoriteKey(key, item.kind, fav ? now : null);
    _notifyOutbox();
  }

  /// Refresh the `favorites` projection rows for one fav_key. [addedAt] null
  /// means the key was unfavorited (delete the projection rows).
  Future<void> _projectFavoriteKey(
      String key, StreamKind kind, int? addedAt) async {
    final String where;
    final List<Object?> args;
    if (key.startsWith('live:tvg:')) {
      where = "kind='live' AND tvg_id=?";
      args = [key.substring(9)];
    } else if (key.startsWith('live:xt:')) {
      where = "kind='live' AND url LIKE ?";
      args = ['%/${key.substring(8)}.%'];
    } else if (key.startsWith('live:url:')) {
      where = "kind='live' AND url=?";
      args = [key.substring(9)];
    } else {
      final isShow = key.startsWith('show:');
      where = 'kind=? AND title_key=?';
      args = [
        isShow ? 'series' : 'movie',
        isShow ? key.substring(5) : key.substring(6)
      ];
    }
    if (addedAt == null) {
      await db.execute(
          'DELETE FROM favorites WHERE stream_id IN '
          '(SELECT id FROM streams WHERE $where)',
          args);
    } else {
      await db.execute(
          'INSERT OR REPLACE INTO favorites(stream_id, added_at) '
          'SELECT id, ? FROM streams WHERE $where',
          [addedAt, ...args]);
    }
  }

  /// Every favorited key (movie:/show:/live:*), for items with no library
  /// row — the detail screen's star on debrid-only titles.
  Future<Set<String>> favoriteKeys() async {
    final rows = await db.query('favorites_v2',
        columns: ['fav_key'], where: 'deleted=0');
    return rows.map((r) => r['fav_key'] as String).toSet();
  }

  Future<Set<int>> favoriteIds() async {
    final rows = await db.query('favorites', columns: ['stream_id']);
    return rows.map((r) => r['stream_id'] as int).toSet();
  }

  Future<List<StreamItem>> favorites() async {
    final rows = await db.rawQuery(
      'SELECT s.* FROM favorites fv JOIN streams s ON s.id=fv.stream_id '
      'ORDER BY fv.added_at DESC',
    );
    return _oneCardPerTitle(rows, rows.length);
  }

  /// Favorites of one kind in one playlist — backs the "My Favorites"
  /// pseudo-category in the Live TV sidebar.
  Future<List<StreamItem>> favoritesByKind(
      int playlistId, StreamKind kind) async {
    final rows = await db.rawQuery(
      'SELECT s.* FROM favorites fv JOIN streams s ON s.id=fv.stream_id '
      'WHERE s.playlist_id=? AND s.kind=? ORDER BY fv.added_at DESC',
      [playlistId, kind.name],
    );
    return _oneCardPerTitle(rows, rows.length);
  }

  /// stream_id → last-touched ms for every progress row. Lets Continue
  /// Watching interleave stream-backed items with per-episode show entries by
  /// recency without widening the StreamItem model.
  Future<Map<int, int>> progressTimestamps() async {
    final rows =
        await db.query('progress', columns: ['stream_id', 'updated_at']);
    return {
      for (final r in rows)
        r['stream_id'] as int: (r['updated_at'] as int?) ?? 0,
    };
  }

  /// stream_id → completed fraction (0..1) for every in-progress item.
  /// Drives the partial-progress bars on cards.
  Future<Map<int, double>> progressFractions() async {
    final rows = await db
        .rawQuery('SELECT stream_id, position_ms, duration_ms FROM progress '
            'WHERE duration_ms > 0');
    final out = <int, double>{};
    for (final r in rows) {
      final pos = (r['position_ms'] as num?)?.toDouble() ?? 0;
      final dur = (r['duration_ms'] as num?)?.toDouble() ?? 0;
      if (dur > 0) out[r['stream_id'] as int] = (pos / dur).clamp(0.0, 1.0);
    }
    return out;
  }

  /// Mark a title watched by its portable key (`movie:<tk>` / `show:<tk>`),
  /// e.g. reflecting Trakt's watched history. Flag-only row (0/0 pos/dur).
  Future<void> markWatched(String key,
          {SyncOrigin origin = SyncOrigin.local}) =>
      markWatchedMany([key], origin: origin);

  /// Batched [markWatched] — the Trakt watched-history reconciliation marks
  /// hundreds of titles at once; one transaction instead of N round-trips.
  Future<void> markWatchedMany(Iterable<String> keys,
      {SyncOrigin origin = SyncOrigin.local}) async {
    final list = keys.toList();
    if (list.isEmpty) return;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final key in list) {
        batch.insert(
          'episode_progress',
          {
            'ep_key': key,
            'position_ms': 0,
            'duration_ms': 0,
            'watched': 1,
            'updated_at': SyncClock.now(),
            'deleted': 0,
            'synthetic': 0,
            'origin': origin.name,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true, continueOnError: true);
      for (final key in list) {
        await _journal(txn, origin, 'prog', key, {'p': 0, 'd': 0, 'w': 1});
      }
    });
    for (final key in list) {
      await _projectProgressKey(key);
    }
    _notifyOutbox();
  }

  /// Clear the watched flag on a title (the season un-watch toggle must also
  /// clear the series' poster check, which the Trakt reconciliation set).
  /// Flag-only rows become tombstones; real progress keeps its position with
  /// the flag cleared.
  Future<void> unmarkWatched(String key,
      {SyncOrigin origin = SyncOrigin.local}) async {
    final rows = await db.query('episode_progress',
        where: 'ep_key=?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return;
    final at = SyncClock.now();
    final pos = rows.first['position_ms'] as int? ?? 0;
    final dur = rows.first['duration_ms'] as int? ?? 0;
    final flagOnly = pos == 0 && dur == 0;
    await db.transaction((txn) async {
      if (flagOnly) {
        await txn.update(
            'episode_progress',
            {'watched': 0, 'deleted': 1, 'updated_at': at,
              'origin': origin.name},
            where: 'ep_key=?',
            whereArgs: [key]);
        await _journal(txn, origin, 'prog', key, null,
            deleted: true, updatedAt: at);
      } else {
        await txn.update('episode_progress',
            {'watched': 0, 'updated_at': at, 'origin': origin.name},
            where: 'ep_key=?', whereArgs: [key]);
        await _journal(txn, origin, 'prog', key, {'p': pos, 'd': dur, 'w': 0},
            updatedAt: at);
      }
    });
    await _projectProgressKey(key);
    _notifyOutbox();
  }

  /// Every movie + series row of one playlist, in a single query — feeds the
  /// in-memory TitleIndex so per-title discovery matching never hits SQL.
  Future<List<StreamItem>> vodItems(int playlistId) async {
    final rows = await db.query(
      'streams',
      where: "playlist_id=? AND kind IN ('movie','series')",
      whereArgs: [playlistId],
    );
    return rows.map(StreamItem.fromRow).toList();
  }

  Future<Set<int>> watchedIds(int playlistId) async {
    final rows = await db.rawQuery(
      'SELECT pr.stream_id FROM progress pr JOIN streams s ON s.id=pr.stream_id '
      'WHERE s.playlist_id=? AND pr.watched=1',
      [playlistId],
    );
    return rows.map((r) => r['stream_id'] as int).toSet();
  }

  /// Live channels only: an id-keyed recency write (backs the recent-
  /// channels behaviour of Recently Watched). Live has no title identity, so
  /// it stays out of the portable key space — VOD progress must go through
  /// [saveEpisodeProgress] with a `movie:`/episode key instead, or the next
  /// projection rebuild would silently discard it.
  Future<void> saveLiveProgress(int streamId, int posMs, int durMs) async {
    await db.insert(
      'progress',
      {
        'stream_id': streamId,
        'position_ms': posMs,
        'duration_ms': durMs,
        'watched': 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

}
