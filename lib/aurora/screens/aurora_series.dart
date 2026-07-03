import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../data/repositories/library_repository.dart';
import '../../data/sources/tmdb_service.dart';
import '../../state/detail_bundle.dart';
import '../../state/providers.dart';
import '../../ui/title_utils.dart';
import '../aurora_focus.dart';
import '../aurora_theme.dart';
import '../player/aurora_player.dart';
import '../widgets/aurora_badges.dart';
import '../widgets/aurora_buttons.dart';
import '../widgets/aurora_image.dart';

/// Series page: cinematic header, a horizontal season selector, then large
/// episode cards. Episode names/stills/ratings are overlaid from TMDB as
/// they resolve (provider episode titles are frequently wrong or missing).
class AuroraSeriesScreen extends ConsumerStatefulWidget {
  const AuroraSeriesScreen({
    super.key,
    required this.playlist,
    required this.series,
  });

  final Playlist playlist;
  final StreamItem series; // url holds the series_id

  @override
  ConsumerState<AuroraSeriesScreen> createState() =>
      _AuroraSeriesScreenState();
}

class _AuroraSeriesScreenState extends ConsumerState<AuroraSeriesScreen> {
  late Future<List<Episode>> _future;
  int _season = 1;

  /// TMDB corrections gathered so far, keyed by (season, episode). Used for
  /// the list AND the play queue so the player shows canonical names too.
  final Map<(int, int), TmdbEpisode> _tmdb = {};

  String get _showTitle => cleanTitle(widget.series.name).title;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Episode>> _load() async {
    final repo = await ref.read(repositoryProvider.future);
    // A TMDB-catalog series carries no Xtream series_id (url is empty) — resolve
    // the English-preferred library match by title to find its episodes.
    var seriesUrl = widget.series.url;
    if (seriesUrl.isEmpty && widget.playlist.id != null) {
      final hits = await repo.search(
          playlistId: widget.playlist.id!,
          kind: StreamKind.series,
          query: _showTitle);
      seriesUrl = LibraryRepository.preferEnglish(hits)?.url ?? '';
    }
    if (seriesUrl.isEmpty) return const [];
    return repo.seriesEpisodes(widget.playlist, seriesUrl);
  }

  String _titleFor(Episode ep) {
    final t = _tmdb[(ep.season, ep.episode)];
    if (t != null && t.name.trim().isNotEmpty) return t.name;
    return cleanTitle(ep.title).title;
  }

  StreamItem _toItem(Episode ep) => StreamItem(
        playlistId: widget.playlist.id!,
        kind: StreamKind.series,
        name: 'S${ep.season}E${ep.episode} · ${_titleFor(ep)}',
        url: ep.url,
        logo: _tmdb[(ep.season, ep.episode)]?.still ??
            ep.still ??
            widget.series.logo,
      );

