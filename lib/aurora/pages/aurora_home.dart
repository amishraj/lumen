import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/image_cache.dart';
import '../../data/models/models.dart';
import '../../data/repositories/library_repository.dart';
import '../../data/sources/realdebrid_service.dart';
import '../../data/sources/tmdb_service.dart';
import '../../data/sources/trakt_service.dart';
import '../../state/detail_bundle.dart';
import '../../state/providers.dart';
import '../../shared/title_utils.dart';
import '../aurora_focus.dart';
import '../aurora_navigation.dart';
import '../aurora_playback.dart';
import '../aurora_providers.dart';
import '../aurora_theme.dart';
import '../screens/aurora_continue.dart';
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
    final cwSplit = ref.watch(continueWatchingSplitProvider).valueOrNull;
    final cwOwn = cwSplit?.own;
    final cwExternal = cwSplit?.external;

    // A genuinely empty home (source unsynced/empty, no debrid rows, nothing
    // from Trakt): featured has resolved to nothing AND every headline row is
    // empty too. Show a focusable call-to-action so the screen is never a dead
    // blank — it gives focus somewhere to land and a route to setup. (During
    // initial load `featured` is null, not empty, so this stays false and the
    // skeletons show instead.)
    bool empty(List<Object?>? l) => l == null || l.isEmpty;
    final nothingLoaded = featured != null &&
        featured.isEmpty &&
        empty(cwOwn) &&
        empty(cwExternal) &&
        empty(v(auroraMyListProvider)) &&
        empty(v(tmdbTrendingProvider)) &&
        empty(v(tmdbPopularProvider)) &&
        empty(watchlist);

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
              : nothingLoaded
                  ? _EmptyHome(
                      onSetup: () => auroraSwitchTab(ref, AuroraTab.settings))
                  : featured.isEmpty
                      ? const SizedBox(height: 96)
                      : _Billboard(items: featured, onFocusTop: _toTop),
        ),
        SliverList(
          delegate: SliverChildListDelegate.fixed([
            // Capped to the most recent slice: a Trakt account wired up to a
            // streaming service can carry 100+ in-progress titles, which is
            // neither browsable as a rail nor cheap to build. The header's ›
            // opens the full list.
            AuroraShelf<StreamItem>(
              title: 'Continue Watching',
              items: cwOwn?.take(kContinueWatchingRailLimit).toList(),
              totalCount: cwOwn?.length,
              onMore: (cwOwn != null && cwOwn.isNotEmpty)
                  ? () => openContinueWatching(context)
                  : null,
              rowHeight: wideRow,
              skeletonWidth: wideW,
              itemBuilder: (context, it, i) => AuroraWideCard(
                item: it,
                width: wideW,
                onTap: () => openAuroraItem(context, ref, it),
                onLongPress: () => dismissFromContinueWatching(ref, it),
              ),
            ),
            // Only present when Trakt actually attributes resume points to an
            // outside service — otherwise this shelf removes itself.
            AuroraShelf<StreamItem>(
              title: cwSplit?.externalLabel == null
                  ? 'Continue elsewhere'
                  : 'Continue on ${cwSplit!.externalLabel}',
              items: cwExternal?.take(kContinueWatchingRailLimit).toList(),
              totalCount: cwExternal?.length,
              hideWhileLoading: true,
              onMore: (cwExternal != null && cwExternal.isNotEmpty)
                  ? () => openContinueWatching(context)
                  : null,
              rowHeight: wideRow,
              skeletonWidth: wideW,
              itemBuilder: (context, it, i) => AuroraWideCard(
                item: it,
                width: wideW,
                onTap: () => openAuroraItem(context, ref, it),
                onLongPress: () => dismissFromContinueWatching(ref, it),
              ),
            ),
            posterShelf('My List', v(auroraMyListProvider)),
            // IPTV-derived: hidden (not skeletoned) until its data is ready —
            // IPTV must never hold visual space on the debrid-first home.
            AuroraShelf<StreamItem>(
              title: 'Live Now',
              items: v(auroraLiveNowProvider),
              rowHeight: liveRow,
              skeletonWidth: liveW,
              hideWhileLoading: true,
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
            // IPTV library samples: hidden while loading, like Live Now.
            AuroraShelf<StreamItem>(
              title: 'Movies for You',
              items: v(kindSampleProvider(StreamKind.movie)),
              rowHeight: posterRow,
              skeletonWidth: posterW,
              hideWhileLoading: true,
              itemBuilder: (context, it, i) => AuroraPosterCard(
                item: it,
                width: posterW,
                onTap: () => openAuroraItem(context, ref, it),
              ),
            ),
            AuroraShelf<StreamItem>(
              title: 'TV Shows',
              items: v(kindSampleProvider(StreamKind.series)),
              rowHeight: posterRow,
              skeletonWidth: posterW,
              hideWhileLoading: true,
              itemBuilder: (context, it, i) => AuroraPosterCard(
                item: it,
                width: posterW,
                onTap: () => openAuroraItem(context, ref, it),
              ),
            ),
            if (because != null && because.seed != null)
              posterShelf(
                  'Because you watched ${cleanTitle(because.seed!).title}',
                  because.items),
            for (final g in genres)
              wideShelf(g.name, v(tmdbGenreRowProvider(g.id))),
            if (watchlist != null && watchlist.isNotEmpty)
              _TraktShelf(items: watchlist, width: posterW),
            SizedBox(height: Aurora.bottomPad(context)),
          ]),
        ),
      ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty home
// ---------------------------------------------------------------------------

/// Shown when the home has genuinely nothing to display. A focusable CTA — so
/// the remote always has a target and the user can reach setup — that
/// autofocuses (there's no billboard to take focus in this state).
class _EmptyHome extends StatelessWidget {
  const _EmptyHome({required this.onSetup});
  final VoidCallback onSetup;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 128, 24, 48),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.movie_filter_rounded,
                size: 56, color: Aurora.textFaint),
            const SizedBox(height: 18),
            const Text('Nothing here yet',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 23,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            const Text(
              'Add a source, or connect Real-Debrid, Trakt and TMDB to fill '
              'your home.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Aurora.textDim, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: 280,
              child: AuroraFocusable(
                autofocus: true,
                onActivate: onSetup,
                builder: (context, focused) => Container(
                  height: 54,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: Aurora.gradient,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.settings_rounded, size: 20, color: Colors.white),
                      SizedBox(width: 10),
                      Text('Open Settings',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ),
            ),
          ]),
        ),
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
  bool _compact = false;
  Timer? _rotate;
  final PageController _pager = PageController();

  @override
  void initState() {
    super.initState();
    // Slow ambient rotation — never while the user's focus is on the hero.
    // On phones the hero is a swipe deck (touch-driven), so it doesn't
    // auto-advance and fight the user's gesture.
    _rotate = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted || _compact || _heroFocused || widget.items.length < 2) {
        return;
      }
      _go(1);
    });
  }

  @override
  void dispose() {
    _rotate?.cancel();
    _pager.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final n = widget.items.length;
    if (n < 2) return;
    // Wrap in both directions — ◀ from the first item lands on the last and
    // ▶ from the last starts over, so the deck never dead-ends.
    final next = ((_index + delta) % n + n) % n;
    if (next == _index) return;
    // Warm the next backdrop so the crossfade never shows a loading tile.
    // Through LumenImageCache — the default manager caps at 200 objects, so
    // warming through it downloaded every backdrop twice AND churned that
    // tiny cache instead of sharing the disk copy AuroraImage reads.
    final after = widget.items[(next + 1) % n];
    if (after.logo != null && after.logo!.isNotEmpty) {
      precacheImage(
          CachedNetworkImageProvider(after.logo!,
              cacheManager: LumenImageCache.instance),
          context);
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
      // Through the central resolver: Real-Debrid first with IPTV fallback —
      // also the only way debrid-only featured picks (url: '') can play at
      // all, instead of handing libmpv an empty url.
      unawaited(AuroraPlayback.play(context, ref, item));
    } else {
      openAuroraItem(context, ref, item);
    }
  }

  @override
  Widget build(BuildContext context) {
    _compact = Aurora.isCompact(context);
    if (_compact) return _buildCompact(context);
    return _buildWide(context);
  }

  /// Phone hero: a swipeable deck. One clean piece of art per featured item,
  /// Play + My List, and page dots — no arrow-key chrome, no Ken Burns.
  ///
  /// In a **portrait** viewport the deck switches to the 2:3 poster and gets
  /// noticeably taller: a 16:9 backdrop squeezed into a tall narrow frame is
  /// either letterboxed or cropped down to a meaningless slice of the middle.
  Widget _buildCompact(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final portrait = Aurora.isPortrait(context);
    final h = portrait
        ? (size.height * 0.64).clamp(430.0, 720.0)
        : (size.height * 0.5).clamp(340.0, 460.0);
    return SizedBox(
      height: h,
      child: ClipRect(
        child: Stack(fit: StackFit.expand, children: [
          PageView.builder(
            controller: _pager,
            itemCount: widget.items.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) => _CompactHero(
              item: widget.items[i],
              rank: i,
              portrait: portrait,
              onPlay: () => _playDirect(widget.items[i]),
            ),
          ),
          // Page dots, centered above the seam.
          if (widget.items.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 14,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < widget.items.length; i++)
                  AnimatedContainer(
                    duration: Aurora.normal,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _index ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color:
                          i == _index ? Colors.white : const Color(0x4DFFFFFF),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _buildWide(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final h = (size.height * 0.66).clamp(420.0, 680.0);
    final margin = Aurora.margin(context);
    final item = widget.items[_index.clamp(0, widget.items.length - 1)];
    final bundle = ref
        .watch(detailBundleProvider(
            (title: item.name, isShow: item.kind == StreamKind.series)))
        .valueOrNull;
    // Prefer the backdrop the featured item already carries — when TMDB
    // governs, that IS the high-quality TMDB w1280 backdrop, present from the
    // first frame. Only fall back to the detail-bundle backdrop when the item
    // has no art of its own. Keying the switcher below on `art` meant the old
    // `bundle.backdrop ?? item.logo` order swapped a perfectly good backdrop
    // for the detail one the moment the bundle loaded — a visible flicker;
    // this makes the HQ banner appear without that mid-view churn.
    final art = (item.logo != null && item.logo!.isNotEmpty)
        ? item.logo
        : bundle?.tmdb?.backdrop;
    // Warm the detail backdrop anyway so a source without its own art (Trakt
    // fallback) crossfades to a cached image instead of a blank tile.
    if ((item.logo == null || item.logo!.isEmpty) &&
        bundle?.tmdb?.backdrop != null) {
      precacheImage(
          CachedNetworkImageProvider(bundle!.tmdb!.backdrop!,
              cacheManager: LumenImageCache.instance),
          context);
    }
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
      // Hard-clip the whole hero: the Ken Burns zoom scales the backdrop up to
      // 1.055×, which pushes its edges *past* the hero's bottom into the seam
      // above the first shelf — where the scrim (which only covers the hero's
      // own bounds) can't reach it. That overflow was the bright bar. The clip
      // guarantees nothing paints outside the hero; anchoring the scale to the
      // bottom edge additionally keeps the bottom pinned so it never grows down
      // in the first place.
      child: ClipRect(
        // Touch devices on the wide layout (phones/tablets in landscape) page
        // the deck by swiping, same as the compact PageView.
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: (d) {
            final vx = d.primaryVelocity ?? 0;
            if (vx.abs() < 120) return;
            _go(vx < 0 ? 1 : -1);
          },
          child: Stack(fit: StackFit.expand, children: [
        // Backdrop with a slow settle (Ken Burns lite) — plain, undecorated
        // image. The fade to the page is handled by exactly ONE scrim below.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 700),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: SizedBox(
            key: ValueKey(art ?? item.name),
            width: size.width,
            height: h,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 1.055, end: 1.0),
              duration: const Duration(seconds: 15),
              curve: Curves.easeOut,
              builder: (context, scale, child) => Transform.scale(
                  scale: scale,
                  alignment: Alignment.bottomCenter,
                  child: child),
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
        // Single, monotonic bottom-to-top scrim: fully transparent over the
        // top ~40% (image shows clean), then one continuous ramp to the fully
        // opaque page colour by the bottom edge. Deliberately ONE gradient —
        // the previous approach paired this with a second fade baked into the
        // image itself (a ShaderMask), and the two were never quite in step:
        // wherever both happened to be only partially opaque at the same
        // height, the image's true (bright) colour punched through as a
        // visible band. One gradient can't have that kind of gap — every
        // step down is provably at least as opaque as the last.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.transparent,
                Color(0xFF06070B),
                Color(0xFF06070B),
              ],
              stops: [0.0, 0.4, 0.92, 1.0],
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
      ),
      ),
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

/// One page of the phone hero deck. Self-contained so the PageView can build
/// each featured item lazily (its own artwork + synopsis bundle).
class _CompactHero extends ConsumerWidget {
  const _CompactHero({
    required this.item,
    required this.rank,
    required this.onPlay,
    this.portrait = false,
  });
  final StreamItem item;
  final int rank;
  final VoidCallback onPlay;

  /// Tall-and-narrow viewport: prefer the 2:3 poster and give the text block
  /// a deeper gradient to sit on.
  final bool portrait;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final margin = Aurora.margin(context);
    final bundle = ref
        .watch(detailBundleProvider(
            (title: item.name, isShow: item.kind == StreamKind.series)))
        .valueOrNull;
    // Portrait wants portrait art. Every candidate is tried in turn so the
    // hero always has *something* to show — a featured pick from the debrid /
    // Trakt path may carry only `item.logo`, and TMDB may only have a backdrop.
    final art = portrait
        ? (bundle?.tmdb?.poster ?? item.logo ?? bundle?.tmdb?.backdrop)
        : (bundle?.tmdb?.backdrop ?? item.logo ?? bundle?.tmdb?.poster);
    final omdb = bundle?.omdb;
    final favs = ref.watch(favoriteIdsProvider).valueOrNull ?? const <int>{};
    final isFav = item.id != null && favs.contains(item.id);
    final title = cleanTitle(item.name).title;

    return Stack(fit: StackFit.expand, children: [
      AuroraImage(
        url: art,
        width: double.infinity,
        height: double.infinity,
        radius: 0,
        // Portrait art in a slightly-less-tall frame: anchor the crop to the
        // top so the composition (faces, title treatment) survives instead of
        // being trimmed from both ends.
        alignment: portrait ? Alignment.topCenter : Alignment.center,
        fallbackText: title,
      ),
      // A longer, softer ramp in portrait: the text block is taller, so the
      // art has to be fully surrendered by the time the buttons start.
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: const [
              Colors.transparent,
              Colors.transparent,
              Color(0xFF06070B),
              Color(0xFF06070B),
            ],
            stops: portrait
                ? const [0.0, 0.30, 0.86, 1.0]
                : const [0.0, 0.35, 0.92, 1.0],
          ),
        ),
      ),
      // Portrait only: a gentle top vignette so the status bar / header icons
      // stay legible over bright poster art.
      if (portrait)
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 150,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x9906070B), Color(0x0006070B)],
              ),
            ),
          ),
        ),
      Positioned(
        left: margin,
        right: margin,
        bottom: portrait ? 46 : 40,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Eyebrow(item.kind == StreamKind.series
                ? 'Featured series'
                : '#${rank + 1} this week'),
            const SizedBox(height: 8),
            Text(title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: portrait ? 30 : 26,
                    fontWeight: FontWeight.w800,
                    height: 1.05,
                    letterSpacing: -0.6,
                    color: Aurora.text)),
            const SizedBox(height: 10),
            RatingsStrip(info: omdb, fallbackRating: item.rating),
            const SizedBox(height: 16),
            Row(children: [
              AuroraPillButton(
                label: 'Play',
                icon: Icons.play_arrow_rounded,
                primary: true,
                compact: true,
                autoScroll: false,
                onPressed: onPlay,
              ),
              const SizedBox(width: 10),
              AuroraPillButton(
                label: isFav ? 'Added' : 'My List',
                icon: isFav ? Icons.check_rounded : Icons.add_rounded,
                compact: true,
                autoScroll: false,
                onPressed: () => setFavorite(ref, item, !isFav),
              ),
            ]),
          ],
        ),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Categories rail — large Hulu-style colour tiles under Live Now. Preloaded
