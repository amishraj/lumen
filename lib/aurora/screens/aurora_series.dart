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

/// Series page: cinematic header, a season selector, then large episode cards.
///
/// Watch state is tracked per episode (title + S/E, so it survives IPTV↔Debrid
/// switches): watched episodes are clearly marked, an in-progress episode shows
/// a resume overlay with its percent, and opening the show jumps you straight
/// to the next episode to watch — in the right season — with a Resume shortcut.
class AuroraSeriesScreen extends ConsumerStatefulWidget {
  const AuroraSeriesScreen({
    super.key,
    required this.playlist,
    required this.series,
  });

  final Playlist playlist;
  final StreamItem series; // url holds the series_id (may be empty for TMDB)

  @override
  ConsumerState<AuroraSeriesScreen> createState() =>
      _AuroraSeriesScreenState();
}

class _AuroraSeriesScreenState extends ConsumerState<AuroraSeriesScreen> {
  late Future<List<Episode>> _future;
  int _season = 1;
  bool _seasonChosen = false; // resume season applied once

  final _scroll = ScrollController();
  final GlobalKey _resumeCardKey = GlobalKey();
  bool _scrolledToResume = false;

  /// ep_key → progress, refreshed on entry and whenever we return from playback.
  Map<String, ({double fraction, bool watched, int updatedAt})> _prog = {};

  /// TMDB corrections gathered so far, keyed by (season, episode).
  final Map<(int, int), TmdbEpisode> _tmdb = {};

  /// (season, episode) pairs Trakt reports as watched — merged with local
  /// progress so episodes seen on another device still show a check.
  Set<(int, int)> _traktWatched = const {};

  String get _showTitle => cleanTitle(widget.series.name).title;

