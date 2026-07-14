import '../ui/title_utils.dart';
import 'models/models.dart';

/// In-memory title → library-item index over the active source's movies and
/// series.
///
/// Every discovery surface (TMDB trending/popular/genre rows, Trakt
/// continue-watching / watched-history reconciliation, recommendations, the
/// browse pager) needs "does the library carry this title?". Doing that as a
/// per-title SQL search was 150–300 serial queries per home load — and on
/// Android TV boxes without FTS5 each one is a LIKE scan over the whole 40k-row
/// streams table, all funnelled through sqflite's single connection (so they
/// also queue behind a running playlist re-sync). That was the minutes-long
/// "home is stuck" stall.
///
/// This index is built from ONE query (see [LibraryRepository.vodItems]) and
/// answers matches from memory. Rebuilt when the playlist re-syncs.
class TitleIndex {
  TitleIndex._(this.playlistId, this._byNorm, this._byNormLoose);

  final int playlistId;

  /// Normalised clean title → items carrying that title (English-labelled
  /// entries first, so `.first`-style picks keep the preferEnglish behaviour).
  final Map<String, List<StreamItem>> _byNorm;

  /// Secondary buckets keyed with a bare trailing year stripped — providers
  /// often name items "The Matrix 1999" (no parens, so cleanTitle keeps it),
  /// which the old substring SQL search still matched. Consulted only when
  /// the exact key misses, so "Blade Runner 2049" never shadows an exact hit.
  final Map<String, List<StreamItem>> _byNormLoose;

  static final _nonAlnum = RegExp(r'[^a-z0-9]');
  static final _trailingYear = RegExp(r'(19|20)\d{2}$');

  /// Loose key: display-cleaned (provider prefixes/quality tags/year stripped),
  /// lower-cased, alphanumerics only — "EN - The Matrix (1999) [1080p]" and
  /// TMDB's "The Matrix" both become "thematrix".
  static String normalize(String raw) =>
      cleanTitle(raw).title.toLowerCase().replaceAll(_nonAlnum, '');

  /// The key with a bare trailing year removed, or null when there isn't one
  /// (or stripping it would leave nothing, e.g. a movie literally named 2012).
  static String? _stripYear(String key) {
    final m = _trailingYear.firstMatch(key);
    if (m == null || m.start == 0) return null;
    return key.substring(0, m.start);
  }

  /// Build from the library's VOD rows. Top-level-callable so it can run via
  /// `compute()` — normalising tens of thousands of names off the UI thread.
  static TitleIndex build((int, List<StreamItem>) args) {
    final (playlistId, items) = args;
    final map = <String, List<StreamItem>>{};
    final loose = <String, List<StreamItem>>{};
    for (final it in items) {
      final k = normalize(it.name);
      if (k.isEmpty) continue;
      (map[k] ??= []).add(it);
      final stripped = _stripYear(k);
      if (stripped != null) (loose[stripped] ??= []).add(it);
    }
    // English-labelled entries first within each bucket (stable otherwise).
    final en = RegExp(r'^\s*(en|eng|english)\b', caseSensitive: false);
    void sortBuckets(Map<String, List<StreamItem>> m) {
      for (final bucket in m.values) {
        if (bucket.length > 1) {
          bucket.sort((a, b) {
            final ae = en.hasMatch(a.name) ? 0 : 1;
            final be = en.hasMatch(b.name) ? 0 : 1;
            return ae - be;
          });
        }
      }
    }

    sortBuckets(map);
    sortBuckets(loose);
    return TitleIndex._(playlistId, map, loose);
  }

  List<StreamItem> _bucketFor(String title) {
    final k = normalize(title);
    if (k.isEmpty) return const [];
    // Exact first; then leading-article tolerance ("The Office" ↔ "Office");
    // then year-stripped variants on either side, article-tolerant too.
    final the = k.startsWith('the') && k.length > 3 ? k.substring(3) : 'the$k';
    final bare = _stripYear(k);
    return _byNorm[k] ??
        _byNorm[the] ??
        _byNormLoose[k] ??
        _byNormLoose[the] ??
        (bare != null ? _byNorm[bare] ?? _byNormLoose[bare] : null) ??
        const [];
  }

  /// Best library match for a discovery title (English-preferred), optionally
  /// constrained to one kind. Null when the library doesn't carry it.
  StreamItem? match(String title, {StreamKind? kind}) {
    for (final it in _bucketFor(title)) {
      if (kind == null || it.kind == kind) return it;
    }
    return null;
  }

  /// EVERY library entry carrying this title (language/quality/provider
  /// variants), English-labelled first. The series screen merges episode
  /// lists across these so a show isn't stuck with whichever variant happens
  /// to have the fewest seasons.
  List<StreamItem> matches(String title, {StreamKind? kind}) => [
        for (final it in _bucketFor(title))
          if (kind == null || it.kind == kind) it,
      ];

  /// Movie-or-series match (the old repo.findByTitle contract) — used for
  /// Trakt title reconciliation where the type isn't always trustworthy.
  StreamItem? matchVod(String title) => match(title);
}
