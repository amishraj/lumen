import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../data/repositories/library_repository.dart';
import '../../data/sources/tmdb_service.dart';
import '../../data/sources/trakt_service.dart';
import '../../state/detail_bundle.dart';
import '../../state/providers.dart';
import '../../ui/title_utils.dart';
import '../aurora_focus.dart';
import '../aurora_navigation.dart';
import '../aurora_providers.dart';
import '../aurora_theme.dart';
import '../player/aurora_player.dart';
import '../widgets/aurora_badges.dart';
import '../widgets/aurora_buttons.dart';
import '../widgets/aurora_cards.dart';
import '../widgets/aurora_image.dart';
import '../widgets/aurora_shelf.dart';

/// Aurora Home: one cinematic billboard, then dense, calm shelves.
class AuroraHomePage extends ConsumerStatefulWidget {
  const AuroraHomePage({super.key});

  @override
  ConsumerState<AuroraHomePage> createState() => _AuroraHomePageState();
}

class _AuroraHomePageState extends ConsumerState<AuroraHomePage> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Snap fully to the top (full billboard, nav clear of the buttons). Used
  /// whenever focus lands back on the hero — so pressing Up repeatedly always
  /// ends at offset 0 instead of leaving a button tucked under the nav bar.
  void _toTop() {
    if (_scroll.hasClients && _scroll.offset > 0) {
      _scroll.animateTo(0,
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final featured = ref.watch(featuredProvider).valueOrNull;
    final posterW = Aurora.posterWidth(context);
    final wideW = Aurora.wideWidth(context);
    final liveW = wideW * 0.82;
    final posterRow = posterW * 1.5 + 56;
    final wideRow = wideW * 9 / 16 + 10;
    final liveRow = liveW * 9 / 16 + 40;

    List<StreamItem>? v(ProviderListenable<AsyncValue<List<StreamItem>>> p) =>
        ref.watch(p).valueOrNull;

    final genres =
        (ref.watch(tmdbGenresProvider).valueOrNull ?? const <TmdbGenre>[])
            .take(3)
            .toList();
    final because = ref.watch(tmdbBecauseYouWatchedProvider).valueOrNull;
    final watchlist = ref.watch(traktWatchlistProvider).valueOrNull;

    Widget posterShelf(String title, List<StreamItem>? items) =>
        AuroraShelf<StreamItem>(
          title: title,
          items: items,
          rowHeight: posterRow,
          skeletonWidth: posterW,
          itemBuilder: (context, it, i) => AuroraPosterCard(
            item: it,
            width: posterW,
            onTap: () => openAuroraItem(context, ref, it),
          ),
        );

    Widget wideShelf(String title, List<StreamItem>? items) =>
        AuroraShelf<StreamItem>(
          title: title,
          items: items,
          rowHeight: wideRow,
          skeletonWidth: wideW,
          itemBuilder: (context, it, i) => AuroraWideCard(
            item: it,
            width: wideW,
            onTap: () => openAuroraItem(context, ref, it),
          ),
        );

    return AuroraRowScope(
      // Row-aware Up/Down: a page of horizontal rails stacked vertically, so
      // Down always lands on the row below (never sideways). AuroraRowScope
      // bounds the search to this page (a plain FocusTraversalGroup here would
      // leak into the top nav bar's shared scope — see its doc comment).
      child: CustomScrollView(
      controller: _scroll,
      // Build a couple of rows past the fold so Down always has a focusable
      // row to land on (and the vertical glide has somewhere to ease toward).
      // ignore: deprecated_member_use
      cacheExtent: 1200,
      slivers: [
        SliverToBoxAdapter(
          child: featured == null
              ? const _BillboardSkeleton()
              : featured.isEmpty
                  ? const SizedBox(height: 96)
                  : _Billboard(items: featured, onFocusTop: _toTop),
        ),
        SliverList(
          delegate: SliverChildListDelegate.fixed([
            wideShelf('Continue Watching', v(continueWatchingProvider)),
            posterShelf('My List', v(auroraMyListProvider)),
            AuroraShelf<StreamItem>(
              title: 'Live Now',
              items: v(auroraLiveNowProvider),
              rowHeight: liveRow,
              skeletonWidth: liveW,
              itemBuilder: (context, it, i) => AuroraLiveCard(
                item: it,
                width: liveW,
                onTap: () => openAuroraItem(context, ref, it,
                    liveQueue: v(auroraLiveNowProvider)),
              ),
            ),
            const _CategoriesRail(),
            wideShelf('Trending This Week', v(tmdbTrendingProvider)),
            wideShelf('Popular Now', v(tmdbPopularProvider)),
            wideShelf('Recently Watched', v(recentlyWatchedProvider)),
            posterShelf(
                'Movies for You', v(kindSampleProvider(StreamKind.movie))),
            posterShelf('TV Shows', v(kindSampleProvider(StreamKind.series))),
            if (because != null && because.seed != null)
              posterShelf(
                  'Because you watched ${cleanTitle(because.seed!).title}',
                  because.items),
            for (final g in genres)
              wideShelf(g.name, v(tmdbGenreRowProvider(g.id))),
            if (watchlist != null && watchlist.isNotEmpty)
              _TraktShelf(items: watchlist, width: posterW),
            const SizedBox(height: 72),
          ]),
        ),
      ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Billboard
// ---------------------------------------------------------------------------

class _Billboard extends ConsumerStatefulWidget {
  const _Billboard({required this.items, this.onFocusTop});
  final List<StreamItem> items;

  /// Called when focus lands on the hero — snaps the page to the very top.
  final VoidCallback? onFocusTop;

  @override
  ConsumerState<_Billboard> createState() => _BillboardState();
}

class _BillboardState extends ConsumerState<_Billboard> {
  int _index = 0;
  bool _heroFocused = false;
  Timer? _rotate;

  @override
  void initState() {
    super.initState();
    // Slow ambient rotation — never while the user's focus is on the hero.
    _rotate = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted || _heroFocused || widget.items.length < 2) return;
      _go(1, manual: false);
    });
  }

  @override
  void dispose() {
    _rotate?.cancel();
    super.dispose();
  }

  void _go(int delta, {bool manual = true}) {
    final n = widget.items.length;
    if (n < 2) return;
    final next = manual ? (_index + delta).clamp(0, n - 1) : (_index + 1) % n;
    if (next == _index) return;
    // Warm the next backdrop so the crossfade never shows a loading tile.
    final after = widget.items[(next + 1) % n];
    if (after.logo != null && after.logo!.isNotEmpty) {
      precacheImage(CachedNetworkImageProvider(after.logo!), context);
    }
    setState(() => _index = next);
  }

  void _onHeroFocus(bool f) {
    _heroFocused = f;
    // Landing back on the hero snaps the page fully to the top, so the buttons
    // are never left tucked under the nav bar after scrolling up.
    if (f) widget.onFocusTop?.call();
  }

  void _upToNav() {
    widget.onFocusTop?.call();
    auroraNavTarget?.requestFocus();
  }

  void _playDirect(StreamItem item) {
    if (item.kind == StreamKind.movie) {
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AuroraPlayerScreen(item: item)));
    } else {
      openAuroraItem(context, ref, item);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final h = (size.height * 0.66).clamp(420.0, 680.0);
    final margin = Aurora.margin(context);
    final item = widget.items[_index.clamp(0, widget.items.length - 1)];
    final bundle = ref
        .watch(detailBundleProvider(
            (title: item.name, isShow: item.kind == StreamKind.series)))
        .valueOrNull;
    final art = bundle?.tmdb?.backdrop ?? item.logo;
    final synopsis = bundle?.overview;
    final omdb = bundle?.omdb;
    final favs = ref.watch(favoriteIdsProvider).valueOrNull ?? const <int>{};
    final isFav = item.id != null && favs.contains(item.id);
    final title = cleanTitle(item.name).title;
    final meta = <String>[
      if (omdb?.year != null && omdb!.year!.isNotEmpty) omdb.year!,
      if (omdb?.rated != null && omdb!.rated!.isNotEmpty) omdb.rated!,
      if (omdb?.runtime != null && omdb!.runtime!.isNotEmpty) omdb.runtime!,
      if (omdb?.genre != null && omdb!.genre!.isNotEmpty)
        omdb.genre!.split(',').take(3).join(' · ').trim(),
    ];

    return SizedBox(
      height: h,
      child: Stack(fit: StackFit.expand, children: [
        // Backdrop with crossfade + a slow settle (Ken Burns lite). The
        // bottom fade is baked into the *pixels* via a ShaderMask (alpha → 0),
        // so the artwork dissolves into the page with no possible seam — an
        // overlay gradient could still leave a visible knee against bright art.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 700),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: SizedBox(
            key: ValueKey(art ?? item.name),
            width: size.width,
            height: h,
            child: ShaderMask(
              // Dissolve the artwork out well *above* the action row so no
              // bright slice of the backdrop lingers below the buttons before
              // the first shelf.
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.white, Colors.white, Colors.transparent],
                stops: [0.0, 0.4, 0.82],
              ).createShader(rect),
              blendMode: BlendMode.dstIn,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 1.055, end: 1.0),
                duration: const Duration(seconds: 15),
                curve: Curves.easeOut,
                builder: (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
                child: AuroraImage(
                  url: art,
                  width: size.width,
                  height: h,
                  radius: 0,
                  fallbackText: title,
                ),
              ),
            ),
          ),
        ),
        // Soft scrims for text legibility (no hard knee needed — the art is
        // already fading out toward the bottom).
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.center,
              colors: [Color(0xCC06070B), Color(0x0006070B)],
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [Color(0xCC06070B), Color(0x0006070B)],
              stops: [0.0, 0.62],
            ),
          ),
        ),
        // Metadata column
        Positioned(
          left: margin,
          right: margin,
          bottom: 34,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Eyebrow(item.kind == StreamKind.series
                  ? 'Featured series'
                  : '#${_index + 1} in movies this week'),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 700),
                child: Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Aurora.display),
              ),
              const SizedBox(height: 12),
              Row(children: [
                RatingsStrip(info: omdb, fallbackRating: item.rating),
                if (omdb != null && meta.isNotEmpty) ...[
                  const SizedBox(width: 14),
                  Flexible(child: MetaLine(meta)),
                ],
              ]),
              if (synopsis != null) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: Text(synopsis,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Aurora.body),
                ),
              ],
              const SizedBox(height: 20),
              Row(children: [
                // autoScroll: false — the hero owns the page scroll (snaps to
                // the very top on focus via _onHeroFocus); the reveal glide
                // must not fight that or Up settles short of offset 0.
                AuroraPillButton(
                  label: 'Play',
                  icon: Icons.play_arrow_rounded,
                  primary: true,
                  autofocus: true,
                  autoScroll: false,
                  onLeft: () => _go(-1),
                  onUp: _upToNav,
                  onPressed: () => _playDirect(item),
                ),
                const SizedBox(width: 12),
                AuroraPillButton(
                  label: 'Details',
                  icon: Icons.info_outline_rounded,
                  autoScroll: false,
                  onUp: _upToNav,
                  onPressed: () => openAuroraItem(context, ref, item),
                ),
                const SizedBox(width: 12),
                AuroraPillButton(
                  label: isFav ? 'In My List' : 'My List',
                  icon: isFav ? Icons.check_rounded : Icons.add_rounded,
                  autoScroll: false,
                  onRight: () => _go(1),
                  onUp: _upToNav,
                  onPressed: () => setFavorite(ref, item, !isFav),
                ),
              ].map((w) {
                // Track hero focus through the action row so ambient rotation
                // pauses the moment the user is interacting.
                return Focus(
                  skipTraversal: true,
                  canRequestFocus: false,
                  onFocusChange: _onHeroFocus,
                  child: w,
                );
              }).toList()),
            ],
          ),
        ),
        // Page dots
        Positioned(
          right: margin,
          bottom: 36,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < widget.items.length; i++)
              AnimatedContainer(
                duration: Aurora.normal,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: i == _index ? 20 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: i == _index ? Colors.white : const Color(0x4DFFFFFF),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}

