import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../state/providers.dart';
import '../../navigation.dart';
import '../../theme/lumen_theme.dart';
import '../../widgets/channel_tile.dart';
import '../../widgets/focusable_item.dart';
import '../../widgets/poster_card.dart';
import '../../widgets/tv_text_field.dart';

/// Browsing with a **resizable** vertical category sidebar (with its own
/// category search + pinning) on the left, and a lazily-paged, virtualized
/// content pane (with per-category search) on the right.
class LiveTvScreen extends ConsumerWidget {
  const LiveTvScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pl = ref.watch(activePlaylistProvider);
    if (pl?.id == null) {
      return const Center(child: Text('Add a source to get started.'));
    }
    return Column(
      children: [
        _KindSelector(kind: ref.watch(selectedKindProvider)),
        const Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Sidebar(),
              _DragHandle(),
              Expanded(child: _ContentArea()),
            ],
          ),
        ),
      ],
    );
  }
}

class _KindSelector extends ConsumerWidget {
  const _KindSelector({required this.kind});
  final StreamKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget seg(String label, StreamKind k, IconData icon) {
      final sel = kind == k;
      return Expanded(
        child: FocusableItem(
          borderRadius: 12,
          onActivate: () {
            ref.read(selectedKindProvider.notifier).state = k;
            ref.read(selectedCategoryProvider.notifier).state = null;
          },
          builder: (context, focused) => AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: sel
                  ? LumenTheme.accent.withValues(alpha: 0.18)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon,
                    size: 17,
                    color: sel ? LumenTheme.accent : const Color(0xFF8A8F9E)),
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                        color:
                            sel ? LumenTheme.accent : const Color(0xFF8A8F9E),
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: LumenTheme.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          seg('Live TV', StreamKind.live, Icons.live_tv),
          seg('Movies', StreamKind.movie, Icons.movie_outlined),
          seg('TV Shows', StreamKind.series, Icons.tv),
        ]),
      ),
    );
  }
}

/// Draggable divider that resizes the sidebar.
class _DragHandle extends ConsumerWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) {
          final cur = ref.read(sidebarWidthProvider);
          ref.read(sidebarWidthProvider.notifier).update(cur + d.delta.dx);
        },
        onHorizontalDragEnd: (_) =>
            ref.read(sidebarWidthProvider.notifier).persist(),
        child: Container(
          width: 10,
          alignment: Alignment.center,
          child: Container(
            width: 2,
            height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFF2A2E3A),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}

/// Self-contained so its search field survives category selection. Watches
/// providers directly rather than receiving them, keeping a stable State.
class _Sidebar extends ConsumerStatefulWidget {
  const _Sidebar();
  @override
  ConsumerState<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<_Sidebar> {
  final _filter = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = ref.watch(sidebarWidthProvider);
    final catsAsync = ref.watch(orderedCategoriesProvider);
    final selected = ref.watch(selectedCategoryProvider);
    final pinned =
        ref.watch(pinnedCategoriesProvider).valueOrNull ?? const <String>{};

    return Container(
      width: width,
      decoration: const BoxDecoration(color: Color(0xFF0D0E13)),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            child: TvTextField(
              controller: _filter,
              hint: 'Search categories',
              icon: Icons.search,
              dense: true,
              onChanged: (v) => setState(() => _query = v.toLowerCase()),
              onCleared: () => setState(() => _query = ''),
            ),
          ),
          Expanded(
            child: catsAsync.when(
              data: (cats) {
                final list = _query.isEmpty
                    ? cats
                    : cats
                        .where((c) => c.name.toLowerCase().contains(_query))
                        .toList();
                if (list.isEmpty) {
                  return const Center(
                      child: Text('No categories',
                          style: TextStyle(
                              color: Color(0xFF6B7080), fontSize: 12)));
                }
                final sel = selected ?? (cats.isNotEmpty ? cats.first : null);
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: list.length,
                  itemExtent: 50,
                  itemBuilder: (context, i) {
                    final c = list[i];
                    return _CategoryRow(
                      category: c,
                      selected: c.name == sel?.name,
                      pinned: pinned.contains(c.name),
                    );
                  },
                );
              },
              loading: () => const Center(
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))),
              error: (e, _) => Center(child: Text('$e')),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryRow extends ConsumerStatefulWidget {
  const _CategoryRow({
    required this.category,
    required this.selected,
    required this.pinned,
  });
  final Category category;
  final bool selected;
  final bool pinned;

  @override
  ConsumerState<_CategoryRow> createState() => _CategoryRowState();
}

class _CategoryRowState extends ConsumerState<_CategoryRow> {
  // Dedicated node so Right from the name lands *exactly* on the pin —
  // nextFocus() followed traversal order and could skip it entirely, which
  // made pinning unreachable by remote.
  final FocusNode _pinFocus = FocusNode(debugLabel: 'category-pin');