  @override
  void initState() {
    super.initState();
    _future = _load();
    _loadProgress();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadProgress() async {
    final repo = await ref.read(repositoryProvider.future);
    final p = await repo.db.episodeProgressAll();
    if (mounted) setState(() => _prog = p);
  }

  Future<List<Episode>> _load() async {
    final repo = await ref.read(repositoryProvider.future);
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

  ({double fraction, bool watched, int updatedAt})? _progFor(Episode e) =>
      _prog[episodeKey(_showTitle, e.season, e.episode)];

  /// Watched if local progress says so, or Trakt has it in the show's history.
  bool _isWatched(Episode e) =>
      (_progFor(e)?.watched ?? false) ||
      _traktWatched.contains((e.season, e.episode));

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

  Future<void> _play(List<Episode> all, Episode ep) async {
    final queue = all.map(_toItem).toList();
    final index = all.indexOf(ep);
    await Navigator.of(context).push(MaterialPageRoute(
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
    // Refresh seen/continue marks after watching.
    await _loadProgress();
  }

  /// The next episode to watch: an in-progress one (latest touched) first, else
  /// the first unwatched after the last watched. Null when nothing's started.
  Episode? _resumeEpisode(List<Episode> eps) {
    Episode? best;
    var bestTs = -1;
    for (final e in eps) {
      final p = _progFor(e);
      if (p != null &&
          !p.watched &&
          p.fraction > 0.02 &&
          p.fraction < 0.97 &&
          p.updatedAt > bestTs) {
        best = e;
        bestTs = p.updatedAt;
      }
    }
    if (best != null) return best;
    final sorted = [...eps]..sort((a, b) =>
        a.season != b.season ? a.season - b.season : a.episode - b.episode);
    var lastWatched = -1;
    for (var i = 0; i < sorted.length; i++) {
      if (_isWatched(sorted[i])) lastWatched = i;
    }
    if (lastWatched >= 0 && lastWatched < sorted.length - 1) {
      return sorted[lastWatched + 1];
    }
    return null;
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

    final seasonMeta = ref
        .watch(tmdbSeasonProvider((title: _showTitle, season: _season)))
        .valueOrNull;
    if (seasonMeta != null) {
      for (final e in seasonMeta.values) {
        _tmdb[(_season, e.number)] = e;
      }
    }

    final traktWatched =
        ref.watch(traktWatchedEpisodesProvider(_showTitle)).valueOrNull;
    if (traktWatched != null) _traktWatched = traktWatched;

    return Scaffold(
      backgroundColor: Aurora.bg,
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(
              height: heroH,
              child: Stack(fit: StackFit.expand, children: [
                _FadedImage(url: banner, width: size.width, height: heroH,
                    title: _showTitle),
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
                  child: FutureBuilder<List<Episode>>(
                    future: _future,
                    builder: (context, snap) {
                      final eps = snap.data ?? const <Episode>[];
                      final resume = eps.isEmpty ? null : _resumeEpisode(eps);
                      return Column(
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
                                info: info,
                                fallbackRating: widget.series.rating),
                            const SizedBox(width: 14),
                            if (resume != null)
                              AuroraPillButton(
                                label:
                                    'Resume S${resume.season} · E${resume.episode}',
                                icon: Icons.play_arrow_rounded,
                                primary: true,
                                compact: true,
                                onPressed: () => _play(eps, resume),
                              ),
                            const SizedBox(width: 10),
                            AuroraPillButton(
                              label: isFav ? 'In My List' : 'My List',
                              icon: isFav
                                  ? Icons.check_rounded
                                  : Icons.add_rounded,
                              compact: true,
                              onPressed: () =>
                                  setFavorite(ref, widget.series, !isFav),
                            ),
                          ]),
                          if (overview != null) ...[
                            const SizedBox(height: 12),
                            ConstrainedBox(
                              constraints:
                                  const BoxConstraints(maxWidth: 640),
                              child: Text(overview,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: Aurora.body),
                            ),
                          ],
                        ],
                      );
                    },
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
                            child:
                                CircularProgressIndicator(strokeWidth: 2))),
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

                // Jump to the resume episode's season on first load.
                final resume = _resumeEpisode(eps);
                if (!_seasonChosen) {
                  _seasonChosen = true;
                  _season = resume?.season ?? seasons.first;
                }
                if (!seasons.contains(_season)) _season = seasons.first;
                final inSeason =
                    eps.where((e) => e.season == _season).toList();

                // Scroll to the resume card once, if it's in this season.
                final resumeHere = resume != null && resume.season == _season;
                if (!_scrolledToResume && resumeHere) {
                  _scrolledToResume = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    final ctx = _resumeCardKey.currentContext;
                    if (ctx != null) {
                      Scrollable.ensureVisible(ctx,
                          duration: const Duration(milliseconds: 420),
                          curve: Curves.easeOutCubic,
                          alignment: 0.25);
                    }
                  });
                }

                return Padding(
                  padding:
                      EdgeInsets.symmetric(horizontal: margin, vertical: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SeasonRail(
                        seasons: seasons,
                        selected: _season,
                        onPick: (s) => setState(() {
                          _season = s;
                          _scrolledToResume = true; // manual pick — don't yank
                        }),
                      ),
                      const SizedBox(height: 16),
                      // Centre the episode column rather than hugging the left
                      // edge — it reads as a deliberate, focused reel on wide TV
                      // screens.
                      Center(
                        child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 860),
                        child: Column(children: [
                          for (final ep in inSeason)
                            _EpisodeCard(
                              key: (resume != null &&
                                      ep.season == resume.season &&
                                      ep.episode == resume.episode)
                                  ? _resumeCardKey
                                  : ValueKey('ep-${ep.season}-${ep.episode}'),
                              episode: ep,
                              meta: _tmdb[(ep.season, ep.episode)],
                              title: _titleFor(ep),
                              fallbackArt: widget.series.logo,
                              progress: _progFor(ep),
                              watched: _isWatched(ep),
                              isResume: resume != null &&
                                  ep.season == resume.season &&
                                  ep.episode == resume.episode,
                              onPlay: () => _play(eps, ep),
                            ),
                        ]),
                      ),
                      ),
                      const SizedBox(height: 40),
                    ],
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

/// Backdrop with a ShaderMask fade so its bottom dissolves into the page —
/// no hard seam where the artwork ends.
class _FadedImage extends StatelessWidget {
  const _FadedImage({
    required this.url,
    required this.width,
    required this.height,
    required this.title,
  });
  final String? url;
  final double width;
  final double height;
  final String title;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.white, Colors.white, Colors.transparent],
        stops: [0.0, 0.55, 0.98],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: AuroraImage(
        url: url,
        width: width,
        height: height,
        radius: 0,
        fallbackText: title,
      ),
    );
  }
}