class _BillboardSkeleton extends StatelessWidget {
  const _BillboardSkeleton();

  @override
  Widget build(BuildContext context) {
    final h =
        (MediaQuery.of(context).size.height * 0.66).clamp(420.0, 680.0);
    return Container(
      height: h,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0C0F18), Color(0xFF06070B)],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Categories rail — large Hulu-style colour tiles under Live Now. Preloaded
// (genres/categories are cheap), each tile a distinct aesthetic gradient with
// an abstract mark; tapping jumps to Movies filtered to that category.
// ---------------------------------------------------------------------------

/// One category tile: gradient, colour name, gradient id, and a mark.
class _CatStyle {
  final List<Color> gradient;
  final IconData mark;
  const _CatStyle(this.gradient, this.mark);
}

const _catPalette = <_CatStyle>[
  _CatStyle([Color(0xFFFF6A5B), Color(0xFF7A1F3D)], Icons.local_fire_department_rounded),
  _CatStyle([Color(0xFF4CC2FF), Color(0xFF1B3A7A)], Icons.bolt_rounded),
  _CatStyle([Color(0xFF8A7BFF), Color(0xFF3A2E7A)], Icons.auto_awesome_rounded),
  _CatStyle([Color(0xFF34D399), Color(0xFF105948)], Icons.forest_rounded),
  _CatStyle([Color(0xFFFFB35C), Color(0xFF7A431B)], Icons.wb_sunny_rounded),
  _CatStyle([Color(0xFFFF7BC2), Color(0xFF7A1F5D)], Icons.favorite_rounded),
  _CatStyle([Color(0xFF00D4C8), Color(0xFF0B4A57)], Icons.water_rounded),
  _CatStyle([Color(0xFFB8C24C), Color(0xFF4A551B)], Icons.eco_rounded),
  _CatStyle([Color(0xFF9AA0FF), Color(0xFF2E317A)], Icons.nights_stay_rounded),
  _CatStyle([Color(0xFFFF8A5B), Color(0xFF7A2E1B)], Icons.explore_rounded),
];

IconData _markFor(String name) {
  final n = name.toLowerCase();
  if (n.contains('action')) return Icons.local_fire_department_rounded;
  if (n.contains('comedy')) return Icons.sentiment_very_satisfied_rounded;
  if (n.contains('drama')) return Icons.theater_comedy_rounded;
  if (n.contains('horror')) return Icons.dark_mode_rounded;
  if (n.contains('thriller') || n.contains('crime')) return Icons.gpp_maybe_rounded;
  if (n.contains('sci') || n.contains('fantasy')) return Icons.rocket_launch_rounded;
  if (n.contains('romance')) return Icons.favorite_rounded;
  if (n.contains('animation') || n.contains('kids') || n.contains('family')) {
    return Icons.child_care_rounded;
  }
  if (n.contains('doc')) return Icons.menu_book_rounded;
  if (n.contains('adventure')) return Icons.explore_rounded;
  if (n.contains('music')) return Icons.music_note_rounded;
  if (n.contains('war')) return Icons.military_tech_rounded;
  if (n.contains('west')) return Icons.landscape_rounded;
  if (n.contains('myst')) return Icons.search_rounded;
  return Icons.movie_rounded;
}

class _CategoriesRail extends ConsumerWidget {
  const _CategoriesRail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final governs = ref.watch(auroraTmdbGovernsProvider).valueOrNull ?? false;
    final margin = Aurora.margin(context);

