// Plain data models — no codegen, so the project builds with zero build_runner steps.

import '../../shared/title_keys.dart' as tk;

enum SourceKind { m3u, xtream }

enum StreamKind { live, movie, series }

StreamKind streamKindFromString(String s) => StreamKind.values.firstWhere(
      (e) => e.name == s,
      orElse: () => StreamKind.live,
    );

/// Stable per-episode identity for local watch tracking. Series episodes are
/// resolved on demand (no DB stream row) and may play from IPTV *or* a
/// changing Real-Debrid url, so progress is keyed by the show title + S/E.
/// Since DB v5 this delegates to the canonical [tk.epKey] alphabet — raw and
/// already-cleaned titles converge on the same key.
String episodeKey(String showTitle, int season, int episode) =>
    tk.epKey(showTitle, season, episode);

/// Title-keyed identity for a movie's watch state (library-backed AND
/// debrid-only — since v5 both live in the same key space). Delegates to the
/// canonical [tk.movieKey] alphabet; the `movie:` namespace can never collide
/// with an episode key (those always contain a `|`).
String movieProgressKey(String title) => tk.movieKey(title);

/// Show-level watched marker (the poster check seeded from Trakt history).
String showProgressKey(String title) => tk.showKey(title);

/// Portable identity of a source — [Playlist.id] is a local AUTOINCREMENT and
/// means nothing on another device.
String playlistSourceKey(Playlist pl) => tk.sourceKeyFor(
      isXtream: pl.kind == SourceKind.xtream,
      url: pl.url,
      username: pl.username,
      debridSentinel: isDebridSentinel(pl),
    );

/// Identity of a live channel for favorites (live has no title identity).
String liveFavKey(StreamItem it) =>
    tk.liveFavKeyFor(tvgId: it.tvgId, url: it.url);

/// The favorites key for any item: title-keyed for VOD, channel-keyed for
/// live. This is what `favorites_v2.fav_key` stores.
String favKeyForItem(StreamItem it) => switch (it.kind) {
      StreamKind.live => liveFavKey(it),
      StreamKind.series => tk.showKey(it.name),
      StreamKind.movie => tk.movieKey(it.name),
    };

/// Sentinel "source" URL for a debrid-only setup (no IPTV provider). The row
/// exists so every playlist-scoped provider/snapshot has an id to key on, but
/// sync skips it entirely and it carries zero streams.
const String kDebridSentinelUrl = 'debrid://only';

/// True when [pl] is the debrid-only placeholder rather than a real IPTV source.
bool isDebridSentinel(Playlist? pl) => pl?.url == kDebridSentinelUrl;

/// A configured IPTV source (an M3U URL or Xtream Codes credentials).
class Playlist {
  final int? id;
  final String name;
  final SourceKind kind;

  /// For m3u: the playlist URL. For xtream: the portal base URL (http://host:port).
  final String url;
  final String? username; // xtream
  final String? password; // xtream
  final String? epgUrl; // optional XMLTV url
  final int createdAt;
  final int? lastSyncedAt;
  final int streamCount;

  const Playlist({
    this.id,
    required this.name,
    required this.kind,
    required this.url,
    this.username,
    this.password,
    this.epgUrl,
    required this.createdAt,
    this.lastSyncedAt,
    this.streamCount = 0,
  });

  /// Xtream player_api base, e.g. http://host:port/player_api.php?username=..&password=..
  String xtreamApi([String action = '']) {
    final base = url.replaceAll(RegExp(r'/+$'), '');
    final q = 'username=${Uri.encodeComponent(username ?? '')}'
        '&password=${Uri.encodeComponent(password ?? '')}';
    return action.isEmpty
        ? '$base/player_api.php?$q'
        : '$base/player_api.php?$q&action=$action';
  }

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'name': name,
        'kind': kind.name,
        'url': url,
        'username': username,
        'password': password,
        'epg_url': epgUrl,
        'created_at': createdAt,
        'last_synced_at': lastSyncedAt,
        'stream_count': streamCount,
      };

  factory Playlist.fromRow(Map<String, Object?> r) => Playlist(
        id: r['id'] as int?,
        name: r['name'] as String,
        kind: (r['kind'] as String) == 'xtream'
            ? SourceKind.xtream
            : SourceKind.m3u,
        url: r['url'] as String,
        username: r['username'] as String?,
        password: r['password'] as String?,
        epgUrl: r['epg_url'] as String?,
        createdAt: r['created_at'] as int,
        lastSyncedAt: r['last_synced_at'] as int?,
        streamCount: (r['stream_count'] as int?) ?? 0,
      );

  Playlist copyWith({int? id, int? lastSyncedAt, int? streamCount}) => Playlist(
        id: id ?? this.id,
        name: name,
        kind: kind,
        url: url,
        username: username,
        password: password,
        epgUrl: epgUrl,
        createdAt: createdAt,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
        streamCount: streamCount ?? this.streamCount,
      );
}