// (genres/categories are cheap), each tile a distinct aesthetic gradient with
// an abstract mark; tapping jumps to Movies filtered to that category.
// ---------------------------------------------------------------------------

/// The abstract geometry painted behind a category tile. Each motif is drawn
/// in white at low opacity, so one painter works over every palette.
enum _Motif { rays, orbit, wave, grid, bloom, shafts }

/// A category's full visual identity: a three-stop ramp (deep → mid → lit),
/// a motif and a glyph. Three stops instead of two is most of why these read
/// as artwork rather than as coloured rectangles — the extra stop gives the
/// tile a light source.
class _CatStyle {
  final Color deep;
  final Color mid;
  final Color lit;
  final _Motif motif;
  final IconData mark;
  const _CatStyle(this.deep, this.mid, this.lit, this.motif, this.mark);
}

/// Fallback ramps for categories we don't recognise (IPTV group names are
/// wildly inconsistent), picked by a stable hash so a given name always keeps
/// the same look between launches.
const _catFallbacks = <_CatStyle>[
  _CatStyle(Color(0xFF2A0E1C), Color(0xFF7A1F3D), Color(0xFFFF6A5B),
      _Motif.rays, Icons.movie_rounded),
  _CatStyle(Color(0xFF07182F), Color(0xFF1B3A7A), Color(0xFF4CC2FF),
      _Motif.orbit, Icons.bolt_rounded),
  _CatStyle(Color(0xFF141033), Color(0xFF3A2E7A), Color(0xFF8A7BFF),
      _Motif.bloom, Icons.auto_awesome_rounded),
  _CatStyle(Color(0xFF04231C), Color(0xFF105948), Color(0xFF34D399),
      _Motif.wave, Icons.forest_rounded),
  _CatStyle(Color(0xFF2B1607), Color(0xFF7A431B), Color(0xFFFFB35C),
      _Motif.shafts, Icons.wb_sunny_rounded),
  _CatStyle(Color(0xFF2A0A20), Color(0xFF7A1F5D), Color(0xFFFF7BC2),
      _Motif.bloom, Icons.favorite_rounded),
  _CatStyle(Color(0xFF03222A), Color(0xFF0B4A57), Color(0xFF00D4C8),
      _Motif.wave, Icons.water_rounded),
  _CatStyle(Color(0xFF1B1F06), Color(0xFF4A551B), Color(0xFFB8C24C),
      _Motif.grid, Icons.eco_rounded),
  _CatStyle(Color(0xFF10122E), Color(0xFF2E317A), Color(0xFF9AA0FF),
      _Motif.orbit, Icons.nights_stay_rounded),
  _CatStyle(Color(0xFF2A1108), Color(0xFF7A2E1B), Color(0xFFFF8A5B),
      _Motif.rays, Icons.explore_rounded),
];

