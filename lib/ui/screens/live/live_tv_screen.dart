import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../state/providers.dart';
import '../../navigation.dart';
import '../../theme/lumen_theme.dart';
import '../../widgets/channel_tile.dart';
import '../../widgets/poster_card.dart';

/// Browsing with a vertical category **sidebar** (pinnable) on the left and a
/// lazily-paged, fully virtualized content pane on the right. Live = list,
/// Movies/TV Shows = poster grid. Each category shards the 40k library.
class LiveTvScreen extends ConsumerWidget {
  const LiveTvScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pl = ref.watch(activePlaylistProvider);
    final kind = ref.watch(selectedKindProvider);
    final catsAsync = ref.watch(orderedCategoriesProvider);

    if (pl?.id == null) {
      return const Center(child: Text('Add a source to get started.'));
    }

    return Column(
      children: [
        _KindSelector(kind: kind),
        Expanded(
          child: catsAsync.when(
            data: (cats) {
              if (cats.isEmpty) {
                return const Center(child: Text('Nothing here yet.'));
              }
              final selected = ref.watch(selectedCategoryProvider) ?? cats.first;
              final exists = cats.any((c) => c.name == selected.name);
              final current = exists ? selected : cats.first;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Sidebar(categories: cats, selected: current),
                  Expanded(
                    child: _ContentPane(
                      key: ValueKey('${pl!.id}-${kind.name}-${current.name}'),
                      playlistId: pl.id!,
                      kind: kind,
                      group: current.name,
                    ),
                  ),
                ],
              );
            },
            loading: () => const _SkeletonList(),
            error: (e, _) => Center(child: Text('$e')),
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
        child: GestureDetector(
          onTap: () {
            ref.read(selectedKindProvider.notifier).state = k;
            ref.read(selectedCategoryProvider.notifier).state = null;
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: sel ? LumenTheme.accent.withValues(alpha: 0.18) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 17, color: sel ? LumenTheme.accent : const Color(0xFF8A8F9E)),
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                        color: sel ? LumenTheme.accent : const Color(0xFF8A8F9E),
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

/// Vertical, scrollable category list with pin toggles. Pinned float to top.
class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.categories, required this.selected});
  final List<Category> categories;
  final Category selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinned = ref.watch(pinnedCategoriesProvider).valueOrNull ?? const <String>{};
    return Container(
      width: 144,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: Color(0xFF1C1F29))),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: categories.length,
        itemExtent: 48,
        itemBuilder: (context, i) {
          final c = categories[i];
          final sel = c.name == selected.name;
          final isPinned = pinned.contains(c.name);
          return InkWell(
            onTap: () => ref.read(selectedCategoryProvider.notifier).state = c,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              padding: const EdgeInsets.only(left: 10, right: 2),
              decoration: BoxDecoration(
                color: sel ? LumenTheme.accent.withValues(alpha: 0.16) : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border(
                  left: BorderSide(
                    color: sel ? LumenTheme.accent : Colors.transparent,
                    width: 3,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                                color: sel ? Colors.white : const Color(0xFFC7CBD6))),
                        Text('${c.count}',
                            style: const TextStyle(
                                fontSize: 10.5, color: Color(0xFF6B7080))),
                      ],
                    ),
                  ),
                  InkResponse(
                    onTap: () async {
                      final repo = await ref.read(repositoryProvider.future);
                      final pl = ref.read(activePlaylistProvider);
                      final kind = ref.read(selectedKindProvider);
                      if (pl?.id == null) return;
                      await repo.setPinned(pl!.id!, kind, c.name, !isPinned);
                      ref.invalidate(pinnedCategoriesProvider);
                      ref.invalidate(orderedCategoriesProvider);
                    },
                    radius: 18,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                        size: 15,
                        color: isPinned
                            ? LumenTheme.accentWarm
                            : const Color(0xFF5B6072),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
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
  late ChannelPageKey _key;

  @override
  void initState() {
    super.initState();
    _key = ChannelPageKey(widget.playlistId, widget.kind, widget.group);
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 800) {
      ref.read(channelPagerProvider(_key).notifier).loadMore();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(channelPagerProvider(_key));
    final favs = ref.watch(favoriteIdsProvider).valueOrNull ?? const <int>{};

    if (state.items.isEmpty && state.loading) return const _SkeletonList();
    if (state.items.isEmpty) {
      return const Center(child: Text('Empty category.'));
    }

    final isGrid = widget.kind != StreamKind.live;
    if (isGrid) {
      return GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 130,
          mainAxisExtent: 218,
          crossAxisSpacing: 12,
          mainAxisSpacing: 8,
        ),
        itemCount: state.items.length + (state.reachedEnd ? 0 : 1),
        itemBuilder: (context, i) {
          if (i >= state.items.length) return const _Loader();
          final item = state.items[i];
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
      itemExtent: 68,
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: state.items.length + (state.reachedEnd ? 0 : 1),
      itemBuilder: (context, i) {
        if (i >= state.items.length) return const _Loader();
        final item = state.items[i];
        final fav = item.id != null && favs.contains(item.id);
        return ChannelTile(
          item: item,
          isFavorite: fav,
          onFavorite: item.id == null
              ? null
              : () async {
                  final repo = await ref.read(repositoryProvider.future);
                  await repo.toggleFavorite(item.id!, !fav);
                  ref.invalidate(favoriteIdsProvider);
                },
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
                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
      );
}

class _SkeletonList extends StatelessWidget {
  const _SkeletonList();
  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemExtent: 68,
      itemCount: 12,
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
                color: LumenTheme.surfaceHi, borderRadius: BorderRadius.circular(12)),
          ),
          const SizedBox(width: 14),
          Container(
            width: 160,
            height: 14,
            decoration: BoxDecoration(
                color: LumenTheme.surfaceHi, borderRadius: BorderRadius.circular(7)),
          ),
        ]),
      ),
    );
  }
}
