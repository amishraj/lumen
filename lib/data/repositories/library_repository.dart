import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart' hide Category;

import '../db/app_database.dart';
import '../models/models.dart';
import '../sources/m3u_parser.dart';
import '../sources/xtream_client.dart';

class SyncProgress {
  final String stage;
  final int written;
  const SyncProgress(this.stage, [this.written = 0]);
}

/// Orchestrates fetch → parse (isolate) → bulk persist for a source.
class LibraryRepository {
  LibraryRepository(this.db);
  final AppDatabase db;

  Future<List<Playlist>> playlists() => db.playlists();

  Future<Playlist> addPlaylist(Playlist pl) async {
    final id = await db.insertPlaylist(pl);
    return pl.copyWith(id: id);
  }

  Future<void> removePlaylist(int id) => db.deletePlaylist(id);

  /// Full sync. Emits coarse progress so the UI can show a live status.
  Stream<SyncProgress> sync(Playlist pl) async* {
    if (pl.id == null) throw ArgumentError('playlist must be persisted first');

    List<StreamItem> items;
    if (pl.kind == SourceKind.m3u) {
      yield const SyncProgress('Downloading playlist…');
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 120),
        headers: {'User-Agent': 'Lumen/1.0'},
      ));
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => HttpClient()
          ..badCertificateCallback = (cert, host, port) => true,
      );
      final res = await dio.get(pl.url,
          options: Options(responseType: ResponseType.plain));
      yield const SyncProgress('Parsing channels…');
      // Parse off the UI thread — a 40k-line M3U is multi-MB.
      items = await compute(parseM3u, M3uParseArgs(pl.id!, res.data as String));
    } else {
      final client = XtreamClient(pl);
      await client.authenticate();
      final stages = <String>[];
      items = await client.fetchAll(onStage: stages.add);
    }

    yield SyncProgress('Saving ${items.length} items…');
    var lastReported = 0;
    final count = await db.replaceStreams(
      pl.id!,
      items,
      onProgress: (w) {
        // throttle: report every ~2000 rows
        if (w - lastReported >= 2000) lastReported = w;
      },
    );
    await db.markSynced(pl.id!, count);
    yield SyncProgress('Done', count);
  }

  Future<List<Category>> categories(int playlistId, StreamKind kind) =>
      db.categories(playlistId, kind);

  Future<List<StreamItem>> page({
    required int playlistId,
    required StreamKind kind,
    String? groupTitle,
    required int offset,
    required int limit,
  }) =>
      db.streamsInCategory(
        playlistId: playlistId,
        kind: kind,
        groupTitle: groupTitle,
        offset: offset,
        limit: limit,
      );

  Future<List<StreamItem>> search({
    required int playlistId,
    StreamKind? kind,
    required String query,
  }) =>
      db.search(playlistId: playlistId, kind: kind, query: query);

  Future<Set<int>> favoriteIds() => db.favoriteIds();
  Future<void> toggleFavorite(int id, bool fav) => db.toggleFavorite(id, fav);
  Future<EpgEntry?> nowPlaying(String channelId) =>
      db.nowPlaying(channelId, DateTime.now().millisecondsSinceEpoch);
}