/// Genre identity. Named genres get a palette that *means* something (horror
/// is cold and dark, comedy is warm and bright), which is what makes the rail
/// scan as a set of posters rather than a swatch book.
_CatStyle _styleFor(String name) {
  final n = name.toLowerCase();
  bool has(String s) => n.contains(s);
  if (has('action')) {
    return const _CatStyle(Color(0xFF2A0906), Color(0xFF8E2317),
        Color(0xFFFF7A4D), _Motif.rays, Icons.local_fire_department_rounded);
  }
  if (has('comedy')) {
    return const _CatStyle(Color(0xFF2E1D02), Color(0xFF9A6B0C),
        Color(0xFFFFD166), _Motif.bloom,
        Icons.sentiment_very_satisfied_rounded);
  }
  if (has('drama')) {
    return const _CatStyle(Color(0xFF1A1020), Color(0xFF54306B),
        Color(0xFFB98BE0), _Motif.wave, Icons.theater_comedy_rounded);
  }
  if (has('horror')) {
    return const _CatStyle(Color(0xFF070A0C), Color(0xFF23343A),
        Color(0xFF6FD2C2), _Motif.shafts, Icons.dark_mode_rounded);
  }
  if (has('thriller') || has('crime')) {
    return const _CatStyle(Color(0xFF0B0D18), Color(0xFF2C2F5C),
        Color(0xFF7C86FF), _Motif.shafts, Icons.gpp_maybe_rounded);
  }
  if (has('sci') || has('fantasy')) {
    return const _CatStyle(Color(0xFF050D26), Color(0xFF20439B),
        Color(0xFF63D8FF), _Motif.orbit, Icons.rocket_launch_rounded);
  }
  if (has('romance')) {
    return const _CatStyle(Color(0xFF2A0716), Color(0xFF8E1F55),
        Color(0xFFFF8FC4), _Motif.bloom, Icons.favorite_rounded);
  }
  if (has('animation') || has('kids') || has('family')) {
    return const _CatStyle(Color(0xFF04202A), Color(0xFF0E6E82),
        Color(0xFF62E6D0), _Motif.bloom, Icons.child_care_rounded);
  }
  if (has('doc')) {
    return const _CatStyle(Color(0xFF11190F), Color(0xFF3B5C2F),
        Color(0xFF9FD87A), _Motif.grid, Icons.menu_book_rounded);
  }
  if (has('adventure')) {
    return const _CatStyle(Color(0xFF06231F), Color(0xFF13705C),
        Color(0xFF5DE0B0), _Motif.wave, Icons.explore_rounded);
  }
  if (has('music')) {
    return const _CatStyle(Color(0xFF1D0724), Color(0xFF6C1F86),
        Color(0xFFE07BFF), _Motif.wave, Icons.music_note_rounded);
  }
  if (has('war')) {
    return const _CatStyle(Color(0xFF14150D), Color(0xFF4A4C2E),
        Color(0xFFC7C583), _Motif.grid, Icons.military_tech_rounded);
  }
  if (has('west')) {
    return const _CatStyle(Color(0xFF2A1405), Color(0xFF8A4A12),
        Color(0xFFFFB765), _Motif.shafts, Icons.landscape_rounded);
  }
  if (has('myst')) {
    return const _CatStyle(Color(0xFF0A0F1D), Color(0xFF283C6B),
        Color(0xFF86B4FF), _Motif.orbit, Icons.search_rounded);
  }
  if (has('histor')) {
    return const _CatStyle(Color(0xFF201709), Color(0xFF6B5220),
        Color(0xFFD8B978), _Motif.grid, Icons.account_balance_rounded);
  }
  if (has('sport')) {
    return const _CatStyle(Color(0xFF06210E), Color(0xFF176B32),
        Color(0xFF63E58B), _Motif.rays, Icons.sports_basketball_rounded);
  }
  return _catFallbacks[name.hashCode.abs() % _catFallbacks.length];
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
          auroraSwitchTab(ref, AuroraTab.movies);
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
          auroraSwitchTab(ref, AuroraTab.movies);
        }));
      }
    }
    if (entries.isEmpty) return const SizedBox.shrink();

    // Scales with the viewport: on a phone two-and-a-bit tiles should be
    // visible so the rail obviously scrolls; on TV they stay poster-sized.
    final w = MediaQuery.of(context).size.width;
    final cardW = (w / 2.7).clamp(150.0, 186.0);
    final cardH = cardW * 1.3;
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
              return _CategoryTile(
                label: label,
                style: _styleFor(label),
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
    required this.style,
    required this.width,
    required this.height,
    required this.onTap,
  });

  final String label;
  final _CatStyle style;
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
            // 1 — the base ramp: deep in the bottom-right, lit toward the
            // top-left, so every tile has a consistent light direction.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [style.mid, style.deep],
                ),
              ),
            ),
            // 2 — the light source itself, offset off-canvas so the falloff
            // inside the card is a slice of a much larger glow.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.75, -0.95),
                  radius: 1.35,
                  colors: [
                    style.lit.withValues(alpha: 0.85),
                    style.lit.withValues(alpha: 0.16),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
            // 3 — the genre motif, drawn in white over the ramp.
            Positioned.fill(
              child: CustomPaint(
                painter: _MotifPainter(style.motif),
                isComplex: false,
              ),
            ),
            // 4 — an oversized glyph, deliberately cropped by the card edge
            // so it reads as artwork rather than as an icon in a box.
            Positioned(
              right: -width * 0.16,
              top: height * 0.10,
              child: Icon(style.mark,
                  size: width * 0.72,
                  color: Colors.white.withValues(alpha: 0.13)),
            ),
            // 5 — legibility scrim under the label.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.center,
                  colors: [Color(0xC2000000), Color(0x00000000)],
                ),
              ),
            ),
            Positioned(
              left: 14,
              right: 12,
              bottom: 13,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        height: 1.1,
                        shadows: [
                          Shadow(color: Color(0x8C000000), blurRadius: 8)
                        ]),
                  ),
                  const SizedBox(height: 3),
                  Row(children: [
                    Text('Browse',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                            color: Colors.white.withValues(alpha: 0.62))),
                    const SizedBox(width: 2),
                    Icon(Icons.chevron_right_rounded,
                        size: 14, color: Colors.white.withValues(alpha: 0.62)),
                  ]),
                ],
              ),
            ),
            // 6 — inner hairline gives the tile an edge against dark artwork;
            // focus swaps it for Aurora's white ring.
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                      color: focused ? Colors.white : const Color(0x24FFFFFF),
                      width: focused ? 2.4 : 1),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Draws a category's motif: white, low-alpha geometry that gives each tile a
