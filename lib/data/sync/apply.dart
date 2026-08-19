// Remote-apply: pulled docs land in the local DB with origin=remote (never
// journaled — they came from the server).
//
// INVARIANT: this file must NEVER import trakt_service.dart. If a pull could
// call Trakt, device B would re-scrobble device A's play and Trakt history
// would double. The pull is DB-only; Trakt reconciliation runs separately,
// after, from its own snapshots.

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import '../db/sync_origin.dart';
import '../models/models.dart';
import '../repositories/library_repository.dart';

/// One pulled doc.
class SyncDoc {
  final String ns, k;
  final String? v;
  final bool deleted;
  final int updatedAt;
  final String deviceId;
  final int seq;
  const SyncDoc(this.ns, this.k, this.v, this.deleted, this.updatedAt,
      this.deviceId, this.seq);

  factory SyncDoc.fromJson(Map<String, dynamic> j) => SyncDoc(
        j['ns'] as String,
        j['k'] as String,
        j['v'] as String?,
        (j['deleted'] as num? ?? 0) != 0,
        (j['updated_at'] as num? ?? 0).toInt(),
        '${j['device_id'] ?? ''}',
        (j['seq'] as num? ?? 0).toInt(),
      );

  Map<String, dynamic>? get value =>
      v == null ? null : jsonDecode(v!) as Map<String, dynamic>;
}

/// What changed, so the caller can invalidate the right providers.
class ApplyStats {
  bool progress = false, favorites = false, pins = false, settings = false;
  bool sources = false, dismissals = false;
  bool get any =>
      progress || favorites || pins || settings || sources || dismissals;
}

Future<ApplyStats> applyRemoteDocs(
    LibraryRepository repo, List<SyncDoc> docs) async {
  final stats = ApplyStats();
  for (final doc in docs) {
    try {
      switch (doc.ns) {
        case 'prog':
          if (await _applyProg(repo.db, doc)) stats.progress = true;
        case 'fav':
          if (await _applyFav(repo.db, doc)) stats.favorites = true;
        case 'pin':
          if (await _applyPin(repo.db, doc)) stats.pins = true;
        case 'set':
          if (await _applySet(repo, doc)) stats.settings = true;
        case 'src':
          if (await _applySrc(repo, doc)) stats.sources = true;
        case 'cwh':
          if (await _applyCwh(repo, doc)) stats.dismissals = true;
      }
    } catch (_) {/* one bad doc must not block the page */}
  }
  return stats;
}

