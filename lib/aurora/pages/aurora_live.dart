import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../aurora_focus.dart';
import '../aurora_providers.dart';
import '../aurora_theme.dart';
import '../player/aurora_player.dart';
import '../widgets/aurora_badges.dart';
import '../widgets/aurora_image.dart';
import '../widgets/aurora_search_field.dart';

const _kFavGroup = '★ Favorites';

/// Live TV: category rail on the left, a windowed channel list on the right.
/// OK on a channel drops straight into the player with the whole visible
/// list as a zap queue (channel up/down works from the remote).
class AuroraLivePage extends ConsumerStatefulWidget {
  const AuroraLivePage({super.key});

  @override
  ConsumerState<AuroraLivePage> createState() => _AuroraLivePageState();
}

class _AuroraLivePageState extends ConsumerState<AuroraLivePage> {
  @override
  Widget build(BuildContext context) {
    final pl = ref.watch(activePlaylistProvider);
    if (pl?.id == null) {
      return const Center(child: Text('Add a source to get started.'));
    }
    final margin = Aurora.margin(context);
    final cats =
        ref.watch(auroraOrderedCategoriesProvider(StreamKind.live)).valueOrNull;
    final pinned = ref.watch(auroraPinnedProvider(StreamKind.live)).valueOrNull ??
        const <String>{};
    final favs = ref
            .watch(favoritesByKindProvider(StreamKind.live))
            .valueOrNull ??
        const <StreamItem>[];
    final selected = ref.watch(auroraGroupProvider(StreamKind.live)) ??
        (favs.isNotEmpty
            ? _kFavGroup
            : (cats != null && cats.isNotEmpty ? cats.first.name : null));

    return Padding(
      padding: EdgeInsets.fromLTRB(margin, 84, 0, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // ---- Category rail ----
        SizedBox(
          width: 292,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12, left: 4),
              child:
                  Text('Live TV', style: Aurora.display.copyWith(fontSize: 30)),
            ),
            Expanded(
              child: cats == null
                  ? const Center(
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  : FocusTraversalGroup(
                      child: ListView.builder(
                        padding: const EdgeInsets.only(bottom: 24, right: 6),
                        itemExtent: 54,
                        itemCount: cats.length + (favs.isNotEmpty ? 1 : 0),
                        itemBuilder: (context, i) {
                          final isFavRow = favs.isNotEmpty && i == 0;
                          final name =
                              isFavRow ? _kFavGroup : cats[i - (favs.isNotEmpty ? 1 : 0)].name;
                          final count = isFavRow
                              ? favs.length
                              : cats[i - (favs.isNotEmpty ? 1 : 0)].count;
                          return _CategoryRow(
                            name: name,
                            count: count,
                            selected: name == selected,
                            pinnable: !isFavRow,
                            pinned: pinned.contains(name),
                            onPick: () => ref
                                .read(auroraGroupProvider(StreamKind.live)
                                    .notifier)
                                .state = name,
                            onPin: () =>
                                toggleAuroraPin(ref, StreamKind.live, name),
                          );
                        },
                      ),
                    ),
            ),
          ]),
        ),
        Container(width: 1, color: Aurora.hairline, margin: const EdgeInsets.symmetric(vertical: 8)),
        // ---- Channels ----
        Expanded(
          child: selected == null
              ? const Center(
                  child: Text('No live categories.',
                      style: TextStyle(color: Aurora.textFaint)))
              : selected == _kFavGroup
                  ? _FavoritesPane(items: favs)
                  : _ChannelPane(
                      key: ValueKey('${pl!.id}-$selected'),
                      playlistId: pl.id!,
                      group: selected,
                    ),
        ),
      ]),
    );
  }
}

class _CategoryRow extends StatefulWidget {
  const _CategoryRow({
    required this.name,
    required this.count,
    required this.selected,
    required this.onPick,
    this.pinnable = false,
    this.pinned = false,
    this.onPin,
  });
  final String name;
  final int count;
  final bool selected;
  final bool pinnable;
  final bool pinned;
  final VoidCallback onPick;
  final VoidCallback? onPin;