class _SeasonRail extends StatelessWidget {
  const _SeasonRail({
    required this.seasons,
    required this.selected,
    required this.onPick,
  });
  final List<int> seasons;
  final int selected;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: FocusTraversalGroup(
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          itemCount: seasons.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final s = seasons[i];
            final sel = s == selected;
            return AuroraFocusable(
              ring: false,
              scale: 1.0,
              autofocus: sel,
              onActivate: () => onPick(s),
              builder: (context, focused) => AnimatedContainer(
                duration: Aurora.fast,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: focused
                      ? Colors.white
                      : (sel ? Aurora.glassHi : Aurora.glass),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Aurora.hairline),
                ),
                child: Text('Season $s',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: sel || focused
                            ? FontWeight.w800
                            : FontWeight.w600,
                        color: focused
                            ? Aurora.bg
                            : (sel ? Aurora.text : Aurora.textDim))),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// One episode: 16:9 still with seen/resume treatment, canonical name,
/// rating and a two-line synopsis.
class _EpisodeCard extends StatelessWidget {
  const _EpisodeCard({
    super.key,
    required this.episode,
    required this.meta,
    required this.title,
    required this.fallbackArt,
    required this.progress,
    required this.watched,
    required this.isResume,
    required this.onPlay,
  });

  final Episode episode;
  final TmdbEpisode? meta;
  final String title;
  final String? fallbackArt;
  final ({double fraction, bool watched, int updatedAt})? progress;

  /// Seen — from local progress *or* Trakt history.
  final bool watched;
  final bool isResume;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final art = meta?.still ?? episode.still ?? fallbackArt;
    final overview = meta?.overview ?? episode.plot;
    final rating = meta?.rating;
    final frac = progress?.fraction ?? 0;
    final inProgress = !watched && frac > 0.02 && frac < 0.97;

    return AuroraFocusable(
      radius: 16,
      scale: 1.015,
      autofocus: isResume,
      onActivate: onPlay,
      builder: (context, focused) => AnimatedContainer(
        duration: Aurora.fast,
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: focused ? Aurora.glassHi : Aurora.glass,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: isResume && !focused
                  ? const Color(0x554CC2FF)
                  : Aurora.hairline),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(children: [
            Opacity(
              opacity: watched ? 0.55 : 1,
              child: AuroraImage(
                url: art,
                width: 196,
                height: 110,
                radius: 10,
                fallbackText: title,
              ),
            ),
            // Play affordance on focus.
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
            // Watched check (SeenBadge positions itself within the Stack).
            if (watched) const SeenBadge(),
            // Resume progress overlay along the bottom of the still.
            if (inProgress)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    borderRadius:
                        BorderRadius.vertical(bottom: Radius.circular(10)),
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Color(0xCC000000), Color(0x00000000)],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${(frac * 100).round()}% watched',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: SizedBox(
                          height: 3,
                          child: Stack(children: [
                            Container(color: const Color(0x40FFFFFF)),
                            FractionallySizedBox(
                              widthFactor: frac,
                              child: const DecoratedBox(
                                  decoration:
                                      BoxDecoration(gradient: Aurora.gradient)),
                            ),
                          ]),
                        ),
                      ),
                    ],
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
                  if (isResume) ...[
                    const Icon(Icons.play_arrow_rounded,
                        size: 16, color: Aurora.accent),
                    const SizedBox(width: 3),
                  ],
                  Expanded(
                    child: Text(
                      'E${episode.episode} · $title',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14.5,
                          color: watched ? Aurora.textDim : Aurora.text),
                    ),
                  ),
                  if (rating != null && rating > 0) ...[
                    const SizedBox(width: 8),
                    ImdbChip(rating),
                  ],
                ]),
                const SizedBox(height: 4),
                // Status line.
                if (isResume)
                  Text(
                    inProgress
                        ? 'Continue · ${(frac * 100).round()}% watched'
                        : 'Up next',
                    style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: Aurora.accent),
                  )
                else if (watched)
                  const Row(children: [
                    Icon(Icons.check_rounded, size: 13, color: Aurora.good),
                    SizedBox(width: 4),
                    Text('Watched',
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: Aurora.good)),
                  ]),
                const SizedBox(height: 4),
                if (overview != null)
                  Text(
                    overview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5, height: 1.45, color: Aurora.textDim),
                  ),
                if (episode.durationSecs != null) ...[
                  const SizedBox(height: 6),
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