    // (label, onTap) pairs.
    final entries = <(String, VoidCallback)>[];
    if (governs) {
      final genres =
          ref.watch(auroraTmdbGenresProvider(StreamKind.movie)).valueOrNull;
      if (genres == null || genres.isEmpty) return const SizedBox.shrink();
      for (final g in genres.take(12)) {
        entries.add((g.name, () {
          ref.read(auroraGenreProvider(StreamKind.movie).notifier).state = g.id;
          ref.read(auroraTabProvider.notifier).state = AuroraTab.movies.index;
        }));
      }
    } else {
      final cats =
          ref.watch(auroraCategoriesProvider(StreamKind.movie)).valueOrNull;
      if (cats == null || cats.isEmpty) return const SizedBox.shrink();
      for (final c in cats.take(12)) {
        entries.add((c.name, () {
          ref.read(auroraGroupProvider(StreamKind.movie).notifier).state =
              c.name;
          ref.read(auroraTabProvider.notifier).state = AuroraTab.movies.index;
        }));
      }
    }
    if (entries.isEmpty) return const SizedBox.shrink();

    const cardW = 160.0;
    const cardH = 208.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 26, margin, 12),
          child: const Text('Browse Categories', style: Aurora.shelfTitle),
        ),
        SizedBox(
          height: cardH + 8,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: EdgeInsets.symmetric(horizontal: margin, vertical: 4),
            itemCount: entries.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, i) {
              final (label, onTap) = entries[i];
              final style = _catPalette[label.hashCode.abs() % _catPalette.length];
              return _CategoryTile(
                label: label,
                gradient: style.gradient,
                mark: _markFor(label),
                width: cardW,
                height: cardH,
                onTap: onTap,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.label,
    required this.gradient,
    required this.mark,
    required this.width,
    required this.height,
    required this.onTap,
  });

  final String label;
  final List<Color> gradient;
  final IconData mark;
  final double width;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AuroraFocusable(
      radius: 18,
      scale: 1.06,
      onActivate: onTap,
      builder: (context, focused) => SizedBox(
        width: width,
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(fit: StackFit.expand, children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: gradient,
                ),
              ),
            ),
            // Abstract depiction — overlapping translucent shapes + a big mark.
            Positioned(
              right: -26,
              top: -20,
              child: _blob(96, const Color(0x26FFFFFF)),
            ),
            Positioned(
              left: -30,
              bottom: 30,
              child: _blob(120, const Color(0x1AFFFFFF)),
            ),
            Positioned(
              right: 12,
              top: 14,
              child: Icon(mark,
                  size: 46, color: Colors.white.withValues(alpha: 0.28)),
            ),
            // Legibility scrim + label.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.center,
                  colors: [Color(0x99000000), Color(0x00000000)],
                ),
              ),
            ),
            Positioned(
              left: 14,
              right: 14,
              bottom: 14,
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                    height: 1.1),
              ),
            ),
            if (focused)
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white, width: 2.4),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _blob(double size, Color color) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

