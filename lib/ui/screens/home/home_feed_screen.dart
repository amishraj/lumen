import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../data/repositories/library_repository.dart';
import '../../../data/sources/tmdb_service.dart';
import '../../../data/sources/trakt_service.dart';
import '../../../state/detail_bundle.dart';
import '../../../state/providers.dart';
import '../../navigation.dart';
import '../../theme/lumen_theme.dart';
import '../../title_utils.dart';
import '../../widgets/focusable_item.dart';
import '../../widgets/logo_image.dart';
import '../../widgets/poster_card.dart';
import '../../widgets/imdb_badge.dart';
import '../../widgets/rating_badges.dart';
import 'genre_browse_screen.dart';
import 'home_customize_screen.dart';

/// Netflix/Kodi-style landing: one cinematic hero, then clean customizable
/// rows. Each row is a virtualized horizontal list over a small DB window.
class HomeFeedScreen extends ConsumerWidget {
  const HomeFeedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // .valueOrNull keeps the last-known list visible while a watched provider
    // refetches, instead of the row (and any focus inside it) disappearing
    // for a frame — see _ContentRow below for why that matters for remote nav.
    final featured = ref.watch(featuredProvider).valueOrNull;
    final rows = ref.watch(homeConfigProvider).valueOrNull;

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(featuredProvider);
        ref.invalidate(continueWatchingProvider);
        ref.invalidate(recentlyWatchedProvider);
        ref.invalidate(favoritesListProvider);
        ref.invalidate(traktConnectedProvider);
        ref.invalidate(traktWatchlistProvider);
        ref.invalidate(traktListsProvider);
      },
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: featured == null
                ? const _HeroSkeleton()
                : featured.isEmpty
                    ? const SizedBox(height: 8)
                    : _HeroCarousel(items: featured),
          ),
          if (rows != null)
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => _rowFor(rows[i]),
                childCount: rows.length,
              ),
            ),
          // Trakt watchlist — above the discovery rows, always shown when
          // connected (self-hides when empty).
          const SliverToBoxAdapter(child: _TraktRow()),
          // TMDB discovery rows (Browse by Genre / Popular / Trending …).
          const SliverToBoxAdapter(child: _TmdbSection()),
          // The user's custom Trakt lists, one row each.
          SliverToBoxAdapter(
            child: Consumer(builder: (context, ref, _) {
              final lists =
                  ref.watch(traktListsProvider).valueOrNull ?? const [];
              if (lists.isEmpty) return const SizedBox.shrink();
              return Column(
                children: [for (final l in lists) _TraktListRow(list: l)],
              );
            }),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }

  Widget _rowFor(String id) {
    switch (id) {
      // Movie-heavy rows use wide, hover-expanding landscape cards.
      case 'continue':
        return _ContentRow(
            title: 'Continue Watching',
            provider: continueWatchingProvider,
            wide: true);
      case 'favorites':
        return _ContentRow(title: 'My List', provider: favoritesListProvider);
      case 'recent':
        return _ContentRow(
            title: 'Recently Watched',
            provider: recentlyWatchedProvider,
            wide: true);
      case 'movies':
        return _ContentRow(
            title: 'Movies for You',
            provider: kindSampleProvider(StreamKind.movie),
            wide: true);
      case 'series':
        return _ContentRow(
            title: 'TV Shows', provider: kindSampleProvider(StreamKind.series));
      // trakt_watchlist is rendered always-on below (not via config) so a
      // connected account's watchlist shows without being toggled in.
      default:
        return const SizedBox.shrink();
    }
  }
}

/// Arrow-navigable hero carousel of current-popular movies. Left from Play or
/// Right from My List pages to the previous/next featured title.
class _HeroCarousel extends StatefulWidget {
  const _HeroCarousel({required this.items});
  final List<StreamItem> items;

  @override
  State<_HeroCarousel> createState() => _HeroCarouselState();
}

class _HeroCarouselState extends State<_HeroCarousel> {
  final _controller = PageController();
  // Single focus target that always follows the visible hero's Play button.
  // Autofocus alone can't do this: it only fires on first mount, so paging
  // (Right/Left) left focus orphaned and it fell back to the search bar or the
  // row below. We re-request this node every time the page changes instead.
  final _playFocus = FocusNode(debugLabel: 'hero-play');
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    _playFocus.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final next = (_page + delta).clamp(0, widget.items.length - 1);
    if (next == _page) return;
    _controller.animateToPage(next,
        duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
  }