  @override
  State<_CategoryRow> createState() => _CategoryRowState();
}

class _CategoryRowState extends State<_CategoryRow> {
  // Dedicated node so Right from the name lands exactly on the pin toggle.
  final FocusNode _pinFocus = FocusNode(debugLabel: 'live-cat-pin');

  @override
  void dispose() {
    _pinFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return AnimatedContainer(
      duration: Aurora.fast,
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: selected ? Aurora.glassHi : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(
              color: selected ? Aurora.accent : Colors.transparent, width: 3),
        ),
      ),
      child: Row(children: [
        Expanded(
          child: AuroraFocusable(
            ring: false,
            scale: 1.0,
            centerOnFocus: false,
            onActivate: widget.onPick,
            onRight: widget.pinnable ? _pinFocus.requestFocus : null,
            builder: (context, focused) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: focused ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                if (widget.pinned) ...[
                  Icon(Icons.push_pin_rounded,
                      size: 12,
                      color: focused ? Aurora.bg : Aurora.accent),
                  const SizedBox(width: 5),
                ],
                Expanded(
                  child: Text(widget.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: selected || focused
                              ? FontWeight.w800
                              : FontWeight.w500,
                          color: focused
                              ? Aurora.bg
                              : (selected ? Aurora.text : Aurora.textDim))),
                ),
                const SizedBox(width: 8),
                Text('${widget.count}',
                    style: TextStyle(
                        fontSize: 11,
                        color: focused
                            ? const Color(0x99060708)
                            : Aurora.textFaint)),
              ]),
            ),
          ),
        ),
        if (widget.pinnable)
          AuroraFocusable(
            focusNode: _pinFocus,
            radius: 18,
            centerOnFocus: false,
            onActivate: widget.onPin ?? () {},
            builder: (context, focused) => Padding(
              padding: const EdgeInsets.all(7),
              child: Icon(
                widget.pinned
                    ? Icons.push_pin_rounded
                    : Icons.push_pin_outlined,
                size: 16,
                color: widget.pinned
                    ? Aurora.accent
                    : (focused ? Aurora.text : Aurora.textFaint),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Favorites pseudo-category — a plain (non-paged) channel list.
class _FavoritesPane extends ConsumerWidget {
  const _FavoritesPane({required this.items});
  final List<StreamItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (items.isEmpty) {
      return const Center(
          child: Text('No favorite channels yet.',
              style: TextStyle(color: Aurora.textFaint)));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(18, 4, 48, 24),
      itemExtent: 66,
      itemCount: items.length,
      itemBuilder: (context, i) =>
          _ChannelRow(item: items[i], queue: items, index: i),
    );
  }
}

/// One paged category of channels + in-category search.
class _ChannelPane extends ConsumerStatefulWidget {
  const _ChannelPane({super.key, required this.playlistId, required this.group});
  final int playlistId;
  final String group;

  @override
  ConsumerState<_ChannelPane> createState() => _ChannelPaneState();
}

class _ChannelPaneState extends ConsumerState<_ChannelPane> {
  final _scroll = ScrollController();
  final _searchCtl = TextEditingController();
  late final ChannelPageKey _key =
      ChannelPageKey(widget.playlistId, StreamKind.live, widget.group);
  String _query = '';
  Future<List<StreamItem>>? _searchFuture;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_query.isNotEmpty) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 800) {
      ref.read(channelPagerProvider(_key).notifier).loadMore();
    }
  }

  void _runSearch(String q) {
    setState(() {
      _query = q.trim();
      _searchFuture = _query.isEmpty
          ? null
          : ref.read(repositoryProvider.future).then((repo) =>
              repo.searchInCategory(
                  playlistId: widget.playlistId,
                  kind: StreamKind.live,
                  groupTitle: widget.group,
                  query: _query));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 48, 8),
        child: AuroraSearchField(
          controller: _searchCtl,
          hint: 'Search in ${widget.group}',
          onChanged: _runSearch,
        ),
      ),
      Expanded(child: _query.isEmpty ? _paged() : _searchResults()),
    ]);
  }

  Widget _paged() {
    final state = ref.watch(channelPagerProvider(_key));
    if (state.items.isEmpty && state.loading) {
      return const Center(
          child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (state.items.isEmpty) {
      return const Center(
          child: Text('Empty category.',
              style: TextStyle(color: Aurora.textFaint)));
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(18, 4, 48, 24),
      itemExtent: 66,
      itemCount: state.items.length + (state.reachedEnd ? 0 : 1),
      itemBuilder: (context, i) {
        if (i >= state.items.length) {
          return const Center(
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)));
        }
        return _ChannelRow(item: state.items[i], queue: state.items, index: i);
      },
    );
  }

  Widget _searchResults() {
    return FutureBuilder<List<StreamItem>>(
      future: _searchFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)));
        }
        final items = snap.data ?? const <StreamItem>[];
        if (items.isEmpty) {
          return const Center(
              child: Text('No matches in this category.',
                  style: TextStyle(color: Aurora.textFaint)));
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(18, 4, 48, 24),
          itemExtent: 66,
          itemCount: items.length,
          itemBuilder: (context, i) =>
              _ChannelRow(item: items[i], queue: items, index: i),
        );
      },
    );
  }
}

