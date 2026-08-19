import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/data/db/app_database.dart';
import 'package:lumen/data/models/models.dart';
import 'package:lumen/shared/title_keys.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Builds a REAL v4 database (the exact pre-v5 schema), seeds it with the
/// data shapes that exist in the wild, then opens it through AppDatabase and
/// asserts the v5 fold: portable keys, projections, tombstone semantics, and
/// that nothing a user could see went missing.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory dir;
  late String path;

  const now = 1755500000000; // fixed "now" for seeded rows

  Future<Database> createV4Db() async {
    final db = await openDatabase(path, version: 4,
        onCreate: (db, v) async {
      await db.execute('''CREATE TABLE playlists (
        id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
        kind TEXT NOT NULL, url TEXT NOT NULL, username TEXT, password TEXT,
        epg_url TEXT, created_at INTEGER NOT NULL, last_synced_at INTEGER,
        stream_count INTEGER NOT NULL DEFAULT 0)''');
      await db.execute('''CREATE TABLE streams (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
        kind TEXT NOT NULL, name TEXT NOT NULL, logo TEXT, url TEXT NOT NULL,
        group_title TEXT, tvg_id TEXT, num INTEGER, rating REAL)''');
      // The ffi SQLite has FTS5, so AppDatabase's probe will expect the
      // shadow table to exist — mirror the real v4 onCreate.
      await db.execute(
          "CREATE VIRTUAL TABLE streams_fts USING fts5(name, tokenize='unicode61')");
      await db.execute('''CREATE TABLE epg (
        channel_id TEXT NOT NULL, start_ms INTEGER NOT NULL,
        stop_ms INTEGER NOT NULL, title TEXT NOT NULL, description TEXT)''');
      await db.execute('''CREATE TABLE favorites (
        stream_id INTEGER PRIMARY KEY REFERENCES streams(id) ON DELETE CASCADE,
        added_at INTEGER NOT NULL)''');
      await db.execute('''CREATE TABLE progress (
        stream_id INTEGER PRIMARY KEY REFERENCES streams(id) ON DELETE CASCADE,
        position_ms INTEGER NOT NULL, duration_ms INTEGER NOT NULL,
        watched INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL)''');
      await db.execute(
          'CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT)');
      await db.execute('''CREATE TABLE pinned_categories (
        playlist_id INTEGER NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL,
        position INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (playlist_id, kind, name))''');
      await db.execute('''CREATE TABLE episode_progress (
        ep_key TEXT PRIMARY KEY, position_ms INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL, watched INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL)''');
      await db.execute('''CREATE TABLE stream_choice (
        choice_key TEXT PRIMARY KEY, url TEXT NOT NULL, label TEXT,
        quality TEXT, updated_at INTEGER NOT NULL)''');
      await db.execute('''CREATE TABLE trakt_outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT, payload TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)''');
      await db.execute('''CREATE TABLE streams_staging (
        playlist_id INTEGER NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL,
        logo TEXT, url TEXT NOT NULL, group_title TEXT, tvg_id TEXT,
        num INTEGER, rating REAL)''');
    });
    return db;
  }

  Future<void> seed(Database db) async {
    await db.insert('playlists', {
      'id': 1,
      'name': 'Main',
      'kind': 'xtream',
      'url': 'http://portal.example.com:8080',
      'username': 'user1',
      'password': 'hunter2',
      'created_at': now,
    });
    // Two language variants of one movie, a series, and a live channel.
    await db.insert('streams', {
      'id': 11, 'playlist_id': 1, 'kind': 'movie',
      'name': 'EN - The Godfather (1972) [1080p]',
      'url': 'http://x/movie/user1/hunter2/11.mkv',
    });
    await db.insert('streams', {
      'id': 12, 'playlist_id': 1, 'kind': 'movie',
      'name': 'FR | The Godfather FHD',
      'url': 'http://x/movie/user1/hunter2/12.mkv',
    });
    await db.insert('streams', {
      'id': 13, 'playlist_id': 1, 'kind': 'series',
      'name': "EN - Marvel's Daredevil (2015)",
      'url': 'http://x/series/user1/hunter2/13',
    });
    await db.insert('streams', {
      'id': 14, 'playlist_id': 1, 'kind': 'live',
      'name': 'ESPN HD', 'tvg_id': 'espn.us',
      'url': 'http://x/live/user1/hunter2/1401.ts',
    });

    // Id-keyed progress: in-progress movie on the EN variant, watched flag on
    // the series (Trakt reconciliation shape), recency row on the live channel.
    await db.insert('progress', {
      'stream_id': 11, 'position_ms': 3600000, 'duration_ms': 7200000,
      'watched': 0, 'updated_at': now - 1000,
    });
    await db.insert('progress', {
      'stream_id': 13, 'position_ms': 0, 'duration_ms': 0,
      'watched': 1, 'updated_at': now - 5000,
    });
    await db.insert('progress', {
      'stream_id': 14, 'position_ms': 500000, 'duration_ms': 0,
      'watched': 0, 'updated_at': now - 2000,
    });

    // Old-alphabet episode keys (punctuation kept) + a debrid-only movie key
    // + a synthetic Trakt seed (fake 100000ms denominator).
    await db.insert('episode_progress', {
      'ep_key': "marvel's daredevil|s1e3",
      'position_ms': 1500000, 'duration_ms': 3000000,
      'watched': 0, 'updated_at': now - 500,
    });
    await db.insert('episode_progress', {
      'ep_key': 'movie:dune part two',
      'position_ms': 45000, 'duration_ms': 100000,
      'watched': 0, 'updated_at': now - 800, // synthetic-shaped
    });

    // Favorites: the FR movie variant + the live channel.
    await db.insert('favorites', {'stream_id': 12, 'added_at': now - 9000});
    await db.insert('favorites', {'stream_id': 14, 'added_at': now - 8000});

    await db.insert('pinned_categories', {
      'playlist_id': 1, 'kind': 'live', 'name': 'Sports', 'position': 100,
    });

    // Old-alphabet (alnum) dismissal for the movie that exists in the library.
    await db.insert('app_settings', {
      'key': 'cw_hidden',
      'value': jsonEncode({'movie:thegodfather': now - 100}),
    });

    await db.insert('stream_choice', {
      'choice_key': 'movie:the godfather',
      'url': 'https://rd.example/signed', 'updated_at': now - 300,
    });
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lumen_v5_test');
    path = '${dir.path}/lumen.db';
    AppDatabase.resetForTest();
  });

  tearDown(() async {
    AppDatabase.resetForTest();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('v4 -> v5 preserves everything a user can see', () async {
    final v4 = await createV4Db();
    await seed(v4);
    await v4.close();

    final app = await AppDatabase.open(overridePath: path);
    final db = app.db;

    // Marker set.
    expect(
        (await db.query('sync_state', where: "key='v5_migrated_at'")).length,
        1);

    // title_key materialised; live rows have none.
    final tkeys = {
      for (final r in await db.query('streams', columns: ['id', 'title_key']))
        r['id'] as int: r['title_key'] as String?
    };
    expect(tkeys[11], 'the godfather');
    expect(tkeys[12], 'the godfather');
    expect(tkeys[13], 'marvel s daredevil');
    expect(tkeys[14], isNull);

    // source_key materialised (no credentials beyond the username).
    final pl = (await db.query('playlists')).first;
    expect(pl['source_key'], 'xt:portal.example.com:8080:user1');

    // Watch state folded into the portable key space.
    final watch = {
      for (final r in await db.query('episode_progress'))
        r['ep_key'] as String: r
    };
    // Movie progress folded from the id-keyed row.
    expect(watch['movie:the godfather']?['position_ms'], 3600000);
    // Series flag row folded to show:.
    expect(watch['show:marvel s daredevil']?['watched'], 1);
    // Episode key re-keyed into the canonical alphabet (apostrophe dropped).
    expect(watch["marvel s daredevil|s1e3"]?['position_ms'], 1500000);
    expect(watch.containsKey("marvel's daredevil|s1e3"), isFalse);
    // Synthetic Trakt seed retro-tagged.
    expect(watch['movie:dune part two']?['synthetic'], 1);
    expect(watch['movie:dune part two']?['origin'], 'trakt');

    // Projections: both movie variants carry the folded progress.
    final prog = {
      for (final r in await db.query('progress'))
        r['stream_id'] as int: r
    };
    expect(prog[11]?['position_ms'], 3600000);
    expect(prog[12]?['position_ms'], 3600000, reason: 'variant shares progress');
    expect(prog[13]?['watched'], 1);
    expect(prog[14]?['position_ms'], 500000, reason: 'live row untouched');

    // Favorites: v2 keys exist, projection stars BOTH movie variants.
    final favKeys = (await db.query('favorites_v2', where: 'deleted=0'))
        .map((r) => r['fav_key'])
        .toSet();
    expect(favKeys, {'movie:the godfather', 'live:tvg:espn.us'});
    final favIds = (await db.query('favorites'))
        .map((r) => r['stream_id'] as int)
        .toSet();
    expect(favIds, {11, 12, 14});

    // Pins re-keyed to the portable source key.
    final pins = await db.query('pinned_v2', where: 'deleted=0');
    expect(pins.single['source_key'], 'xt:portal.example.com:8080:user1');
    expect(pins.single['name'], 'Sports');

    // cw_hidden re-keyed from the alnum alphabet via the library.
    final hidden = jsonDecode((await db.query('app_settings',
            where: "key='cw_hidden'"))
        .single['value'] as String) as Map;
    expect(hidden.keys, ['movie:the godfather']);

    // Continue Watching still surfaces the movie (the user-visible check).
    final cw = await app.continueWatching(1);
    expect(cw.map((e) => e.id), contains(11));

    // v4 backups exist for rollback.
    expect((await db.query('progress_v4_backup')).length, 3);
    expect((await db.query('favorites_v4_backup')).length, 2);
  });

  test('backfill is idempotent (crashed-upgrade retry)', () async {
    final v4 = await createV4Db();
    await seed(v4);
    await v4.close();

    final app = await AppDatabase.open(overridePath: path);
    // Simulate the crash-retry: clear the marker and reopen.
    await app.db
        .delete('sync_state', where: "key='v5_migrated_at'");
    final before = (await app.db.query('episode_progress')).length;
    await app.db.close();
    AppDatabase.resetForTest();

    final app2 = await AppDatabase.open(overridePath: path);
    expect((await app2.db.query('episode_progress')).length, before);
    final favIds = (await app2.db.query('favorites'))
        .map((r) => r['stream_id'] as int)
        .toSet();
    expect(favIds, {11, 12, 14});
    await app2.db.close();
  });

  test('re-sync swap keeps watch state without the url re-map', () async {
    final v4 = await createV4Db();
    await seed(v4);
    await v4.close();

    final app = await AppDatabase.open(overridePath: path);
    // Simulate the weekly re-sync: same titles, DIFFERENT urls and new ids.
    await app.replaceStreams(1, [
      const StreamItem(
          playlistId: 1,
          kind: StreamKind.movie,
          name: 'EN - The Godfather (1972) [NEW-CDN]',
          url: 'http://y/movie/user1/hunter2/9911.mkv'),
      const StreamItem(
          playlistId: 1,
          kind: StreamKind.series,
          name: "Marvel's Daredevil",
          url: 'http://y/series/user1/hunter2/9913'),
      const StreamItem(
          playlistId: 1,
          kind: StreamKind.live,
          name: 'ESPN FHD',
          tvgId: 'espn.us',
          url: 'http://y/live/user1/hunter2/1401.ts'),
    ]);

    // Progress survived onto the NEW ids via the key-space projection.
    final rows = await app.db.rawQuery(
        'SELECT s.name, p.position_ms, p.watched FROM progress p '
        'JOIN streams s ON s.id=p.stream_id ORDER BY s.name');
    final byName = {for (final r in rows) r['name'] as String: r};
    expect(byName['EN - The Godfather (1972) [NEW-CDN]']?['position_ms'],
        3600000);
    expect(byName["Marvel's Daredevil"]?['watched'], 1);
    // Favorites too (movie variant + live channel via tvg id).
    final favNames = (await app.db.rawQuery(
            'SELECT s.name FROM favorites f JOIN streams s ON s.id=f.stream_id'))
        .map((r) => r['name'])
        .toSet();
    expect(favNames,
        {'EN - The Godfather (1972) [NEW-CDN]', 'ESPN FHD'});
    await app.db.close();
  });

  test('tombstones: un-watch survives, Trakt seed cannot resurrect it',
      () async {
    final v4 = await createV4Db();
    await seed(v4);
    await v4.close();

    final app = await AppDatabase.open(overridePath: path);
    const key = "marvel s daredevil|s1e3";
    await app.setEpisodesWatched([key], false); // un-watch -> tombstone
    expect((await app.episodeProgressAll()).containsKey(key), isFalse);
    final raw = (await app.db
            .query('episode_progress', where: 'ep_key=?', whereArgs: [key]))
        .single;
    expect(raw['deleted'], 1, reason: 'tombstone, not row deletion');

    // A Trakt seed with an OLDER paused_at must not resurrect it.
    await app.saveEpisodeProgressFraction(key, 0.5, updatedAt: now - 99999);
    expect((await app.episodeProgressAll()).containsKey(key), isFalse);

    // A real local checkpoint (the user pressed play) overrides the tombstone.
    await app.saveEpisodeProgress(key, 60000, 3000000);
    expect((await app.episodeProgressAll()).containsKey(key), isTrue);
    await app.db.close();
  });

  test('titleKey alphabet properties', () {
    expect(titleKey('EN - The Godfather (1972) [1080p]'), 'the godfather');
    expect(titleKey("Marvel's Daredevil"), 'marvel s daredevil');
    expect(titleKey('Dune 2021'), 'dune');
    expect(titleKey(titleKey('EN - The Godfather (1972)')),
        titleKey('EN - The Godfather (1972)'),
        reason: 'idempotent');
    expect(movieKey('The Matrix'), 'movie:the matrix');
    expect(epKey('Breaking Bad', 5, 14), 'breaking bad|s5e14');
    expect(
        liveFavKeyFor(
            tvgId: null, url: 'http://x/live/user1/hunter2/1401.ts'),
        'live:xt:1401',
        reason: 'credentials never enter the key');
  });
}