  void _onPageChanged(int i) {
    setState(() => _page = i);
    // After the new page builds, pull focus onto its Play button so remote
    // navigation stays on the hero instead of jumping away.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final h = (MediaQuery.of(context).size.height * 0.62).clamp(380.0, 560.0);
    return SizedBox(
      height: h,
      child: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            onPageChanged: _onPageChanged,
            itemCount: widget.items.length,
            itemBuilder: (context, i) => _HeroBillboard(
              item: widget.items[i],
              // Only the visible page owns the shared focus node (a node can
              // attach to one widget at a time); it autofocuses on first open.
              playFocus: i == _page ? _playFocus : null,
              autofocusPlay: i == 0,
              onPrev: i > 0 ? () => _go(-1) : null,
              onNext: i < widget.items.length - 1 ? () => _go(1) : null,
            ),
          ),
          // Page dots
          Positioned(
            bottom: 8,
            right: 24,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < widget.items.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _page ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _page
                          ? LumenTheme.accent
                          : const Color(0x66FFFFFF),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-bleed cinematic hero with Play + My List, like Netflix's billboard.
class _HeroBillboard extends ConsumerWidget {
  const _HeroBillboard({
    required this.item,
    this.onPrev,
    this.onNext,
    this.playFocus,
    this.autofocusPlay = false,
  });
  final StreamItem item;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final FocusNode? playFocus;
  final bool autofocusPlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final h = (MediaQuery.of(context).size.height * 0.62).clamp(380.0, 560.0);
    final favs = ref.watch(favoriteIdsProvider).valueOrNull ?? const <int>{};
    final isFav = item.id != null && favs.contains(item.id);
    // Single bundled fetch so backdrop, badges and synopsis land together.
    final bundle = ref
        .watch(detailBundleProvider(
            (title: item.name, isShow: item.kind == StreamKind.series)))
        .valueOrNull;
    final tmdb = bundle?.tmdb;
    final omdb = bundle?.omdb;
    final heroArt = tmdb?.backdrop ?? item.logo;
    final synopsis = bundle?.overview;

    return SizedBox(
      height: h,
      child: Stack(
        fit: StackFit.expand,
        children: [
          LogoImage(
              url: heroArt,
              size: 1400,
              height: h,
              radius: 0,
              fallbackText: item.name),
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
                    color: Colors.black.withValues(alpha: 0.4),
                    shape: BoxShape.circle),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: LumenTheme.accent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    item.kind == StreamKind.series
                        ? 'FEATURED SERIES'
                        : 'FEATURED',
                    style: const TextStyle(
                        color: Color(0xFF0A0B0F),
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  cleanTitle(item.name).title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      height: 1.05,
                      color: Colors.white,
                      letterSpacing: -1),
                ),
                // IMDb / Rotten Tomatoes (OMDb) badges, with an IMDb-styled
                // rating fallback so the hero always shows a rating level.
                if (omdb != null &&
                    (omdb.imdb != null || omdb.rotten != null)) ...[
                  const SizedBox(height: 10),
                  RatingBadges(info: omdb),
                ] else if ((item.rating ?? tmdb?.rating ?? 0) > 0) ...[
                  const SizedBox(height: 10),
                  ImdbBadge(
                      rating: (item.rating ?? tmdb!.rating!), compact: false),
                ],
                if (synopsis != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    synopsis,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Color(0xFFC7CBD6), fontSize: 13.5, height: 1.45),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    FocusableItem(
                      focusNode: playFocus,
                      autofocus: autofocusPlay,
                      borderRadius: 12,
                      onLeft: onPrev,
                      onActivate: () => openItem(context, ref, item),
                      builder: (context, focused) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 26, vertical: 13),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
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
                      onRight: onNext,
                      onActivate: () => setFavorite(ref, item, !isFav),
                      builder: (context, focused) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 13),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(12),
                        ),
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
    final h = (MediaQuery.of(context).size.height * 0.62).clamp(380.0, 560.0);
    return Container(height: h, color: LumenTheme.surface);
  }
}

/// A titled horizontal strip of cards bound to a provider. [wide] switches to
/// landscape 16:9 cards that expand on hover/focus (movie rows).
class _ContentRow extends ConsumerWidget {
  const _ContentRow(
      {required this.title, required this.provider, this.wide = false});
  final String title;
  final ProviderListenable<AsyncValue<List<StreamItem>>> provider;
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Use the last-known value (Riverpod keeps it during a refetch) instead of
    // a strict data-only match — otherwise this row (and its focused item)
    // vanishes for a frame on every invalidate (e.g. toggling a favorite),
    // which drops keyboard/remote focus and makes Down/Up feel "reset".
    final items = ref.watch(provider).valueOrNull;
    if (items == null || items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 16, 10),
          child: Text(title,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        ),
        SizedBox(
          height: wide ? 160 : 250,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none, // don't clip the focus glow / scale
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            itemCount: items.length,
            separatorBuilder: (_, __) => SizedBox(width: wide ? 16 : 14),
            itemBuilder: (_, i) => PosterCard(
              item: items[i],
              wide: wide,
              onTap: () => openItem(context, ref, items[i]),
            ),
          ),
        ),
      ],
    );
  }
}

