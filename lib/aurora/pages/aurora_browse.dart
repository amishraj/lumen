import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../aurora_focus.dart';
import '../aurora_navigation.dart';
import '../aurora_providers.dart';
import '../aurora_theme.dart';
import '../widgets/aurora_cards.dart';

/// Movies / TV Shows browse.
///
/// When a TMDB key is present, listings are governed by TMDB: the chips are
/// TMDB genres and the grid is TMDB discovery (matched to the user's library
/// for playback + overlays). Without a key it falls back to the source's own
/// IPTV categories over the windowed pager. Either way the chips support
/// pinning — pinned first, and (on the chip rail) ▲ pins the focused chip.
class AuroraBrowsePage extends ConsumerStatefulWidget {
  const AuroraBrowsePage({super.key, required this.kind});
  final StreamKind kind;

  @override
  ConsumerState<AuroraBrowsePage> createState() => _AuroraBrowsePageState();
}

class _AuroraBrowsePageState extends ConsumerState<AuroraBrowsePage> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 900) return;
    final governs =
        ref.read(auroraTmdbGovernsProvider).valueOrNull ?? false;
    final pl = ref.read(activePlaylistProvider);
    if (pl?.id == null) return;
    if (governs) {
      final g = ref.read(auroraGenreProvider(widget.kind));
      ref
          .read(auroraCatalogPagerProvider(
                  CatalogKey(widget.kind == StreamKind.series, g))
              .notifier)
          .loadMore();
    } else {
      final group = ref.read(auroraGroupProvider(widget.kind));
      ref
          .read(channelPagerProvider(
                  ChannelPageKey(pl!.id!, widget.kind, group))
              .notifier)
          .loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pl = ref.watch(activePlaylistProvider);
    if (pl?.id == null) {
      return const Center(child: Text('Add a source to get started.'));
    }
    final governs = ref.watch(auroraTmdbGovernsProvider).valueOrNull ?? false;
    final margin = Aurora.margin(context);
    final isMovies = widget.kind == StreamKind.movie;

    return LayoutBuilder(builder: (context, box) {
      const gap = 18.0;
      final avail = box.maxWidth - margin * 2;
      final cols = (avail / 172).floor().clamp(3, 10);
      final cellW = (avail - (cols - 1) * gap) / cols;
      final cellH = cellW * 1.5 + 58;

      return CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(margin, 92, margin, 6),
              child: Row(children: [
                Text(isMovies ? 'Movies' : 'TV Shows',
                    style: Aurora.display.copyWith(fontSize: 30)),
                const SizedBox(width: 12),
                if (governs)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Aurora.glass,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Aurora.hairline),
                    ),
                    child: const Text('TMDB',
                        style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                            color: Color(0xFF01B4E4))),
                  ),
              ]),
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 52,
              child: governs
                  ? _GenreChips(kind: widget.kind)
                  : _CategoryChips(kind: widget.kind),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(margin, 14, margin, 40),
            sliver: governs
                ? _TmdbGrid(kind: widget.kind, cols: cols, gap: gap, cellH: cellH,
                    cellW: cellW)
                : _IptvGrid(kind: widget.kind, cols: cols, gap: gap,
                    cellH: cellH, cellW: cellW),
          ),
        ],
      );
    });
  }
}

// ---------------------------------------------------------------------------
// TMDB-governed chips + grid
// ---------------------------------------------------------------------------

class _GenreChips extends ConsumerWidget {
  const _GenreChips({required this.kind});
  final StreamKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final margin = Aurora.margin(context);
    final genres =
        ref.watch(auroraOrderedGenresProvider(kind)).valueOrNull;
    final pinned = ref.watch(auroraPinnedProvider(kind)).valueOrNull ??
        const <String>{};
    final selected = ref.watch(auroraGenreProvider(kind));
    if (genres == null) return const SizedBox.shrink();

    return FocusTraversalGroup(
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: EdgeInsets.symmetric(horizontal: margin, vertical: 6),
        itemCount: genres.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          if (i == 0) {
            return _Chip(
              label: 'Popular',
              selected: selected == null,
              onPick: () =>
                  ref.read(auroraGenreProvider(kind).notifier).state = null,
            );
          }
          final g = genres[i - 1];
          return _Chip(
            label: g.name,
            selected: selected == g.id,
            pinned: pinned.contains(g.name),
            onPick: () =>
                ref.read(auroraGenreProvider(kind).notifier).state = g.id,
            onPin: () => toggleAuroraPin(ref, kind, g.name),
          );
        },
      ),
    );
  }
}

class _TmdbGrid extends ConsumerWidget {
  const _TmdbGrid({
    required this.kind,
    required this.cols,
    required this.gap,
    required this.cellH,
    required this.cellW,
  });
  final StreamKind kind;
  final int cols;
  final double gap;
  final double cellH;
  final double cellW;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final genreId = ref.watch(auroraGenreProvider(kind));
    final key = CatalogKey(kind == StreamKind.series, genreId);
    final state = ref.watch(auroraCatalogPagerProvider(key));

