import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../aurora_focus.dart';
import '../aurora_navigation.dart';
import '../aurora_providers.dart';
import '../aurora_theme.dart';
import '../widgets/aurora_cards.dart';

/// Movies / TV Shows: a rail of category chips over an infinitely-paged
/// poster grid. Backed by the same windowed pager that keeps 40k-item
/// libraries scrolling at 60fps.
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

  ChannelPageKey? get _key {
    final pl = ref.read(activePlaylistProvider);
    if (pl?.id == null) return null;
    final group = ref.read(auroraGroupProvider(widget.kind));
    return ChannelPageKey(pl!.id!, widget.kind, group);
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 900) {
      final k = _key;
      if (k != null) ref.read(channelPagerProvider(k).notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pl = ref.watch(activePlaylistProvider);
    if (pl?.id == null) {
      return const Center(child: Text('Add a source to get started.'));
    }
    final margin = Aurora.margin(context);
    final group = ref.watch(auroraGroupProvider(widget.kind));
    final cats = ref.watch(auroraCategoriesProvider(widget.kind)).valueOrNull;
    final pageKey = ChannelPageKey(pl!.id!, widget.kind, group);
    final state = ref.watch(channelPagerProvider(pageKey));
    final isMovies = widget.kind == StreamKind.movie;

    return LayoutBuilder(builder: (context, box) {
      // Exact cell math so cards fill the row edge-to-edge.
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
              child: Text(isMovies ? 'Movies' : 'TV Shows',
                  style: Aurora.display.copyWith(fontSize: 30)),
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 46,
              child: cats == null
                  ? const SizedBox.shrink()
                  : FocusTraversalGroup(
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        clipBehavior: Clip.none,
                        padding: EdgeInsets.symmetric(
                            horizontal: margin, vertical: 5),
                        itemCount: cats.length + 1,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (context, i) {
                          if (i == 0) {
                            return _CategoryChip(
                              label: isMovies ? 'All Movies' : 'All Shows',
                              selected: group == null,
                              onPick: () => ref
                                  .read(auroraGroupProvider(widget.kind)
                                      .notifier)
                                  .state = null,
                            );
                          }
                          final c = cats[i - 1];
                          return _CategoryChip(
                            label: c.name,
                            count: c.count,
                            selected: group == c.name,
                            onPick: () => ref
                                .read(
                                    auroraGroupProvider(widget.kind).notifier)
                                .state = c.name,
                          );
                        },
                      ),
                    ),
            ),
          ),
          if (state.items.isEmpty && state.loading)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(margin, 14, margin, 40),
              sliver: _skeletonGrid(cols, gap, cellW, cellH),
            )
          else if (state.items.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                  child: Text('Nothing here yet.',
                      style: TextStyle(color: Aurora.textFaint))),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(margin, 14, margin, 40),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  crossAxisSpacing: gap,
                  mainAxisSpacing: 20,
                  mainAxisExtent: cellH,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    if (i >= state.items.length) {
                      return const Center(
                        child: SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2)),
                      );
                    }
                    final it = state.items[i];
                    return AuroraPosterCard(
                      item: it,
                      width: cellW,
                      onTap: () => openAuroraItem(context, ref, it),
                    );
                  },
                  childCount: state.items.length + (state.reachedEnd ? 0 : 1),
                ),
              ),
            ),
        ],
      );
    });
  }

  Widget _skeletonGrid(int cols, double gap, double cellW, double cellH) {
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
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onPick,
    this.count,
  });

  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return AuroraFocusable(
      ring: false,
      scale: 1.0,
      onActivate: onPick,
      builder: (context, focused) => AnimatedContainer(
        duration: Aurora.fast,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
        decoration: BoxDecoration(
          color: focused
              ? Colors.white
              : (selected ? Aurora.glassHi : Aurora.glass),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: selected && !focused
                  ? const Color(0x59FFFFFF)
                  : Aurora.hairline),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
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
                    color: focused ? const Color(0x99060708) : Aurora.textFaint)),
          ],
        ]),
      ),
    );
  }
}