/// A channel row: number · logo · name/EPG · favorite toggle.
class _ChannelRow extends ConsumerWidget {
  const _ChannelRow(
      {required this.item, required this.queue, required this.index});
  final StreamItem item;
  final List<StreamItem> queue;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favIds = ref.watch(favoriteIdsProvider).valueOrNull ?? const <int>{};
    final fav = item.id != null && favIds.contains(item.id);

    return AuroraFocusable(
      radius: 14,
      scale: 1.01,
      onActivate: () {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AuroraPlayerScreen(
            item: item,
            queue: List.of(queue),
            startIndex: index,
          ),
        ));
      },
      builder: (context, focused) => Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: focused ? Aurora.glassHi : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          SizedBox(
            width: 44,
            child: Text(
              item.num == null ? '' : '${item.num}',
              style: const TextStyle(
                  color: Aurora.textFaint,
                  fontSize: 12,
                  fontWeight: FontWeight.w700),
            ),
          ),
          AuroraLogoTile(
              url: item.logo,
              width: 66,
              height: 40,
              radius: 8,
              fallbackText: item.name),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: focused ? Aurora.text : const Color(0xFFCBD0DC))),
                if (item.tvgId != null && item.tvgId!.isNotEmpty)
                  _NowPlayingLine(tvgId: item.tvgId!),
              ],
            ),
          ),
          if (item.id != null)
            AuroraFocusable(
              radius: 20,
              onActivate: () => setFavorite(ref, item, !fav),
              builder: (context, f2) => Padding(
                padding: const EdgeInsets.all(7),
                child: Icon(
                  fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  size: 17,
                  color: fav ? Aurora.live : Aurora.textFaint,
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Lazy now-playing line from the EPG table (renders nothing when the
/// source has no EPG rows for this channel). Future is cached per channel so
/// parent rebuilds (favorite toggles, focus moves) don't re-query.
class _NowPlayingLine extends ConsumerStatefulWidget {
  const _NowPlayingLine({required this.tvgId});
  final String tvgId;

  @override
  ConsumerState<_NowPlayingLine> createState() => _NowPlayingLineState();
}

class _NowPlayingLineState extends ConsumerState<_NowPlayingLine> {
  late Future<EpgEntry?> _future = _lookup();

  Future<EpgEntry?> _lookup() => ref
      .read(repositoryProvider.future)
      .then((repo) => repo.nowPlaying(widget.tvgId));

  @override
  void didUpdateWidget(covariant _NowPlayingLine old) {
    super.didUpdateWidget(old);
    if (old.tvgId != widget.tvgId) _future = _lookup();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EpgEntry?>(
      future: _future,
      builder: (context, snap) {
        final e = snap.data;
        if (e == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(children: [
            const LiveBadge(small: true),
            const SizedBox(width: 6),
            Flexible(
              child: Text(e.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Aurora.caption),
            ),
          ]),
        );
      },
    );
  }
}