  void _play(List<Episode> all, Episode ep) {
    final queue = all.map(_toItem).toList();
    final index = all.indexOf(ep);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AuroraPlayerScreen(
        item: queue[index < 0 ? 0 : index],
        queue: queue,
        startIndex: index < 0 ? 0 : index,
        playContext: AuroraPlayContext(
          title: widget.series.name,
          isShow: true,
          episodes: [for (final e in all) (e.season, e.episode)],
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final margin = Aurora.margin(context);
    final heroH = (size.height * 0.56).clamp(340.0, 600.0);

    final bundle = ref
        .watch(detailBundleProvider((title: widget.series.name, isShow: true)))
        .valueOrNull;
    final tmdbShow = bundle?.tmdb;
    final info = bundle?.omdb;
    final banner = tmdbShow?.backdrop ?? widget.series.logo;
    final overview = info?.plot ?? tmdbShow?.overview;
    final favs = ref.watch(favoriteIdsProvider).valueOrNull ?? const <int>{};
    final isFav =
        widget.series.id != null && favs.contains(widget.series.id);

    // Merge this season's TMDB episode metadata as it arrives.
    final seasonMeta = ref
        .watch(tmdbSeasonProvider((title: _showTitle, season: _season)))
        .valueOrNull;
    if (seasonMeta != null) {
      for (final e in seasonMeta.values) {
        _tmdb[(_season, e.number)] = e;
      }
    }

    return Scaffold(
      backgroundColor: Aurora.bg,
      body: CustomScrollView(slivers: [
        SliverToBoxAdapter(
          child: SizedBox(
            height: heroH,
            child: Stack(fit: StackFit.expand, children: [
              AuroraImage(
                url: banner,
                width: size.width,
                height: heroH,
                radius: 0,
                fallbackText: _showTitle,
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xFF06070B), Color(0x0006070B)],
                    stops: [0.0, 0.62],
                  ),
                ),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0xC706070B), Color(0x0006070B)],
                    stops: [0.0, 0.6],
                  ),
                ),
              ),
              Positioned(
                top: 18,
                left: margin - 8,
                child: SafeArea(
                  child: AuroraIconButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ),
              Positioned(
                left: margin,
                right: margin,
                bottom: 24,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Eyebrow('Series'),
                    const SizedBox(height: 8),
                    Text(_showTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Aurora.display.copyWith(fontSize: 36)),
                    const SizedBox(height: 12),
                    Row(children: [
                      RatingsStrip(
                          info: info, fallbackRating: widget.series.rating),
                      const SizedBox(width: 14),
                      AuroraPillButton(
                        label: isFav ? 'In My List' : 'My List',
                        icon:
                            isFav ? Icons.check_rounded : Icons.add_rounded,
                        compact: true,
                        onPressed: () =>
                            setFavorite(ref, widget.series, !isFav),
                      ),
                    ]),
                    if (overview != null) ...[
                      const SizedBox(height: 12),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
                        child: Text(overview,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: Aurora.body),
                      ),
                    ],
                  ],
                ),
              ),
            ]),
          ),
        ),
        SliverToBoxAdapter(
          child: FutureBuilder<List<Episode>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(48),
                  child: Center(
                      child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2))),
                );
              }
              if (snap.hasError) {
                return Padding(
                  padding: EdgeInsets.all(margin),
                  child: Text('Could not load episodes: ${snap.error}',
                      style: const TextStyle(color: Aurora.textDim)),
                );
              }
              final eps = snap.data ?? const <Episode>[];
              if (eps.isEmpty) {
                return Padding(
                  padding: EdgeInsets.all(margin),
                  child: const Text('No episodes found for this series.',
                      style: TextStyle(color: Aurora.textFaint)),
                );
              }
              final seasons = eps.map((e) => e.season).toSet().toList()
                ..sort();
              if (!seasons.contains(_season)) _season = seasons.first;
              final inSeason =
                  eps.where((e) => e.season == _season).toList();

              return Padding(
                padding:
                    EdgeInsets.symmetric(horizontal: margin, vertical: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Season selector — a focusable chip rail.
                    SizedBox(
                      height: 42,
                      child: FocusTraversalGroup(
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          clipBehavior: Clip.none,
                          itemCount: seasons.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(width: 8),
                          itemBuilder: (context, i) {
                            final s = seasons[i];
                            final sel = s == _season;
                            return AuroraFocusable(
                              ring: false,
                              scale: 1.0,
                              autofocus: i == 0,
                              onActivate: () =>
                                  setState(() => _season = s),
                              builder: (context, focused) =>
                                  AnimatedContainer(
                                duration: Aurora.fast,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 8),
                                decoration: BoxDecoration(
                                  color: focused
                                      ? Colors.white
                                      : (sel
                                          ? Aurora.glassHi
                                          : Aurora.glass),
                                  borderRadius: BorderRadius.circular(20),
                                  border:
                                      Border.all(color: Aurora.hairline),
                                ),
                                child: Text('Season $s',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: sel || focused
                                            ? FontWeight.w800
                                            : FontWeight.w600,
                                        color: focused
                                            ? Aurora.bg
                                            : (sel
                                                ? Aurora.text
                                                : Aurora.textDim))),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 860),
                      child: Column(children: [
                        for (final ep in inSeason)
                          _EpisodeCard(
                            episode: ep,
                            meta: _tmdb[(ep.season, ep.episode)],
                            title: _titleFor(ep),
                            fallbackArt: widget.series.logo,
                            onPlay: () => _play(eps, ep),
                          ),
                      ]),
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}

/// One episode: large 16:9 still with play affordance, canonical name,
/// rating and a two-line synopsis.
class _EpisodeCard extends StatelessWidget {
  const _EpisodeCard({
    required this.episode,
    required this.meta,
    required this.title,
    required this.fallbackArt,
    required this.onPlay,
  });

  final Episode episode;
  final TmdbEpisode? meta;
  final String title;
  final String? fallbackArt;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final art = meta?.still ?? episode.still ?? fallbackArt;
    final overview = meta?.overview ?? episode.plot;
    final rating = meta?.rating;

    return AuroraFocusable(
      radius: 16,
      scale: 1.015,
      onActivate: onPlay,
      builder: (context, focused) => AnimatedContainer(
        duration: Aurora.fast,
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: focused ? Aurora.glassHi : Aurora.glass,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Aurora.hairline),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(children: [
            AuroraImage(
              url: art,
              width: 196,
              height: 110,
              radius: 10,
              fallbackText: title,
            ),
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: focused ? 1 : 0,
                duration: Aurora.fast,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0x59000000),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.play_circle_fill_rounded,
                      color: Colors.white, size: 42),
                ),
              ),
            ),
          ]),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 2),
                Row(children: [
                  Expanded(
                    child: Text(
                      'E${episode.episode} · $title',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14.5),
                    ),
                  ),
                  if (rating != null && rating > 0) ...[
                    const SizedBox(width: 8),
                    ImdbChip(rating),
                  ],
                ]),
                const SizedBox(height: 6),
                if (overview != null)
                  Text(
                    overview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: Aurora.textDim),
                  ),
                if (episode.durationSecs != null) ...[
                  const SizedBox(height: 7),
                  Text('${(episode.durationSecs! / 60).round()} min',
                      style: Aurora.caption),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