  Category get category => widget.category;
  bool get selected => widget.selected;
  bool get pinned => widget.pinned;

  @override
  void dispose() {
    _pinFocus.dispose();
    super.dispose();
  }

  Future<void> _togglePin() async {
    try {
      // Read the fresh pinned state — the build-time bool can be stale if the
      // providers refreshed between paint and press.
      final repo = await ref.read(repositoryProvider.future);
      final pl = ref.read(activePlaylistProvider);
      final kind = ref.read(selectedKindProvider);
      if (pl?.id == null) return;
      final current =
          (await repo.pinnedCategories(pl!.id!, kind)).contains(category.name);
      await repo.setPinned(pl.id!, kind, category.name, !current);
      ref.invalidate(pinnedCategoriesProvider);
      ref.invalidate(orderedCategoriesProvider);
    } catch (e) {
      // Surface instead of failing silently — "pin does nothing" is
      // undebuggable from the couch.
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Couldn\'t pin: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // The favorites pseudo-category isn't a real provider group — no pin.
    final isFavs = category.name == kFavoritesCategory;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      padding: const EdgeInsets.only(left: 2, right: 2),
      decoration: BoxDecoration(
        color: selected
            ? LumenTheme.accent.withValues(alpha: 0.16)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: Border(
          left: BorderSide(
              color: selected ? LumenTheme.accent : Colors.transparent,
              width: 3),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: FocusableItem(
              borderRadius: 8,
              onActivate: () =>
                  ref.read(selectedCategoryProvider.notifier).state = category,
              // From the name, Right lands exactly on the pin toggle.
              onRight: isFavs ? null : _pinFocus.requestFocus,
              builder: (context, focused) => Padding(
                padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(category.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w500,
                            color: selected
                                ? Colors.white
                                : const Color(0xFFC7CBD6))),
                    Text('${category.count}',
                        style: const TextStyle(
                            fontSize: 10.5, color: Color(0xFF6B7080))),
                  ],
                ),
              ),
            ),
          ),
          if (!isFavs)
            FocusableItem(
              focusNode: _pinFocus,
              borderRadius: 18,
              onActivate: _togglePin,
              builder: (context, focused) => Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined,
                    size: 16,
                    color: pinned
                        ? LumenTheme.accentWarm
                        : const Color(0xFF5B6072)),
              ),
            ),
        ],
      ),
    );
  }
}

class _ContentArea extends ConsumerWidget {
  const _ContentArea();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pl = ref.watch(activePlaylistProvider);
    final kind = ref.watch(selectedKindProvider);
    final catsAsync = ref.watch(orderedCategoriesProvider);

    return catsAsync.when(
      data: (cats) {
        if (cats.isEmpty) return const Center(child: Text('Nothing here yet.'));
        final selected = ref.watch(selectedCategoryProvider) ?? cats.first;
        final current =
            cats.any((c) => c.name == selected.name) ? selected : cats.first;
        if (current.name == kFavoritesCategory) {
          return _FavoritesPane(
            key: ValueKey('${pl!.id}-${kind.name}-favs'),
            playlistId: pl.id!,
            kind: kind,
          );
        }
        return _ContentPane(
          key: ValueKey('${pl!.id}-${kind.name}-${current.name}'),
          playlistId: pl.id!,
          kind: kind,
          group: current.name,
        );
      },
      loading: () => const _SkeletonList(),
      error: (e, _) => Center(child: Text('$e')),
    );
  }
}

/// The "★ My Favorites" pseudo-category: the user's favorites of this kind.
class _FavoritesPane extends ConsumerWidget {
  const _FavoritesPane(
      {super.key, required this.playlistId, required this.kind});
  final int playlistId;
  final StreamKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favIds = ref.watch(favoriteIdsProvider).valueOrNull ?? const <int>{};
    return FutureBuilder<List<StreamItem>>(
      // favIds in the key so the list refreshes when favorites change.
      key: ValueKey(favIds.length),
      future: ref
          .read(repositoryProvider.future)
          .then((repo) => repo.favoritesByKind(playlistId, kind)),
      builder: (context, snap) {
        final items = snap.data ?? const <StreamItem>[];
        if (snap.connectionState != ConnectionState.done) {
          return const _SkeletonList();
        }
        if (items.isEmpty) {
          return const Center(
              child: Text('No favorites yet — tap the ♥ on any item.'));
        }
        if (kind != StreamKind.live) {
          return GridView.builder(
            clipBehavior: Clip.none,
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 140,
              mainAxisExtent: 242,
              crossAxisSpacing: 16,
              mainAxisSpacing: 14,
            ),
            itemCount: items.length,
            itemBuilder: (context, i) => PosterCard(
              item: items[i],
              width: 120,
              onTap: () => openItem(context, ref, items[i]),
            ),
          );
        }
        return ListView.builder(
          itemExtent: 72,
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            return ChannelTile(
              item: item,
              isFavorite: true,
              onFavorite:
                  item.id == null ? null : () => setFavorite(ref, item, false),
              onTap: () => openItem(context, ref, item),
            );
          },
        );
      },
    );
  }
}

