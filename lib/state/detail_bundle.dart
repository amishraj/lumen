import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/sources/omdb_service.dart';
import '../data/sources/tmdb_service.dart';

/// Everything a detail surface needs, fetched in parallel and delivered as
/// ONE result — so the UI updates once instead of OMDb ratings, TMDB art and
/// the synopsis popping in piecemeal (which read as "reloads/refreshes").
class DetailBundle {
  final OmdbInfo? omdb;
  final TmdbInfo? tmdb;
  const DetailBundle({this.omdb, this.tmdb});

  String? get overview => omdb?.plot ?? tmdb?.overview;
  String? get backdrop => tmdb?.backdrop ?? omdb?.poster;
  double? get rating {
    final imdb = double.tryParse(omdb?.imdb ?? '');
    return imdb ?? tmdb?.rating;
  }
}

final detailBundleProvider = FutureProvider.autoDispose
    .family<DetailBundle, ({String title, bool isShow})>((ref, args) async {
  // Both lookups are DB-cached after first fetch, so re-entry is instant.
  final results = await Future.wait<Object?>([
    ref.watch(omdbProvider(args.title).future).catchError((Object _) => null),
    ref.watch(tmdbDetailProvider(args).future).catchError((Object _) => null),
  ]);
  return DetailBundle(
    omdb: results[0] as OmdbInfo?,
    tmdb: results[1] as TmdbInfo?,
  );
});
