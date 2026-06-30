import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../data/sources/trakt_service.dart';
import '../../../state/providers.dart';
import '../../navigation.dart';
import '../../theme/lumen_theme.dart';
import '../../widgets/logo_image.dart';
import '../../widgets/poster_card.dart';
import 'home_customize_screen.dart';

/// The Netflix-style landing tab: a featured hero banner, then customizable
/// rows (continue watching, favorites, recent, Trakt watchlist, movies, shows).
/// Each row is a virtualized horizontal list pulling a small DB window — light.
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
                  items.isEmpty ? const SizedBox(height: 8) : _Banner(items: items),
              orElse: () => const SizedBox(height: 220),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 8, 4),
              child: Row(
                children: [
                  const Text('For You',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const HomeCustomizeScreen())),
                    icon: const Icon(Icons.tune, size: 18),
                    label: const Text('Customize'),
                  ),
                ],
              ),
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
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
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
            title: 'Movies for You',
            provider: kindSampleProvider(StreamKind.movie));
      case 'series':
        return _ContentRow(
            title: 'TV Shows', provider: kindSampleProvider(StreamKind.series));
      case 'trakt_watchlist':
        return const _TraktRow();
      default:
        return const SizedBox.shrink();
    }
  }
}

/// Hero carousel of featured posters.
class _Banner extends StatefulWidget {
  const _Banner({required this.items});
  final List<StreamItem> items;

  @override
  State<_Banner> createState() => _BannerState();
}

class _BannerState extends State<_Banner> {
  final _controller = PageController(viewportFraction: 0.92);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    return SizedBox(
      height: 230,
      child: PageView.builder(
        controller: _controller,
        itemCount: items.length,
        itemBuilder: (context, i) {
          final it = items[i];
          return Consumer(builder: (context, ref, _) {
            return GestureDetector(
              onTap: () => openItem(context, ref, it),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  color: LumenTheme.surface,
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    LogoImage(
                        url: it.logo,
                        size: 600,
                        height: 230,
                        radius: 22,
                        fallbackText: it.name),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Color(0xCC0A0B0F)],
                          stops: [0.45, 1],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 18,
                      right: 18,
                      bottom: 16,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: LumenTheme.accent,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              it.kind == StreamKind.series ? 'SERIES' : 'FEATURED',
                              style: const TextStyle(
                                  color: Color(0xFF0A0B0F),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(it.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          });
        },
      ),
    );
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
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            SizedBox(
              height: 214,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
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
              padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(children: [
                Icon(Icons.check_circle, color: Color(0xFFED1C24), size: 18),
                SizedBox(width: 6),
                Text('Trakt Watchlist',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ]),
            ),
            SizedBox(
              height: 92,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
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
    return GestureDetector(
      onTap: () async {
        // Find this Trakt title inside the IPTV library and play it.
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
      child: Container(
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
