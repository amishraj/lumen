import 'dart:async';
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
        createHttpClient: () =>
            HttpClient()..badCertificateCallback = (cert, host, port) => true,
      );
      final res = await dio.get(pl.url,
          options: Options(responseType: ResponseType.plain));
      yield const SyncProgress('Parsing channels…');
      // Parse off the UI thread — a 40k-line M3U is multi-MB.
      items = await compute(parseM3u, M3uParseArgs(pl.id!, res.data as String));
    } else {
      final client = XtreamClient(pl);
      yield const SyncProgress('Connecting to portal…');
      // Surfaces a clear "check username/password/URL" error if login fails.
      await client.authenticate();
      // Bridge the client's per-phase callbacks into yielded progress so the
      // UI shows "Loading movies…", "Indexing…", etc. instead of sitting on a
      // frozen "Starting…" for the whole (often multi-minute) fetch — the main
      // reason Xtream syncs looked hung while M3U (which already yielded) didn't.
      final progress = StreamController<SyncProgress>();
      late List<StreamItem> fetched;
      final job = client
          .fetchAll(onStage: (s) => progress.add(SyncProgress(s)))
          .then((v) => fetched = v)
          .whenComplete(progress.close);
      yield* progress.stream;
      await job; // rethrows a clear error if a phase failed/timed out
      items = fetched;
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
    int limit = 200,
  }) =>
      db.search(
          playlistId: playlistId, kind: kind, query: query, limit: limit);

  Future<List<StreamItem>> searchInCategory({
    required int playlistId,
    required StreamKind kind,
    required String groupTitle,
    required String query,
  }) =>
      db.searchInCategory(
          playlistId: playlistId,
          kind: kind,
          groupTitle: groupTitle,
          query: query);

  Future<Set<int>> favoriteIds() => db.favoriteIds();
  Future<void> toggleFavorite(int id, bool fav) => db.toggleFavorite(id, fav);
  Future<List<StreamItem>> favorites() => db.favorites();
  Future<List<StreamItem>> favoritesByKind(int playlistId, StreamKind kind) =>
      db.favoritesByKind(playlistId, kind);
  Future<void> markWatched(int id) => db.markWatched(id);
  Future<void> markWatchedMany(Iterable<int> ids) => db.markWatchedMany(ids);
  Future<Set<int>> watchedIds(int playlistId) => db.watchedIds(playlistId);
  Future<Map<int, double>> progressFractions() => db.progressFractions();

  /// All movies + series of one playlist (one query) — the TitleIndex source.
  Future<List<StreamItem>> vodItems(int playlistId) => db.vodItems(playlistId);

  /// Providers often carry the same movie/show in several languages, prefixed
  /// like "EN | Title", "EN - Title", "ENGLISH: Title". When we pick a title
  /// match to play (Trakt / TMDB / discovery), prefer the English-labelled one
  /// and only fall back to another language if there's no English entry.
  static final _enLabel =
      RegExp(r'^\s*(en|eng|english)\b', caseSensitive: false);

  static StreamItem? preferEnglish(List<StreamItem> hits) {
    if (hits.isEmpty) return null;
    for (final h in hits) {
      if (_enLabel.hasMatch(h.name)) return h;
    }
    return hits.first;
  }

  Future<List<StreamItem>> sportsEvents(int playlistId) =>
      db.sportsEvents(playlistId);
  Future<EpgEntry?> nowPlaying(String channelId) =>
      db.nowPlaying(channelId, DateTime.now().millisecondsSinceEpoch);

  // Home feed.
  Future<List<StreamItem>> continueWatching(int playlistId) =>
      db.continueWatching(playlistId);
  Future<List<StreamItem>> recentlyWatched(int playlistId) =>
      db.recentlyWatched(playlistId);
  Future<List<StreamItem>> featured(int playlistId) => db.featured(playlistId);
  Future<List<StreamItem>> categoryPreview(
          int playlistId, StreamKind kind, String group) =>
      db.categoryPreview(playlistId: playlistId, kind: kind, groupTitle: group);

  // Pinned categories.
  Future<List<String>> pinnedCategories(int playlistId, StreamKind kind) =>
      db.pinnedCategories(playlistId, kind);
  Future<void> setPinned(
          int playlistId, StreamKind kind, String name, bool p) =>
      db.setPinned(playlistId, kind, name, p);

  // Settings.
  Future<String?> getSetting(String key) => db.getSetting(key);
  Future<void> setSetting(String key, String? value) =>
      db.setSetting(key, value);

  /// Resolve series episodes on demand (Xtream only).
  Future<List<Episode>> seriesEpisodes(Playlist pl, String seriesId) async {
    if (pl.kind != SourceKind.xtream) return [];
    return XtreamClient(pl).seriesEpisodes(seriesId);
  }
}
