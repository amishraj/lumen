import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/models.dart';

/// Single SQLite database. This is the source of truth — the UI never holds the
/// full channel set in memory; it queries indexed, paginated windows from here.
class AppDatabase {
  AppDatabase._(this.db);
  final Database db;

  static AppDatabase? _instance;

  static Future<AppDatabase> open() async {
    if (_instance != null) return _instance!;
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'lumen.db');
    final db = await openDatabase(
      path,
      version: 1,
      onConfigure: (db) async {
        await db.execute('PRAGMA journal_mode=WAL');
        await db.execute('PRAGMA synchronous=NORMAL');
        await db.execute('PRAGMA foreign_keys=ON');
      },
      onCreate: _createSchema,
    );
    return _instance = AppDatabase._(db);
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

    // FTS5 over channel names for instant search across 40k+ entries.
    await db.execute(
        "CREATE VIRTUAL TABLE streams_fts USING fts5(name, tokenize='unicode61')");

    await db.execute('''
      CREATE TABLE epg (
        channel_id TEXT NOT NULL,
        start_ms INTEGER NOT NULL,
        stop_ms INTEGER NOT NULL,
        title TEXT NOT NULL,
        description TEXT
      )''');
    await db.execute('CREATE INDEX idx_epg_chan ON epg(channel_id, start_ms)');

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
  }

  // ---- Playlists -----------------------------------------------------------

  Future<int> insertPlaylist(Playlist pl) =>
      db.insert('playlists', pl.toRow()..remove('id'));

  Future<List<Playlist>> playlists() async {
    final rows = await db.query('playlists', orderBy: 'created_at DESC');
    return rows.map(Playlist.fromRow).toList();
  }

  Future<void> deletePlaylist(int id) async {
    await db.delete('playlists', where: 'id=?', whereArgs: [id]);
    // FTS rows for this playlist's streams are orphaned by id; rebuild is cheap
    // relative to a full resync, but we prune precisely here.
    await db.execute(
        'DELETE FROM streams_fts WHERE rowid IN (SELECT id FROM streams WHERE playlist_id=?)',
        [id]);
    await db.delete('streams', where: 'playlist_id=?', whereArgs: [id]);
  }

  Future<void> markSynced(int playlistId, int count) async {
    await db.update(
      'playlists',
      {'last_synced_at': DateTime.now().millisecondsSinceEpoch, 'stream_count': count},
      where: 'id=?',
      whereArgs: [playlistId],
    );
  }

  // ---- Bulk ingest ---------------------------------------------------------

  /// Replace all streams for a playlist. Inserts in batched transactions so a
  /// 40k-row playlist lands without spiking memory or blocking on one giant
  /// statement. [onProgress] reports rows written so the UI can show progress.
  Future<int> replaceStreams(
    int playlistId,
    Iterable<StreamItem> items, {
    void Function(int written)? onProgress,
    int batchSize = 800,
  }) async {
    // Clear old rows + their FTS shadow.
    await db.execute(
        'DELETE FROM streams_fts WHERE rowid IN (SELECT id FROM streams WHERE playlist_id=?)',
        [playlistId]);
    await db.delete('streams', where: 'playlist_id=?', whereArgs: [playlistId]);

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
          'INSERT INTO streams(playlist_id,kind,name,logo,url,group_title,tvg_id,num,rating) '
          'VALUES(?,?,?,?,?,?,?,?,?)',
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
          ],
        );
        n++;
      }
      if (n == 0) break;
      await batch.commit(noResult: true, continueOnError: true);
      written += n;
      onProgress?.call(written);
    }

    // Populate the FTS shadow in one pass over the freshly inserted rows.
    // A single INSERT..SELECT is far faster than per-row FTS writes during ingest.
    await db.execute(
        'INSERT INTO streams_fts(rowid, name) '
        'SELECT id, name FROM streams WHERE playlist_id=?',
        [playlistId]);

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

  /// FTS search — instant substring/prefix match across all names.
  Future<List<StreamItem>> search({
    required int playlistId,
    StreamKind? kind,
    required String query,
    int limit = 200,
  }) async {
    final tokens = query
        .trim()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .map((t) => '"${t.replaceAll('"', '')}"*')
        .toList();
    if (tokens.isEmpty) return [];
    final match = tokens.join(' ');
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

  Future<void> toggleFavorite(int streamId, bool fav) async {
    if (fav) {
      await db.insert(
        'favorites',
        {'stream_id': streamId, 'added_at': DateTime.now().millisecondsSinceEpoch},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } else {
      await db.delete('favorites', where: 'stream_id=?', whereArgs: [streamId]);
    }
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
    return rows.map(StreamItem.fromRow).toList();
  }

  Future<void> saveProgress(int streamId, int posMs, int durMs) async {
    final watched = durMs > 0 && posMs / durMs >= 0.9 ? 1 : 0;
    await db.insert(
      'progress',
      {
        'stream_id': streamId,
        'position_ms': posMs,
        'duration_ms': durMs,
        'watched': watched,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ---- EPG -----------------------------------------------------------------

  Future<EpgEntry?> nowPlaying(String channelId, int nowMs) async {
    final rows = await db.query(
      'epg',
      where: 'channel_id=? AND start_ms<=? AND stop_ms>?',
      whereArgs: [channelId, nowMs, nowMs],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return EpgEntry(
      channelId: channelId,
      startMs: r['start_ms'] as int,
      stopMs: r['stop_ms'] as int,
      title: r['title'] as String,
      description: r['description'] as String?,
    );
  }
}