    if (state.items.isEmpty && state.loading) {
      return _skeleton(cols, gap, cellH);
    }
    if (state.items.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.only(top: 60),
          child: Center(
              child: Text('Nothing here yet.',
                  style: TextStyle(color: Aurora.textFaint))),
        ),
      );
    }
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        crossAxisSpacing: gap,
        mainAxisSpacing: 20,
        mainAxisExtent: cellH,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, i) {
          if (i >= state.items.length) return const _GridLoader();
          final it = state.items[i];
          return AuroraPosterCard(
            item: it,
            width: cellW,
            onTap: () => openAuroraItem(context, ref, it),
          );
        },
        childCount: state.items.length + (state.reachedEnd ? 0 : 1),
      ),
    );
  }

  Widget _skeleton(int cols, double gap, double cellH) => SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          crossAxisSpacing: gap,
          mainAxisSpacing: 20,
          mainAxisExtent: cellH,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, i) => Container(
            margin: const EdgeInsets.only(bottom: 58),
            decoration: BoxDecoration(
              color: const Color(0xFF10131C),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          childCount: cols * 3,
        ),
      );
}

// ---------------------------------------------------------------------------
// IPTV-category chips + grid (no TMDB key)
// ---------------------------------------------------------------------------

class _CategoryChips extends ConsumerWidget {
  const _CategoryChips({required this.kind});
  final StreamKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final margin = Aurora.margin(context);
    final cats =
        ref.watch(auroraOrderedCategoriesProvider(kind)).valueOrNull;
    final pinned = ref.watch(auroraPinnedProvider(kind)).valueOrNull ??
        const <String>{};
    final selected = ref.watch(auroraGroupProvider(kind));
    if (cats == null) return const SizedBox.shrink();

    return FocusTraversalGroup(
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: EdgeInsets.symmetric(horizontal: margin, vertical: 6),
        itemCount: cats.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          if (i == 0) {
            return _Chip(
              label: kind == StreamKind.movie ? 'All Movies' : 'All Shows',
              selected: selected == null,
              onPick: () =>
                  ref.read(auroraGroupProvider(kind).notifier).state = null,
            );
          }
          final c = cats[i - 1];
          return _Chip(
            label: c.name,
            count: c.count,
            selected: selected == c.name,
            pinned: pinned.contains(c.name),
            onPick: () =>
                ref.read(auroraGroupProvider(kind).notifier).state = c.name,
            onPin: () => toggleAuroraPin(ref, kind, c.name),
          );
        },
      ),
    );
  }
}

class _IptvGrid extends ConsumerWidget {
  const _IptvGrid({
    required this.kind,
    required this.cols,
    required this.gap,
    required this.cellH,
    required this.cellW,
  });
  final StreamKind kind;
  final int cols;
  final double gap;
  final double cellH;
  final double cellW;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pl = ref.watch(activePlaylistProvider);
    final group = ref.watch(auroraGroupProvider(kind));
    final key = ChannelPageKey(pl!.id!, kind, group);
    final state = ref.watch(channelPagerProvider(key));

    if (state.items.isEmpty && state.loading) {
      return SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          crossAxisSpacing: gap,
          mainAxisSpacing: 20,
          mainAxisExtent: cellH,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, i) => Container(
            margin: const EdgeInsets.only(bottom: 58),
            decoration: BoxDecoration(
              color: const Color(0xFF10131C),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          childCount: cols * 3,
        ),
      );
    }
    if (state.items.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.only(top: 60),
          child: Center(
              child: Text('Nothing here yet.',
                  style: TextStyle(color: Aurora.textFaint))),
        ),
      );
    }
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        crossAxisSpacing: gap,
        mainAxisSpacing: 20,
        mainAxisExtent: cellH,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, i) {
          if (i >= state.items.length) return const _GridLoader();
          final it = state.items[i];
          return AuroraPosterCard(
            item: it,
            width: cellW,
            onTap: () => openAuroraItem(context, ref, it),
          );
        },
        childCount: state.items.length + (state.reachedEnd ? 0 : 1),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared chip + loader
// ---------------------------------------------------------------------------

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onPick,
    this.count,
    this.pinned = false,
    this.onPin,
  });

  final String label;
  final int? count;
  final bool selected;
  final bool pinned;
  final VoidCallback onPick;
  final VoidCallback? onPin;

  @override
  Widget build(BuildContext context) {
    return AuroraFocusable(
      ring: false,
      scale: 1.0,
      onActivate: onPick,
      // ▲ returns to the top nav; long-press (pointer) pins the category.
      onUp: () => auroraNavFocusNode.requestFocus(),
      onLongPress: onPin,
      builder: (context, focused) => AnimatedContainer(
        duration: Aurora.fast,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
        decoration: BoxDecoration(
          color: focused
              ? Colors.white
              : (selected ? Aurora.glassHi : Aurora.glass),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
              color: selected && !focused
                  ? const Color(0x59FFFFFF)
                  : Aurora.hairline),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (pinned) ...[
            Icon(Icons.push_pin_rounded,
                size: 12,
                color: focused ? Aurora.bg : Aurora.accent),
            const SizedBox(width: 5),
          ],
          Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight:
                      selected || focused ? FontWeight.w800 : FontWeight.w600,
                  color: focused
                      ? Aurora.bg
                      : (selected ? Aurora.text : Aurora.textDim))),
          if (count != null) ...[
            const SizedBox(width: 6),
            Text('$count',
                style: TextStyle(
                    fontSize: 11,
                    color: focused
                        ? const Color(0x99060708)
                        : Aurora.textFaint)),
          ],
          if (onPin != null && focused && !pinned) ...[
            const SizedBox(width: 7),
            const Icon(Icons.push_pin_outlined,
                size: 12, color: Color(0x99060708)),
          ],
        ]),
      ),
    );
  }
}

class _GridLoader extends StatelessWidget {
  const _GridLoader();
  @override
  Widget build(BuildContext context) => const Center(
        child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
}
