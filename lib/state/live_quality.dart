/// Heuristics for IPTV channel quality variants.
///
/// Xtream live channels are single fixed-bitrate feeds — there is no ABR
/// ladder inside one stream, so the player can't "lower the quality" of the
/// URL it is already playing. What providers do instead is list the same
/// channel several times at different qualities ("ESPN 4K", "ESPN FHD",
/// "ESPN HD", "ESPN"). These helpers parse that naming convention so the
/// player can fall back to a lighter sibling feed when the connection can't
/// keep up with the current one.
library;

import '../data/models/models.dart';

/// Quality implied by a channel name: 4 = 4K/UHD · 3 = FHD/1080 ·
/// 2 = HD/720 · 1 = SD/480 · 0 = unmarked (often the provider's SD feed).
int liveQualityRank(String name) {
  final n = name.toLowerCase();
  bool has(String pat) => RegExp('\\b(?:$pat)\\b').hasMatch(n);
  if (has(r'4k|uhd|2160p?')) return 4;
  if (has(r'fhd|fullhd|1080p?')) return 3;
  if (has(r'hd|720p?|hq')) return 2;
  if (has(r'sd|480p?|576p?|lq')) return 1;
  return 0;
}

/// Tokens stripped when reducing a channel name to its base identity —
/// quality markers plus codec/fps noise that varies between variants.
final _qualityNoise = RegExp(
  r'\b(?:4k|uhd|2160p?|fhd|fullhd|1080p?|hd|720p?|hq|sd|480p?|576p?|lq|'
  r'hevc|h\.?26[45]|raw|50\s?fps|60\s?fps)\b',
  caseSensitive: false,
);

/// "US| ESPN FHD (HEVC)" and "US| ESPN HD" both reduce to "us espn", so
/// they compare equal as the same underlying channel.
String liveBaseName(String name) => name
    .toLowerCase()
    .replaceAll(_qualityNoise, ' ')
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// The best sibling of [current] that is *below* its quality — i.e. the
/// gentlest possible downgrade. Returns null when [current] is already
/// SD/unmarked or no lower variant exists in [candidates].
StreamItem? pickLowerQualityVariant(
    StreamItem current, Iterable<StreamItem> candidates) {
  final base = liveBaseName(current.name);
  if (base.isEmpty) return null;
  final rank = liveQualityRank(current.name);
  if (rank <= 1) return null; // nothing lighter to offer

  StreamItem? best;
  var bestRank = -1;
  for (final c in candidates) {
    if (c.kind != StreamKind.live || c.playlistId != current.playlistId) {
      continue;
    }
    if (c.url == current.url || (c.id != null && c.id == current.id)) continue;
    if (liveBaseName(c.name) != base) continue;
    final r = liveQualityRank(c.name);
    if (r >= rank) continue; // equal or higher — not a downgrade
    if (r > bestRank) {
      best = c;
      bestRank = r;
    } else if (r == bestRank &&
        best != null &&
        c.groupTitle == current.groupTitle &&
        best.groupTitle != current.groupTitle) {
      best = c; // tie-break: stay in the same category
    }
  }
  return best;
}
