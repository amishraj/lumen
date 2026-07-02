import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../data/sources/omdb_service.dart';
import '../../../data/sources/realdebrid_service.dart';
import '../../../data/sources/tmdb_service.dart';
import '../../../state/providers.dart';
import '../../theme/lumen_theme.dart';
import '../../title_utils.dart';
import '../../widgets/focusable_item.dart';
import '../../widgets/logo_image.dart';
import '../../widgets/source_picker.dart';
import '../../widgets/rating_badges.dart';
import '../player/player_screen.dart';

/// Movie detail page (Netflix/Kodi-style): backdrop, title, IMDb/RT/Metacritic
/// ratings + plot from OMDb, and Play. Metadata loads lazily and is cached.
class ContentDetailScreen extends ConsumerWidget {
  const ContentDetailScreen({super.key, required this.item});
  final StreamItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(omdbProvider(item.name));
    final tmdb = ref
        .watch(tmdbDetailProvider(
            (title: item.name, isShow: item.kind == StreamKind.series)))
        .valueOrNull;
    final favs = ref.watch(favoriteIdsProvider).valueOrNull ?? const <int>{};
    final isFav = item.id != null && favs.contains(item.id);
    // Warm the RD flag so it's resolved by the time Play is pressed.
    ref.watch(rdEnabledProvider);
    final info = meta.valueOrNull;
    // TMDB supplies the best backdrop; fall back to OMDb poster / provider art.
    final backdrop = tmdb?.backdrop ?? info?.poster ?? item.logo;
    final overview = info?.plot ?? tmdb?.overview;
    final metaBits = <String>[
      if (info?.year != null && info!.year!.isNotEmpty)
        info.year!
      else if (tmdb?.releaseDate != null && tmdb!.releaseDate!.length >= 4)
        tmdb.releaseDate!.substring(0, 4),
      if (info?.rated != null && info!.rated!.isNotEmpty) info.rated!,
      if (info?.runtime != null && info!.runtime!.isNotEmpty)
        info.runtime!
      else if (tmdb?.runtimeMins != null)
        '${tmdb!.runtimeMins} min',
      if (info?.genre != null && info!.genre!.isNotEmpty)
        info.genre!
      else if (tmdb != null && tmdb.genres.isNotEmpty)
        tmdb.genres.take(3).join(', '),
    ];

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 320,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  LogoImage(
                    url: backdrop,
                    size: 1000,
                    height: 320,
                    radius: 0,
                    fallbackText: item.name,
                  ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xFF0A0B0F)],
                        stops: [0.45, 1],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(cleanTitle(item.name).title,
                      style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          height: 1.1)),
                  const SizedBox(height: 8),
                  if (metaBits.isNotEmpty)
                    Text(
                      metaBits.join('  •  '),
                      style: const TextStyle(
                          color: Color(0xFF9AA0B0), fontSize: 13),
                    ),
                  const SizedBox(height: 14),
                  if (meta.isLoading)
                    const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    RatingBadges(info: info),
                  const SizedBox(height: 18),
                  Row(children: [
                    FocusableItem(
                      autofocus: true,
                      borderRadius: 12,
                      onActivate: () async {
                        // With Real-Debrid enabled, let the user choose the
                        // source; otherwise go straight to the IPTV stream.
                        final rd =
                            ref.read(rdEnabledProvider).valueOrNull ?? false;
                        var toPlay = item;
                        if (rd) {
                          final picked = await showSourcePicker(context, ref,
                              title: item.name, iptvUrl: item.url);
                          if (picked == null) return;
                          toPlay = item.copyWith(url: picked.url);
                        }
                        if (!context.mounted) return;
                        Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => PlayerScreen(item: toPlay)));
                      },
                      builder: (context, focused) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 28, vertical: 13),
                        decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12)),
                        child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.play_arrow_rounded,
                                  color: Color(0xFF0A0B0F)),
                              SizedBox(width: 6),
                              Text('Play',
                                  style: TextStyle(
                                      color: Color(0xFF0A0B0F),
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15)),
                            ]),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FocusableItem(
                      borderRadius: 12,
                      onActivate: () => setFavorite(ref, item, !isFav),
                      builder: (context, focused) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 13),
                        decoration: BoxDecoration(
                            color: LumenTheme.surfaceHi,
                            borderRadius: BorderRadius.circular(12)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(isFav ? Icons.check : Icons.add,
                              color: Colors.white, size: 20),
                          const SizedBox(width: 6),
                          const Text('My List',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700)),
                        ]),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 20),
                  if (overview != null)
                    Text(overview,
                        style: const TextStyle(
                            fontSize: 14,
                            height: 1.5,
                            color: Color(0xFFC7CBD6)))
                  else if (!meta.isLoading)
                    const Text('No description available.',
                        style:
                            TextStyle(color: Color(0xFF6B7080), fontSize: 13)),
                  if (tmdb != null && tmdb.cast.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    const Text('Cast',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text(tmdb.cast.join(', '),
                        style: const TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: Color(0xFF9AA0B0))),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