/// TMDB-powered discovery: genre shortcuts + Popular / Trending / genre rows
/// and a "Because you watched…" strip. Hidden entirely until a key is set.
class _TmdbSection extends ConsumerWidget {
  const _TmdbSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(tmdbEnabledProvider).valueOrNull ?? false;
    if (!enabled) return const SizedBox.shrink();
    final genres = ref.watch(tmdbGenresProvider).valueOrNull ?? const [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (genres.isNotEmpty) _GenreChips(genres: genres),
        _ContentRow(
            title: 'Popular Now', provider: tmdbPopularProvider, wide: true),
        _ContentRow(
            title: 'Trending This Week',
            provider: tmdbTrendingProvider,
            wide: true),
        const _BecauseYouWatchedRow(),
        // A few genre rows inline; full catalogue via the chips above.
        for (final g in genres.take(3))
          _ContentRow(
              title: g.name, provider: tmdbGenreRowProvider(g.id), wide: true),
      ],
    );
  }
}

/// Horizontal strip of tappable genre chips → full genre browse screen.
class _GenreChips extends StatelessWidget {
  const _GenreChips({required this.genres});
  final List<TmdbGenre> genres;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 18, 16, 10),
          child: Text('Browse by Genre',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        ),
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: genres.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, i) => FocusableItem(
              borderRadius: 22,
              onActivate: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => GenreBrowseScreen(genre: genres[i]))),
              builder: (context, focused) => Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: LumenTheme.surface,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Text(genres[i].name,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// "Because you watched X" recommendations, matched to the library.
class _BecauseYouWatchedRow extends ConsumerWidget {
  const _BecauseYouWatchedRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(tmdbBecauseYouWatchedProvider).valueOrNull;
    if (data == null || data.seed == null || data.items.isEmpty) {
      return const SizedBox.shrink();
    }
    final items = data.items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 16, 10),
          child: Text('Because you watched ${data.seed}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        ),
        SizedBox(
          height: 250,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
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
  }
}

/// Trakt watchlist — title cards that find the title in your IPTV library.
class _TraktRow extends ConsumerWidget {
  const _TraktRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(traktWatchlistProvider).valueOrNull;
    if (items == null || items.isEmpty) return const SizedBox.shrink();
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
          height: 246,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (_, i) => _TraktChip(item: items[i]),
          ),
        ),
      ],
    );
  }
}

/// One of the user's Trakt lists rendered as a titled strip.
class _TraktListRow extends ConsumerWidget {
  const _TraktListRow({required this.list});
  final TraktList list;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items =
        ref.watch(traktListItemsProvider(list.id)).valueOrNull ?? const [];
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 16, 10),
          child: Row(children: [
            const Icon(Icons.bookmark, color: Color(0xFFED1C24), size: 18),
            const SizedBox(width: 6),
            Text(list.name,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ]),
        ),
        SizedBox(
          height: 246,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (_, i) => _TraktChip(item: items[i]),
          ),
        ),
      ],
    );
  }
}

class _TraktChip extends ConsumerWidget {
  const _TraktChip({required this.item});
  final TraktItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Vertical 2:3 poster from TMDB (DB-cached per title); neutral fallback.
    final poster = ref
        .watch(tmdbDetailProvider(
            (title: item.title, isShow: item.type == 'show')))
        .valueOrNull
        ?.poster;
    const w = 130.0;

    return FocusableItem(
      borderRadius: 14,
      onActivate: () async {
        final repo = await ref.read(repositoryProvider.future);
        final pl = ref.read(activePlaylistProvider);
        if (pl?.id == null) return;
        final hits = await repo.search(playlistId: pl!.id!, query: item.title);
        final hit = LibraryRepository.preferEnglish(hits);
        if (!context.mounted) return;
        if (hit != null) {
          openItem(context, ref, hit);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('"${item.title}" not found in your library.')));
        }
      },
      builder: (context, focused) => AnimatedScale(
        scale: focused ? 1.05 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: SizedBox(
          width: w,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LogoImage(
                url: poster,
                size: w,
                height: w * 1.5,
                radius: 14,
                fallbackText: item.title,
              ),
              const SizedBox(height: 6),
              Text(item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600)),
              Text(
                  '${item.type == 'show' ? 'TV' : 'Movie'}'
                  '${item.year != null ? ' · ${item.year}' : ''}',
                  style:
                      const TextStyle(color: Color(0xFF9AA0B0), fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}