/// distinct texture without needing any artwork to download. Cheap by design —
/// a handful of strokes per tile, no blurs, no shaders.
class _MotifPainter extends CustomPainter {
  const _MotifPainter(this.motif);
  final _Motif motif;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.white.withValues(alpha: 0.16)
      ..strokeWidth = 1.2;
    final fill = Paint()..color = Colors.white.withValues(alpha: 0.07);

    switch (motif) {
      case _Motif.rays:
        // Concentric arcs blasting out of the bottom-left corner.
        final o = Offset(w * 0.06, h * 1.02);
        for (var i = 1; i <= 6; i++) {
          canvas.drawCircle(o, w * 0.22 * i, stroke);
        }
      case _Motif.orbit:
        // Tilted rings — planetary, for sci-fi / mystery.
        canvas.save();
        canvas.translate(w * 0.62, h * 0.42);
        canvas.rotate(-0.42);
        for (var i = 1; i <= 3; i++) {
          canvas.drawOval(
              Rect.fromCenter(
                  center: Offset.zero, width: w * 0.5 * i, height: w * 0.19 * i),
              stroke);
        }
        canvas.drawCircle(Offset.zero, w * 0.13, fill);
        canvas.restore();
      case _Motif.wave:
        // Stacked sine bands rolling across the lower half.
        for (var band = 0; band < 4; band++) {
          final path = Path();
          final baseY = h * (0.42 + band * 0.16);
          path.moveTo(0, baseY);
          for (var x = 0.0; x <= w; x += w / 12) {
            path.quadraticBezierTo(
              x + w / 24,
              baseY + (band.isEven ? -h * 0.055 : h * 0.055),
              x + w / 12,
              baseY,
            );
          }
          canvas.drawPath(path, stroke);
        }
      case _Motif.grid:
        // Diagonal hairline weave — archival, for docs / history / war.
        for (var i = -1; i < 10; i++) {
          final x = w * 0.16 * i;
          canvas.drawLine(Offset(x, 0), Offset(x + h * 0.55, h), stroke);
        }
      case _Motif.bloom:
        // Overlapping soft discs — playful, for comedy / family / romance.
        canvas.drawCircle(Offset(w * 0.78, h * 0.16), w * 0.34, fill);
        canvas.drawCircle(Offset(w * 0.24, h * 0.34), w * 0.26, fill);
        canvas.drawCircle(Offset(w * 0.62, h * 0.52), w * 0.20, fill);
        canvas.drawCircle(Offset(w * 0.78, h * 0.16), w * 0.34, stroke);
        canvas.drawCircle(Offset(w * 0.24, h * 0.34), w * 0.26, stroke);
      case _Motif.shafts:
        // Hard-edged light shafts raking across — tense, for horror/thriller.
        for (var i = 0; i < 4; i++) {
          final x = w * (0.1 + i * 0.26);
          final path = Path()
            ..moveTo(x, 0)
            ..lineTo(x + w * 0.1, 0)
            ..lineTo(x + w * 0.1 - h * 0.42, h)
            ..lineTo(x - h * 0.42, h)
            ..close();
          canvas.drawPath(path, fill);
        }
    }
  }

  @override
  bool shouldRepaint(_MotifPainter old) => old.motif != motif;
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
        final pl = ref.read(activePlaylistProvider);
        if (pl?.id == null) return;
        // Memory match first (instant); fall back to one DB search while the
        // index is still building.
        final idx = await ref.read(titleIndexProvider.future);
        var hit = idx?.matchVod(item.title);
        if (hit == null && idx == null) {
          final repo = await ref.read(repositoryProvider.future);
          hit = LibraryRepository.preferEnglish(
              await repo.search(playlistId: pl!.id!, query: item.title));
        }
        var rdOn = false;
        try {
          rdOn = await ref.read(rdEnabledProvider.future);
        } catch (_) {}
        if (!context.mounted) return;
        if (hit != null) {
          openAuroraItem(context, ref, hit);
        } else if (rdOn) {
          // Not in the IPTV library — open it anyway, playable via debrid.
          openAuroraItem(
              context,
              ref,
              StreamItem(
                playlistId: pl!.id!,
                kind: item.type == 'show'
                    ? StreamKind.series
                    : StreamKind.movie,
                name: item.title,
                logo: poster,
                url: '',
              ));
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