/// LWW guard, client side: only apply when the remote row is strictly newer
/// than what we hold. Local wins ties — the monotonic per-device clock makes
/// real ties impossible; an artificial one means we already have it.
Future<bool> _applyProg(AppDatabase db, SyncDoc doc) async {
  final have = await db.db.query('episode_progress',
      columns: ['updated_at'], where: 'ep_key=?', whereArgs: [doc.k], limit: 1);
  final haveAt = have.isEmpty ? -1 : (have.first['updated_at'] as int? ?? 0);
  if (doc.updatedAt <= haveAt) return false;
  final v = doc.value;
  await db.db.insert(
    'episode_progress',
    {
      'ep_key': doc.k,
      'position_ms': (v?['p'] as num?)?.toInt() ?? 0,
      'duration_ms': (v?['d'] as num?)?.toInt() ?? 0,
      'watched': (v?['w'] as num?)?.toInt() ?? 0,
      'updated_at': doc.updatedAt,
      'deleted': doc.deleted ? 1 : 0,
      'synthetic': 0,
      'origin': SyncOrigin.remote.name,
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  await db.projectProgressKeyRemote(doc.k);
  return true;
}

Future<bool> _applyFav(AppDatabase db, SyncDoc doc) async {
  final have = await db.db.query('favorites_v2',
      columns: ['updated_at'],
      where: 'fav_key=?',
      whereArgs: [doc.k],
      limit: 1);
  final haveAt = have.isEmpty ? -1 : (have.first['updated_at'] as int? ?? 0);
  if (doc.updatedAt <= haveAt) return false;
  final v = doc.value;
  final kindName = '${v?['kind'] ?? _kindFromKey(doc.k)}';
  await db.db.insert(
    'favorites_v2',
    {
      'fav_key': doc.k,
      'kind': kindName,
      'added_at': (v?['at'] as num?)?.toInt() ?? doc.updatedAt,
      'deleted': doc.deleted ? 1 : 0,
      'updated_at': doc.updatedAt,
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  final kind = StreamKind.values
      .firstWhere((x) => x.name == kindName, orElse: () => StreamKind.movie);
  await db.projectFavoriteKeyRemote(
      doc.k, kind, doc.deleted ? null : (v?['at'] as num?)?.toInt());
  return true;
}

String _kindFromKey(String k) => k.startsWith('show:')
    ? 'series'
    : k.startsWith('live:')
        ? 'live'
        : 'movie';

Future<bool> _applyPin(AppDatabase db, SyncDoc doc) async {
  // k = <source_key>|<kind>|<name> — source_key may itself contain '|'? No:
  // sourceKeyFor never emits '|', and kind names are fixed, so split from
  // the RIGHT twice.
  final lastBar = doc.k.lastIndexOf('|');
  if (lastBar <= 0) return false;
  final name = doc.k.substring(lastBar + 1);
  final rest = doc.k.substring(0, lastBar);
  final kindBar = rest.lastIndexOf('|');
  if (kindBar <= 0) return false;
  final kind = rest.substring(kindBar + 1);
  final sourceKey = rest.substring(0, kindBar);
  final have = await db.db.query('pinned_v2',
      columns: ['updated_at'],
      where: 'source_key=? AND kind=? AND name=?',
      whereArgs: [sourceKey, kind, name],
      limit: 1);
  final haveAt = have.isEmpty ? -1 : (have.first['updated_at'] as int? ?? 0);
  if (doc.updatedAt <= haveAt) return false;
  await db.db.insert(
    'pinned_v2',
    {
      'source_key': sourceKey,
      'kind': kind,
      'name': name,
      'position': (doc.value?['position'] as num?)?.toInt() ?? 0,
      'deleted': doc.deleted ? 1 : 0,
      'updated_at': doc.updatedAt,
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  return true;
}

Future<bool> _applySet(LibraryRepository repo, SyncDoc doc) async {
  final current = await repo.getSetting(doc.k);
  final incoming = doc.deleted ? null : '${doc.value?['s'] ?? ''}';
  if (current == incoming) return false;
  // origin: remote → not re-journaled; still fires onSettingChanged so the
  // reinstall vault picks up synced credentials.
  await repo.setSetting(doc.k, incoming, origin: SyncOrigin.remote);
  return true;
}

Future<bool> _applySrc(LibraryRepository repo, SyncDoc doc) async {
  final lists = await repo.playlists();
  Playlist? match;
  for (final pl in lists) {
    if (playlistSourceKey(pl) == doc.k) {
      match = pl;
      break;
    }
  }
  if (doc.deleted) {
    if (match?.id == null) return false;
    await repo.removePlaylist(match!.id!, origin: SyncOrigin.remote);
    return true;
  }
  if (match != null) return false; // already present — nothing to do
  final v = doc.value;
  if (v == null || v['url'] == null) return false;
  // lastSyncedAt stays null → the existing T+6s resync slot ingests it.
  // Deliberately NOT an inline library sync: that's a multi-minute 40k-row
  // job and this runs during a background pull.
  await repo.addPlaylist(
      origin: SyncOrigin.remote,
      Playlist(
        name: '${v['name'] ?? 'Synced source'}',
        kind: '${v['kind']}' == 'xtream' ? SourceKind.xtream : SourceKind.m3u,
        url: '${v['url']}',
        username: v['username'] as String?,
        password: v['password'] as String?,
        epgUrl: v['epg_url'] as String?,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
  return true;
}

Future<bool> _applyCwh(LibraryRepository repo, SyncDoc doc) async {
  // cw_hidden stays a local blob; each remote doc is one entry of it.
  final raw = await repo.getSetting('cw_hidden');
  Map<String, dynamic> map;
  try {
    map = raw == null || raw.isEmpty
        ? {}
        : jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    map = {};
  }
  final at = (doc.value?['at'] as num?)?.toInt() ?? doc.updatedAt;
  final have = (map[doc.k] as num?)?.toInt() ?? -1;
  if (doc.deleted) {
    if (!map.containsKey(doc.k)) return false;
    map.remove(doc.k);
  } else {
    if (have >= at) return false;
    map[doc.k] = at;
  }
  await repo.setSetting('cw_hidden', jsonEncode(map),
      origin: SyncOrigin.remote);
  return true;
}