class _ContentPane extends ConsumerStatefulWidget {
  const _ContentPane({
    super.key,
    required this.playlistId,
    required this.kind,
    required this.group,
  });
  final int playlistId;
  final StreamKind kind;
  final String group;

  @override
  ConsumerState<_ContentPane> createState() => _ContentPaneState();
}

class _ContentPaneState extends ConsumerState<_ContentPane> {
  final _scroll = ScrollController();
  final _searchCtl = TextEditingController();
  late ChannelPageKey _key;
  String _search = '';
  Future<List<StreamItem>>? _searchFuture;

  @override
  void initState() {
    super.initState();
    _key = ChannelPageKey(widget.playlistId, widget.kind, widget.group);
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (_search.isNotEmpty) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 800) {
      ref.read(channelPagerProvider(_key).notifier).loadMore();
    }
  }

  void _runSearch(String q) {
    setState(() {
      _search = q.trim();
      _searchFuture = _search.isEmpty
          ? null
          : ref
              .read(repositoryProvider.future)
              .then((repo) => repo.searchInCategory(
                    playlistId: widget.playlistId,
                    kind: widget.kind,
                    groupTitle: widget.group,
                    query: _search,
                  ));
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
          child: TvTextField(
            controller: _searchCtl,
            hint: 'Search in ${widget.group}',
            icon: Icons.search,
            dense: true,
            onChanged: _runSearch,
            onCleared: () => _runSearch(''),
          ),
        ),
        Expanded(
          child: _search.isEmpty ? _pagedView() : _searchView(),
        ),
      ],
    );
  }

  Widget _searchView() {
    return FutureBuilder<List<StreamItem>>(
      future: _searchFuture,
      builder: (context, snap) {
        final items = snap.data ?? [];
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (items.isEmpty) {
          return const Center(child: Text('No matches in this category.'));
        }
        return _buildList(items, reachedEnd: true);
      },
    );
  }

  Widget _pagedView() {
    final state = ref.watch(channelPagerProvider(_key));
    if (state.items.isEmpty && state.loading) return const _SkeletonList();
    if (state.items.isEmpty) {
      return const Center(child: Text('Empty category.'));
    }
    return _buildList(state.items, reachedEnd: state.reachedEnd);
  }

  Widget _buildList(List<StreamItem> items, {required bool reachedEnd}) {
    final favs = ref.watch(favoriteIdsProvider).valueOrNull ?? const <int>{};
    final isGrid = widget.kind != StreamKind.live;

    if (isGrid) {
      return GridView.builder(
        controller: _scroll,
        clipBehavior: Clip.none,
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 140,
          mainAxisExtent: 242,
          crossAxisSpacing: 16,
          mainAxisSpacing: 14,
        ),
        itemCount: items.length + (reachedEnd ? 0 : 1),
        itemBuilder: (context, i) {
          if (i >= items.length) return const _Loader();
          final item = items[i];
          return PosterCard(
            item: item,
            width: 120,
            onTap: () => openItem(context, ref, item),
          );
        },
      );
    }

    return ListView.builder(
      controller: _scroll,
      itemExtent: 72,
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: items.length + (reachedEnd ? 0 : 1),
      itemBuilder: (context, i) {
        if (i >= items.length) return const _Loader();
        final item = items[i];
        final fav = item.id != null && favs.contains(item.id);
        return ChannelTile(
          item: item,
          isFavorite: fav,
          onFavorite:
              item.id == null ? null : () => setFavorite(ref, item, !fav),
          onTap: () => openItem(context, ref, item),
        );
      },
    );
  }
}

class _Loader extends StatelessWidget {
  const _Loader();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
            child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))),
      );
}

class _SkeletonList extends StatelessWidget {
  const _SkeletonList();
  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemExtent: 72,
      itemCount: 12,
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
                color: LumenTheme.surfaceHi,
                borderRadius: BorderRadius.circular(12)),
          ),
          const SizedBox(width: 14),
          Container(
            width: 160,
            height: 14,
            decoration: BoxDecoration(
                color: LumenTheme.surfaceHi,
                borderRadius: BorderRadius.circular(7)),
          ),
        ]),
      ),
    );
  }
}
