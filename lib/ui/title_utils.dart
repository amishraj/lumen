/// Display-side cleanup of raw IPTV item names. Providers ship titles like
/// "02 - The Godfather - 1972 [MULTI-SUB]" or "EN - Vivarium [MULTI-SUB]";
/// on cards we want the *real* title, with the language surfaced as a small
/// chip instead of baked into the text. Purely cosmetic — matching/lookup
/// logic keeps using the raw names.
class TitleParts {
  final String title;
  final String? lang; // e.g. "EN" — null when no language tag was present
  const TitleParts(this.title, this.lang);
}

final _langPrefix =
    RegExp(r'^\s*([A-Z]{2,3})\s*[|:\-–]\s+', caseSensitive: true);
final _indexPrefix = RegExp(r'^\s*\d{1,4}\s*[-.]\s*');
final _bracketTags = RegExp(r'\s*[\[(][^\])]*[\])]');
final _trailingYear = RegExp(r'\s*[-–]\s*(19|20)\d{2}\s*$');
final _qualityTokens = RegExp(
    r'\b(4k|uhd|fhd|hd|sd|hevc|x26[45]|2160p|1080p|720p|480p|multi(-?sub)?|vip|dubbed|sub(bed)?)\b',
    caseSensitive: false);
final _spaces = RegExp(r'\s{2,}');

TitleParts cleanTitle(String raw) {
  var s = raw.trim();
  String? lang;

  // Order matters: index first ("02 - EN - Title"), then the language tag.
  s = s.replaceFirst(_indexPrefix, '');
  final lm = _langPrefix.firstMatch(s);
  if (lm != null) {
    lang = lm.group(1);
    s = s.substring(lm.end);
  }
  s = s
      .replaceAll(_bracketTags, '')
      .replaceAll(_qualityTokens, '')
      .replaceFirst(_trailingYear, '')
      .replaceAll(_spaces, ' ')
      .trim();
  // Never render an empty title — fall back to the raw name.
  return TitleParts(s.isEmpty ? raw.trim() : s, lang);
}