// ---------------------------------------------------------------------------
// Trakt watchlist shelf (titles resolved to the library on demand)
// ---------------------------------------------------------------------------

class _TraktShelf extends ConsumerWidget {
  const _TraktShelf({required this.items, required this.width});
  final List<TraktItem> items;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AuroraShelf<TraktItem>(
      title: 'Trakt Watchlist',
      leading: const Icon(Icons.check_circle, color: Color(0xFFED1C24), size: 16),
      items: items,
      rowHeight: width * 1.5 + 56,
      skeletonWidth: width,
      itemBuilder: (context, it, i) => _TraktCard(item: it, width: width),
    );
  }
}

class _TraktCard extends ConsumerWidget {
  const _TraktCard({required this.item, required this.width});
  final TraktItem item;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final poster = ref
        .watch(tmdbDetailProvider(
            (title: item.title, isShow: item.type == 'show')))
        .valueOrNull
        ?.poster;

    return AuroraFocusable(
      radius: 12,
      scale: 1.07,
      onActivate: () async {
        final repo = await ref.read(repositoryProvider.future);
        final pl = ref.read(activePlaylistProvider);
        if (pl?.id == null) return;
        final hits = await repo.search(playlistId: pl!.id!, query: item.title);
        final hit = LibraryRepository.preferEnglish(hits);
        if (!context.mounted) return;
        if (hit != null) {
          openAuroraItem(context, ref, hit);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('"${item.title}" isn\'t in your library.')));
        }
      },
      builder: (context, focused) => SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AuroraImage(
              url: poster,
              width: width,
              height: width * 1.5,
              radius: 12,
              fallbackText: item.title,
            ),
            const SizedBox(height: 7),
            Text(item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: focused ? Aurora.text : Aurora.textDim)),
            Text(
                '${item.type == 'show' ? 'TV' : 'Movie'}'
                '${item.year != null ? ' · ${item.year}' : ''}',
                style: Aurora.caption),
          ],
        ),
      ),
    );
  }
}
