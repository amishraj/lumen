import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../data/sources/omdb_service.dart';
import '../../../data/sources/tmdb_service.dart';
import '../../../state/providers.dart';
import '../../theme/lumen_theme.dart';
import '../../title_utils.dart';
import '../../widgets/focusable_item.dart';
import '../../widgets/imdb_badge.dart';
import '../../widgets/logo_image.dart';
import '../../widgets/rating_badges.dart';
import '../player/player_screen.dart';

/// Shows a series' seasons & episodes. Episodes come from the Xtream panel;
/// canonical names / descriptions / stills / ratings are overlaid from TMDB
/// (provider episode titles are often wrong or missing).
class SeriesDetailScreen extends ConsumerStatefulWidget {
  const SeriesDetailScreen({
    super.key,
    required this.playlist,
    required this.series,
  });

  final Playlist playlist;
  final StreamItem series; // url holds the series_id

  @override
  ConsumerState<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends ConsumerState<SeriesDetailScreen> {
  late Future<List<Episode>> _future;
  int _season = 1;

  /// TMDB corrections gathered so far, keyed by (season, episode). Grows as
  /// the user browses seasons; used for both the list AND the play queue so
  /// the player shows canonical names too.
  final Map<(int, int), TmdbEpisode> _tmdb = {};

  String get _showTitle => cleanTitle(widget.series.name).title;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Episode>> _load() async {
    final repo = await ref.read(repositoryProvider.future);
    return repo.seriesEpisodes(widget.playlist, widget.series.url);
  }

  /// Canonical episode title: TMDB name when known, else the cleaned
  /// provider title.
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

  /// Plays [ep] with the whole series as a queue so the player can skip between
  /// episodes.
  void _play(List<Episode> all, Episode ep) {
    final queue = all.map(_toItem).toList();
    final index = all.indexOf(ep);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        item: queue[index < 0 ? 0 : index],
        queue: queue,
        startIndex: index < 0 ? 0 : index,
        // Structured identity so the in-player source switch can look up
        // Real-Debrid streams for the exact episode.
        debrid: DebridContext(
          title: widget.series.name,
          isShow: true,
          episodes: [for (final e in all) (e.season, e.episode)],
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    // Crisp wide TMDB backdrop for the banner (provider art is usually a
    // low-res poster that upscales badly).
    final tmdbShow = ref
        .watch(tmdbDetailProvider((title: widget.series.name, isShow: true)))
        .valueOrNull;
    final banner = tmdbShow?.backdrop ?? widget.series.logo;

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
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 380,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              titlePadding:
                  const EdgeInsets.only(left: 56, right: 16, bottom: 14),
              title: Text(_showTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, letterSpacing: -0.3)),
              background: Stack(
                fit: StackFit.expand,
                children: [
                  LogoImage(
                      url: banner,
                      size: 1400,
                      height: 380,
                      radius: 0,
                      fallbackText: widget.series.name),
                  // Cinematic bottom fade for the title + info.
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Color(0x660A0B0F),
                          Color(0xF20A0B0F),
                        ],
                        stops: [0.35, 0.75, 1],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                // Narrower content column reads better on wide screens.
                constraints: const BoxConstraints(maxWidth: 760),
                child: Consumer(builder: (context, ref, _) {
                  final info =
                      ref.watch(omdbProvider(widget.series.name)).valueOrNull;
                  final overview = info?.plot ?? tmdbShow?.overview;
                  if (info == null && overview == null) {
                    return const SizedBox(height: 8);
                  }
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        RatingBadges(info: info),
                        if (overview != null) ...[
                          const SizedBox(height: 12),
                          Text(overview,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 13.5,
                                  height: 1.5,
                                  color: Color(0xFFC7CBD6))),
                        ],
                      ],
                    ),
                  );
                }),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: FutureBuilder<List<Episode>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snap.hasError) {
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Could not load episodes: ${snap.error}'),
                  );
                }
                final eps = snap.data ?? [];
                if (eps.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No episodes found for this series.'),
                  );
                }
                final seasons = eps.map((e) => e.season).toSet().toList()
                  ..sort();
                if (!seasons.contains(_season)) _season = seasons.first;
                final inSeason = eps.where((e) => e.season == _season).toList();

                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 16),
                        SizedBox(
                          height: 48,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            clipBehavior: Clip.none,
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            itemCount: seasons.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 8),
                            itemBuilder: (_, i) {
                              final s = seasons[i];
                              final sel = s == _season;
                              return FocusableItem(
                                borderRadius: 30,
                                autofocus: i == 0,
                                onActivate: () => setState(() => _season = s),
                                builder: (context, focused) => Container(
                                  alignment: Alignment.center,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 18),
                                  decoration: BoxDecoration(
                                    color: sel
                                        ? LumenTheme.accent
                                        : LumenTheme.surfaceHi,
                                    borderRadius: BorderRadius.circular(30),
                                  ),
                                  child: Text('Season $s',
                                      style: TextStyle(
                                          color: sel
                                              ? const Color(0xFF0A0B0F)
                                              : Colors.white,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13)),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 12),
                        for (final ep in inSeason)
                          _EpisodeCard(
                            episode: ep,
                            meta: _tmdb[(ep.season, ep.episode)],
                            title: _titleFor(ep),
                            fallbackArt: widget.series.logo,
                            onPlay: () => _play(eps, ep),
                          ),
                        const SizedBox(height: 28),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// One episode: large 16:9 still, canonical name, per-episode IMDb-style
/// rating and a two-line description.
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

    return FocusableItem(
      borderRadius: 16,
      onActivate: onPlay,
      builder: (context, focused) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: focused ? LumenTheme.surfaceHi : LumenTheme.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                LogoImage(
                    url: art,
                    size: 168,
                    height: 94,
                    radius: 10,
                    fallbackText: title),
                // Subtle play affordance over the still when focused/hovered.
                Positioned.fill(
                  child: AnimatedOpacity(
                    opacity: focused ? 1 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black38,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.play_circle_fill,
                          color: Colors.white, size: 36),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'E${episode.episode} · $title',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 14),
                        ),
                      ),
                      if (rating != null && rating > 0) ...[
                        const SizedBox(width: 8),
                        ImdbBadge(rating: rating),
                      ],
                    ],
                  ),
                  const SizedBox(height: 5),
                  if (overview != null)
                    Text(
                      overview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, height: 1.45, color: Color(0xFF9AA0B0)),
                    ),
                  if (episode.durationSecs != null) ...[
                    const SizedBox(height: 6),
                    Text('${(episode.durationSecs! / 60).round()} min',
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF6B7080))),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
