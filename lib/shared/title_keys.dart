/// The ONE portable identity for titles, sources and live channels.
///
/// Watch state, favorites and pins used to be keyed three different ways:
/// `streams.id` (destroyed on every playlist re-sync), `movieProgressKey`
/// (clean title, punctuation kept) and `cwKeyForTitle` (alnum-only). Same
/// `movie:` prefix, two alphabets — anything joining them silently missed.
/// Everything durable now goes through [titleKey], and the DB v5 migration
/// re-keyed all existing rows into this alphabet.
///
/// Rules:
/// - every transform is many-to-one, so re-keying merges rows and never
///   splits a title's history;
/// - live channels have NO title identity (cleanTitle strips HD/FHD/4K,
///   which is the only thing separating regional feeds) — they use
///   [liveFavKeyFor] instead;
/// - keys are sent to the sync server, so credentials must never enter one
///   (see the Xtream handling in [liveFavKeyFor] / [sourceKeyFor]).
library;

import 'title_utils.dart';

final _bareYear = RegExp(r'\s+(19|20)\d{2}$');
final _punct = RegExp(r'[^a-z0-9 ]');
final _runs = RegExp(r'\s{2,}');

/// Canonical lower-case identity of a VOD title. Idempotent: feeding a key
/// back through produces the same key, so raw provider names and
/// already-cleaned titles converge.
String titleKey(String rawName) {
  var s = cleanTitle(rawName).title.trim().toLowerCase();
  s = s.replaceFirst(_bareYear, '');
  s = s.replaceAll(_punct, ' ').replaceAll(_runs, ' ').trim();
  return s; // '' when nothing survives — callers treat that as "no identity"
}

/// A film: `movie:<tk>`. Namespaces can never collide: episode keys always
/// contain `|`, movie/show keys never do, and the prefixes differ.
String movieKey(String rawName) => 'movie:${titleKey(rawName)}';

/// A show-level marker (poster check from Trakt history): `show:<tk>`.
String showKey(String rawName) => 'show:${titleKey(rawName)}';

/// One episode: `<tk>|s{n}e{n}`.
String epKey(String rawShowName, int season, int episode) =>
    '${titleKey(rawShowName)}|s${season}e$episode';

/// Portable identity of an IPTV source (playlists.id is a local
/// AUTOINCREMENT and means nothing on another device).
String sourceKeyFor({
  required bool isXtream,
  required String url,
  String? username,
  bool debridSentinel = false,
}) {
  if (debridSentinel) return 'debrid';
  if (isXtream) {
    final u = Uri.tryParse(url);
    return 'xt:${u?.host ?? url}:${u?.port ?? 0}:${username ?? ''}';
  }
  return 'm3u:$url';
}

/// Xtream live urls are `/live/<user>/<pass>/<id>.<ext>` — key on the id so
/// credentials never enter a key that reaches the server.
final _xtLive = RegExp(r'/live/[^/]+/[^/]+/(\d+)\.');

/// Identity of a live channel for favorites. Prefers the EPG id (stable
/// across providers), then the Xtream stream id, then the raw url.
String liveFavKeyFor({String? tvgId, required String url}) {
  if (tvgId != null && tvgId.isNotEmpty) return 'live:tvg:$tvgId';
  final m = _xtLive.firstMatch(url);
  if (m != null) return 'live:xt:${m.group(1)}';
  return 'live:url:$url';
}