/// A category / group (group-title in M3U, category in Xtream).
class Category {
  final String id; // stable id: '${playlistId}:${kind}:${name}'
  final int playlistId;
  final StreamKind kind;
  final String name;
  final int count;

  const Category({
    required this.id,
    required this.playlistId,
    required this.kind,
    required this.name,
    this.count = 0,
  });

  factory Category.fromRow(Map<String, Object?> r) => Category(
        id: r['id'] as String,
        playlistId: r['playlist_id'] as int,
        kind: streamKindFromString(r['kind'] as String),
        name: r['name'] as String,
        count: (r['count'] as int?) ?? 0,
      );
}

/// A single playable item — a channel, movie, or series.
class StreamItem {
  final int? id;
  final int playlistId;
  final StreamKind kind;
  final String name;
  final String? logo;
  final String url; // resolved play url
  final String? groupTitle;
  final String? tvgId; // epg channel id
  final int? num; // channel number / sort order
  final double? rating;

  const StreamItem({
    this.id,
    required this.playlistId,
    required this.kind,
    required this.name,
    this.logo,
    required this.url,
    this.groupTitle,
    this.tvgId,
    this.num,
    this.rating,
  });

  factory StreamItem.fromRow(Map<String, Object?> r) => StreamItem(
        id: r['id'] as int?,
        playlistId: r['playlist_id'] as int,
        kind: streamKindFromString(r['kind'] as String),
        name: r['name'] as String,
        logo: r['logo'] as String?,
        url: r['url'] as String,
        groupTitle: r['group_title'] as String?,
        tvgId: r['tvg_id'] as String?,
        num: r['num'] as int?,
        rating: (r['rating'] as double?),
      );

  /// JSON round-trip for the persisted home-row snapshots (same keys as the
  /// DB row, so fromRow-shaped code can share the field names).
  Map<String, Object?> toJson() => {
        'id': id,
        'playlist_id': playlistId,
        'kind': kind.name,
        'name': name,
        'logo': logo,
        'url': url,
        'group_title': groupTitle,
        'tvg_id': tvgId,
        'num': num,
        'rating': rating,
      };

  // NB: the `num` field shadows the `num` type in here — cast via int/double.
  factory StreamItem.fromJson(Map<String, Object?> r) => StreamItem(
        id: r['id'] as int?,
        playlistId: (r['playlist_id'] as int?) ?? 0,
        kind: streamKindFromString('${r['kind']}'),
        name: '${r['name'] ?? ''}',
        logo: r['logo'] as String?,
        url: '${r['url'] ?? ''}',
        groupTitle: r['group_title'] as String?,
        tvgId: r['tvg_id'] as String?,
        num: r['num'] as int?,
        rating: r['rating'] is int
            ? (r['rating'] as int).toDouble()
            : r['rating'] as double?,
      );

  StreamItem copyWith({String? logo, double? rating, String? url}) =>
      StreamItem(
        id: id,
        playlistId: playlistId,
        kind: kind,
        name: name,
        logo: logo ?? this.logo,
        url: url ?? this.url,
        groupTitle: groupTitle,
        tvgId: tvgId,
        num: num,
        rating: rating ?? this.rating,
      );
}

/// One episode of a series (resolved on demand from Xtream get_series_info).
class Episode {
  final String id;
  final String title;
  final int season;
  final int episode;
  final String url; // direct play url
  final String? plot;
  final String? still; // thumbnail
  final int? durationSecs;

  const Episode({
    required this.id,
    required this.title,
    required this.season,
    required this.episode,
    required this.url,
    this.plot,
    this.still,
    this.durationSecs,
  });
}

/// Now/next EPG programme.
class EpgEntry {
  final String channelId;
  final int startMs;
  final int stopMs;
  final String title;
  final String? description;

  const EpgEntry({
    required this.channelId,
    required this.startMs,
    required this.stopMs,
    required this.title,
    this.description,
  });

  double progress(int nowMs) {
    if (nowMs <= startMs) return 0;
    if (nowMs >= stopMs) return 1;
    final span = (stopMs - startMs);
    if (span <= 0) return 0;
    return (nowMs - startMs) / span;
  }
}
