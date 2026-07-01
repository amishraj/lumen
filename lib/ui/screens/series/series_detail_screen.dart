import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../data/sources/omdb_service.dart';
import '../../../state/providers.dart';
import '../../theme/lumen_theme.dart';
import '../../widgets/logo_image.dart';
import '../../widgets/rating_badges.dart';
import '../player/player_screen.dart';

/// Shows a series' seasons & episodes. Episodes are fetched lazily from the
/// Xtream panel the first time the user opens the show.
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

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Episode>> _load() async {
    final repo = await ref.read(repositoryProvider.future);
    return repo.seriesEpisodes(widget.playlist, widget.series.url);
  }

  StreamItem _toItem(Episode ep) => StreamItem(
        playlistId: widget.playlist.id!,
        kind: StreamKind.series,
        name: 'S${ep.season}E${ep.episode} · ${ep.title}',
        url: ep.url,
        logo: ep.still ?? widget.series.logo,
      );

  /// Plays [ep] with the whole series as a queue so the player can skip between
  /// episodes.
  void _play(List<Episode> all, Episode ep) {
    final queue = all.map(_toItem).toList();
    final index = all.indexOf(ep);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        item: queue[index],
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
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 260,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(widget.series.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              background: Stack(
                fit: StackFit.expand,
                children: [
                  LogoImage(
                      url: widget.series.logo,
                      size: 600,
                      height: 260,
                      radius: 0,
                      fallbackText: widget.series.name),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xEE0A0B0F)],
                        stops: [0.4, 1],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Consumer(builder: (context, ref, _) {
              final info =
                  ref.watch(omdbProvider(widget.series.name)).valueOrNull;
              if (info == null) return const SizedBox(height: 8);
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    RatingBadges(info: info),
                    if (info.plot != null) ...[
                      const SizedBox(height: 12),
                      Text(info.plot!,
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

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 44,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: seasons.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (_, i) {
                          final s = seasons[i];
                          final sel = s == _season;
                          return GestureDetector(
                            onTap: () => setState(() => _season = s),
                            child: Container(
                              alignment: Alignment.center,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
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
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13)),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...inSeason.map((ep) => ListTile(
                          leading: LogoImage(
                              url: ep.still ?? widget.series.logo,
                              size: 64,
                              height: 40,
                              radius: 8,
                              fallbackText: ep.title),
                          title: Text('${ep.episode}. ${ep.title}',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: ep.durationSecs != null
                              ? Text('${(ep.durationSecs! / 60).round()} min',
                                  style: const TextStyle(fontSize: 12))
                              : null,
                          trailing: const Icon(Icons.play_circle_fill,
                              color: LumenTheme.accent),
                          onTap: () => _play(eps, ep),
                        )),
                    const SizedBox(height: 24),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
