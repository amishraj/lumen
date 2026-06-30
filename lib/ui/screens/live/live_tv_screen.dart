import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../state/providers.dart';
import '../../theme/lumen_theme.dart';
import '../../widgets/channel_tile.dart';
import '../player/player_screen.dart';

/// Live/movie browsing: a horizontal category rail shards the library, and a
/// lazily-paged, fully virtualized list renders only what's on screen.
class LiveTvScreen extends ConsumerWidget {
  const LiveTvScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pl = ref.watch(activePlaylistProvider);
    final kind = ref.watch(selectedKindProvider);
    final catsAsync = ref.watch(categoriesProvider);

    if (pl?.id == null) {
      return const Center(child: Text('Add a source to get started.'));
    }

    return Column(
      children: [
        _KindSelector(kind: kind),
        SizedBox(
          height: 44,
          child: catsAsync.when(
            data: (cats) => _CategoryRail(categories: cats),
            loading: () => const Center(
                child: SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            error: (e, _) => Center(child: Text('$e')),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: catsAsync.when(
            data: (cats) {
              if (cats.isEmpty) {
                return const Center(child: Text('Nothing here yet.'));
              }
              final selected = ref.watch(selectedCategoryProvider) ?? cats.first;
              final group = selected.name == 'Uncategorized' &&
                      !cats.any((c) => c.name == 'Uncategorized')
                  ? null
                  : selected.name;
              return _ChannelList(
                key: ValueKey('${pl!.id}-${kind.name}-${selected.name}'),
                playlistId: pl.id!,
                kind: kind,
                group: group,
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
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: LumenTheme.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          seg('Live TV', StreamKind.live, Icons.live_tv),
          seg('Movies', StreamKind.movie, Icons.movie_outlined),
        ]),
      ),
    );
  }
}

class _CategoryRail extends ConsumerWidget {
  const _CategoryRail({required this.categories});
  final List<Category> categories;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedCategoryProvider) ??
        (categories.isNotEmpty ? categories.first : null);
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: categories.length,
      separatorBuilder: (_, __) => const SizedBox(width: 8),
      itemBuilder: (_, i) {
        final c = categories[i];
        final sel = c.name == selected?.name;
        return GestureDetector(
          onTap: () => ref.read(selectedCategoryProvider.notifier).state = c,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: sel ? LumenTheme.accent : LumenTheme.surfaceHi,
              borderRadius: BorderRadius.circular(30),
            ),
            child: Row(
              children: [
                Text(c.name,
                    style: TextStyle(
                        color: sel ? const Color(0xFF0A0B0F) : Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(
                    color: (sel ? Colors.black : LumenTheme.accent)
                        .withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('${c.count}',
                      style: TextStyle(
                          color: sel ? Colors.black : LumenTheme.accent,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ChannelList extends ConsumerStatefulWidget {
  const _ChannelList({
    super.key,
    required this.playlistId,
    required this.kind,
    required this.group,
  });
  final int playlistId;
  final StreamKind kind;
  final String? group;

  @override
  ConsumerState<_ChannelList> createState() => _ChannelListState();
}

class _ChannelListState extends ConsumerState<_ChannelList> {
  final _scroll = ScrollController();
  late ChannelPageKey _key;

  @override
  void initState() {
    super.initState();
    _key = ChannelPageKey(widget.playlistId, widget.kind, widget.group);
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (_scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 600) {
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
      return const Center(child: Text('No channels in this category.'));
    }

    return ListView.builder(
      controller: _scroll,
      // itemExtent makes the list O(1) to lay out — key to smooth 40k scroll.
      itemExtent: 68,
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: state.items.length + (state.reachedEnd ? 0 : 1),
      itemBuilder: (context, i) {
        if (i >= state.items.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
                child: SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
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
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => PlayerScreen(item: item)),
          ),
        );
      },
    );
  }
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
