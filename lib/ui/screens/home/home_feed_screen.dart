import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../data/sources/trakt_service.dart';
import '../../../state/providers.dart';
import '../../navigation.dart';
import '../../theme/lumen_theme.dart';
import '../../widgets/focusable_item.dart';
import '../../widgets/logo_image.dart';
import '../../widgets/poster_card.dart';
import 'home_customize_screen.dart';

/// Netflix/Kodi-style landing: one cinematic hero, then clean customizable
/// rows. Each row is a virtualized horizontal list over a small DB window.
class HomeFeedScreen extends ConsumerWidget {
  const HomeFeedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final featured = ref.watch(featuredProvider);
    final config = ref.watch(homeConfigProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(featuredProvider);
        ref.invalidate(continueWatchingProvider);
        ref.invalidate(recentlyWatchedProvider);
        ref.invalidate(favoritesListProvider);
        ref.invalidate(traktWatchlistProvider);
      },
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: featured.maybeWhen(
              data: (items) =>
                  items.isEmpty ? const SizedBox(height: 8) : _Hero(item: items.first),
              orElse: () => const _HeroSkeleton(),
            ),
          ),
          config.maybeWhen(
            data: (rows) => SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => _rowFor(rows[i]),
                childCount: rows.length,
              ),
            ),
            orElse: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }

  Widget _rowFor(String id) {
    switch (id) {
      case 'continue':
        return _ContentRow(title: 'Continue Watching', provider: continueWatchingProvider);
      case 'favorites':
        return _ContentRow(title: 'My Favorites', provider: favoritesListProvider);
      case 'recent':
        return _ContentRow(title: 'Recently Watched', provider: recentlyWatchedProvider);
      case 'movies':
        return _ContentRow(
            title: 'Movies for You', provider: kindSampleProvider(StreamKind.movie));
      case 'series':
        return _ContentRow(title: 'TV Shows', provider: kindSampleProvider(StreamKind.series));
      case 'trakt_watchlist':
        return const _TraktRow();
      default:
        return const SizedBox.shrink();
    }
  }
}

/// Full-bleed cinematic hero with Play + favorite, like Netflix's billboard.
class _Hero extends ConsumerWidget {
  const _Hero({required this.item});
  final StreamItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final h = (MediaQuery.of(context).size.height * 0.5).clamp(300.0, 460.0);
    final favs = ref.watch(favoriteIdsProvider).valueOrNull ?? const <int>{};
    final isFav = item.id != null && favs.contains(item.id);

    return SizedBox(
      height: h,
      child: Stack(
        fit: StackFit.expand,
        children: [
          LogoImage(url: item.logo, size: 1400, height: h, radius: 0, fallbackText: item.name),
          // Cinematic gradients: darken bottom + left for legible text.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Color(0xFF0A0B0F), Colors.transparent],
                stops: [0.02, 0.7],
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0xCC0A0B0F), Colors.transparent],
                stops: [0.0, 0.6],
              ),
            ),
          ),
          Positioned(
            top: 10,
            right: 12,
            child: FocusableItem(
              borderRadius: 24,
              onActivate: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const HomeCustomizeScreen())),
              builder: (context, focused) => Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4), shape: BoxShape.circle),
                child: const Icon(Icons.tune, size: 20, color: Colors.white),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 22,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: LumenTheme.accent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    item.kind == StreamKind.series ? 'FEATURED SERIES' : 'FEATURED',
                    style: const TextStyle(
                        color: Color(0xFF0A0B0F),
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      height: 1.05,
                      color: Colors.white,
                      letterSpacing: -1),
                ),
                if (item.rating != null && item.rating! > 0) ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    const Icon(Icons.star_rounded, size: 16, color: LumenTheme.accentWarm),
                    const SizedBox(width: 4),
                    Text(item.rating!.toStringAsFixed(1),
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w600)),
                  ]),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    FocusableItem(
                      autofocus: true,
                      borderRadius: 12,
                      onActivate: () => openItem(context, ref, item),
                      builder: (context, focused) => Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 26, vertical: 13),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.play_arrow_rounded, color: Color(0xFF0A0B0F)),
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
                      onActivate: () async {
                        if (item.id == null) return;
                        final repo = await ref.read(repositoryProvider.future);
                        await repo.toggleFavorite(item.id!, !isFav);
                        ref.invalidate(favoriteIdsProvider);
                        ref.invalidate(favoritesListProvider);
                      },
                      builder: (context, focused) => Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(isFav ? Icons.check : Icons.add, color: Colors.white, size: 20),
                          const SizedBox(width: 6),
                          const Text('My List',
                              style: TextStyle(
                                  color: Colors.white, fontWeight: FontWeight.w700)),
                        ]),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroSkeleton extends StatelessWidget {
  const _HeroSkeleton();
  @override
  Widget build(BuildContext context) {
    final h = (MediaQuery.of(context).size.height * 0.5).clamp(300.0, 460.0);
    return Container(height: h, color: LumenTheme.surface);
  }
}

/// A titled horizontal strip of poster cards bound to a provider.
class _ContentRow extends ConsumerWidget {
  const _ContentRow({required this.title, required this.provider});
  final String title;
  final ProviderListenable<AsyncValue<List<StreamItem>>> provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(provider);
    return async.maybeWhen(
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 16, 10),
              child: Text(title,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            SizedBox(
              height: 218,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(width: 14),
                itemBuilder: (_, i) => PosterCard(
                  item: items[i],
                  onTap: () => openItem(context, ref, items[i]),
                ),
              ),
            ),
          ],
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

/// Trakt watchlist — title cards that find the title in your IPTV library.
class _TraktRow extends ConsumerWidget {
  const _TraktRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(traktWatchlistProvider);
    return async.maybeWhen(
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 16, 10),
              child: Row(children: [
                Icon(Icons.check_circle, color: Color(0xFFED1C24), size: 18),
                SizedBox(width: 6),
                Text('Trakt Watchlist',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ]),
            ),
            SizedBox(
              height: 92,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (_, i) => _TraktChip(item: items[i]),
              ),
            ),
          ],
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _TraktChip extends ConsumerWidget {
  const _TraktChip({required this.item});
  final TraktItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FocusableItem(
      borderRadius: 14,
      onActivate: () async {
        final repo = await ref.read(repositoryProvider.future);
        final pl = ref.read(activePlaylistProvider);
        if (pl?.id == null) return;
        final hits = await repo.search(playlistId: pl!.id!, query: item.title);
        if (!context.mounted) return;
        if (hits.isNotEmpty) {
          openItem(context, ref, hits.first);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('"${item.title}" not found in your library.')));
        }
      },
      builder: (context, focused) => Container(
        width: 160,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: LumenTheme.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 4),
            Text(
                '${item.type == 'show' ? 'TV' : 'Movie'}'
                '${item.year != null ? ' · ${item.year}' : ''}',
                style: const TextStyle(color: Color(0xFF9AA0B0), fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
