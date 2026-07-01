// Plain data models — no codegen, so the project builds with zero build_runner steps.

enum SourceKind { m3u, xtream }

enum StreamKind { live, movie, series }

StreamKind streamKindFromString(String s) => StreamKind.values.firstWhere(
      (e) => e.name == s,
      orElse: () => StreamKind.live,
    );

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

  StreamItem copyWith({String? logo, double? rating}) => StreamItem(
        id: id,
        playlistId: playlistId,
        kind: kind,
        name: name,
        logo: logo ?? this.logo,
        url: url,
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
