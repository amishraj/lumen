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
  final _railScroll = ScrollController();
  final _catSearch = TextEditingController();
  String _catQuery = '';

  @override
  void dispose() {
    _railScroll.dispose();
    _catSearch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Leaving Live resets the category search, so returning starts clean.
    ref.listen<int>(auroraTabProvider, (_, next) {
      if (next != AuroraTab.live.index &&
          (_catQuery.isNotEmpty || _catSearch.text.isNotEmpty)) {
        setState(() {
          _catSearch.clear();
          _catQuery = '';
        });
      }
    });
    final pl = ref.watch(activePlaylistProvider);
    if (pl?.id == null) {
      return const Center(child: Text('Add a source to get started.'));
    }
    if (isDebridSentinel(pl)) {
      // Debrid-only setup: live TV is the one thing that genuinely needs an
      // IPTV source — say so instead of showing an empty category rail.
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Live TV needs an IPTV source.\nAdd your M3U or Xtream account in Settings → Sources.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Aurora.textDim, height: 1.5),
          ),
        ),
      );
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

    // A 292px category column plus a channel list does not fit a phone. On
    // compact the two panes become one: categories collapse into a horizontal
    // chip rail (plus a searchable sheet for the long tail) above a
    // full-width channel list.
    if (Aurora.isCompact(context)) {
      return _CompactLive(
        playlistId: pl!.id!,
        cats: cats,
        pinned: pinned,
        favs: favs,
        selected: selected,
      );
    }

    return AuroraUpNavScope(
      child: Padding(
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
            Padding(
              padding: const EdgeInsets.only(bottom: 8, right: 6),
              child: AuroraSearchField(
                controller: _catSearch,
                hint: 'Search categories',
                onChanged: (v) =>
                    setState(() => _catQuery = v.trim().toLowerCase()),
              ),
            ),
            Expanded(
              child: cats == null
                  ? const Center(
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  : Builder(builder: (context) {
                      final searching = _catQuery.isNotEmpty;
                      final shownCats = searching
                          ? cats
                              .where((c) =>
                                  c.name.toLowerCase().contains(_catQuery))
                              .toList()
                          : cats;
                      // Favourites row only when not filtering categories.
                      final showFav = favs.isNotEmpty && !searching;
                      if (shownCats.isEmpty) {
                        return const Center(
                            child: Text('No categories',
                                style: TextStyle(
                                    color: Aurora.textFaint, fontSize: 12)));
                      }
                      return FocusTraversalGroup(
                      child: ListView.builder(
                        controller: _railScroll,
                        padding: const EdgeInsets.only(bottom: 24, right: 6),
                        itemExtent: 54,
                        itemCount: shownCats.length + (showFav ? 1 : 0),
                        itemBuilder: (context, i) {
                          final isFavRow = showFav && i == 0;
                          final cat =
                              isFavRow ? null : shownCats[i - (showFav ? 1 : 0)];
                          final name = isFavRow ? _kFavGroup : cat!.name;
                          final count = isFavRow ? favs.length : cat!.count;
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
                    );
                    }),
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
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Compact (phone / portrait) Live
// ---------------------------------------------------------------------------

/// Phone Live TV: one column. A horizontal chip rail carries Favourites,
/// pinned categories and the rest; "All categories" opens a searchable sheet
/// for libraries with hundreds of groups. Below it, the same channel panes the
/// wide layout uses, now full width.
class _CompactLive extends ConsumerWidget {
  const _CompactLive({
    required this.playlistId,
    required this.cats,
    required this.pinned,
    required this.favs,
    required this.selected,
  });

  final int playlistId;
  final List<Category>? cats;
  final Set<String> pinned;
  final List<StreamItem> favs;
  final String? selected;

  Future<void> _pickCategory(BuildContext context, WidgetRef ref) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Aurora.bgRaised,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _CategorySheet(
        cats: cats ?? const [],
        pinned: pinned,
        hasFavorites: favs.isNotEmpty,
        selected: selected,
      ),
    );
    if (picked == null) return;
    ref.read(auroraGroupProvider(StreamKind.live).notifier).state = picked;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final margin = Aurora.margin(context);
    final list = cats ?? const <Category>[];
    // Favourites first, then pinned, then everything else — the same priority
    // the wide rail uses, flattened into a single scrollable strip.
    final names = <String>[
      if (favs.isNotEmpty) _kFavGroup,
      for (final c in list) c.name,
    ];

    return Padding(
      padding: EdgeInsets.only(top: Aurora.topPad(context)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 6, margin - 6, 2),
          child: Row(children: [
            Expanded(
              child: Text('Live TV',
                  style: Aurora.display.copyWith(fontSize: 26)),
            ),
            AuroraFocusable(
              radius: 20,
              centerOnFocus: false,
              onActivate: () => _pickCategory(context, ref),
              builder: (context, focused) => Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: focused ? Colors.white : Aurora.glass,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Aurora.hairline),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.tune_rounded,
                      size: 16,
                      color: focused ? Aurora.bg : Aurora.textDim),
                  const SizedBox(width: 6),
                  Text('Categories',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: focused ? Aurora.bg : Aurora.textDim)),
                ]),
              ),
            ),
          ]),
        ),
        if (cats == null)
          const Expanded(
            child: Center(
                child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))),
          )
        else ...[
          SizedBox(
            height: 46,
            child: names.isEmpty
                ? null
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    padding: EdgeInsets.symmetric(horizontal: margin),
                    itemCount: names.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, i) {
                      final name = names[i];
                      return _CompactCatChip(
                        label: name,
                        selected: name == selected,
                        pinned: pinned.contains(name),
                        onPick: () => ref
                            .read(auroraGroupProvider(StreamKind.live).notifier)
                            .state = name,
                      );
                    },
                  ),
          ),
          Expanded(
            child: selected == null
                ? const Center(
                    child: Text('No live categories.',
                        style: TextStyle(color: Aurora.textFaint)))
                : selected == _kFavGroup
                    ? _FavoritesPane(items: favs, compact: true)
                    : _ChannelPane(
                        key: ValueKey('compact-$playlistId-$selected'),
                        playlistId: playlistId,
                        group: selected!,
                        compact: true,
                      ),
          ),
        ],
      ]),
    );
  }
}

class _CompactCatChip extends StatelessWidget {
  const _CompactCatChip({
    required this.label,
    required this.selected,
    required this.pinned,
    required this.onPick,
  });
  final String label;
  final bool selected;
  final bool pinned;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return AuroraFocusable(
      ring: false,
      scale: 1.0,
      centerOnFocus: false,
      onActivate: onPick,
      builder: (context, focused) => Center(
        child: AnimatedContainer(
          duration: Aurora.fast,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
            if (pinned) ...[
              Icon(Icons.push_pin_rounded,
                  size: 11, color: focused ? Aurora.bg : Aurora.accent),
              const SizedBox(width: 4),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 190),
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          selected || focused ? FontWeight.w800 : FontWeight.w600,
                      color: focused
                          ? Aurora.bg
                          : (selected ? Aurora.text : Aurora.textDim))),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Searchable full category list — the long tail that won't fit a chip rail.
class _CategorySheet extends StatefulWidget {
  const _CategorySheet({
    required this.cats,
    required this.pinned,
    required this.hasFavorites,
    required this.selected,
  });
  final List<Category> cats;
  final Set<String> pinned;
  final bool hasFavorites;
  final String? selected;

  @override
  State<_CategorySheet> createState() => _CategorySheetState();
}

class _CategorySheetState extends State<_CategorySheet> {
  final _ctl = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _q.isEmpty
        ? widget.cats
        : widget.cats
            .where((c) => c.name.toLowerCase().contains(_q))
            .toList();
    final showFav = widget.hasFavorites && _q.isEmpty;
    return SafeArea(
      top: false,
      child: SizedBox(
        // Leaves the top of the screen visible so the sheet reads as a sheet.
        height: MediaQuery.of(context).size.height * 0.78,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              16, 0, 16, MediaQuery.of(context).viewInsets.bottom),
          child: Column(children: [
            AuroraSearchField(
              controller: _ctl,
              hint: 'Search categories',
              onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: shown.isEmpty && !showFav
                  ? const Center(
                      child: Text('No categories',
                          style: TextStyle(color: Aurora.textFaint)))
                  : ListView.builder(
                      itemExtent: 52,
                      itemCount: shown.length + (showFav ? 1 : 0),
                      itemBuilder: (context, i) {
                        final isFavRow = showFav && i == 0;
                        final c =
                            isFavRow ? null : shown[i - (showFav ? 1 : 0)];
                        final name = isFavRow ? _kFavGroup : c!.name;
                        final active = name == widget.selected;
                        return ListTile(
                          dense: true,
                          selected: active,
                          leading: widget.pinned.contains(name)
                              ? const Icon(Icons.push_pin_rounded,
                                  size: 15, color: Aurora.accent)
                              : null,
                          title: Text(name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: active
                                      ? FontWeight.w800
                                      : FontWeight.w500,
                                  color:
                                      active ? Aurora.text : Aurora.textDim)),
                          trailing: Text(
                              isFavRow ? '' : '${c!.count}',
                              style: Aurora.caption),
                          onTap: () => Navigator.of(context).pop(name),
                        );
                      },
                    ),
            ),
          ]),
        ),
      ),
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
  const _FavoritesPane({required this.items, this.compact = false});
  final List<StreamItem> items;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (items.isEmpty) {
      return const Center(
          child: Text('No favorite channels yet.',
              style: TextStyle(color: Aurora.textFaint)));
    }
    return ListView.builder(
      padding: _listPadding(context, compact),
      itemExtent: 66,
      itemCount: items.length,
      itemBuilder: (context, i) =>
          _ChannelRow(item: items[i], queue: items, index: i, compact: compact),
    );
  }
}

/// Gutter for a channel list: the wide layout sits beside the category rail
/// (small left inset, generous right), the phone list runs edge to edge and
/// has to clear the floating tab bar.
EdgeInsets _listPadding(BuildContext context, bool compact) => compact
    ? EdgeInsets.fromLTRB(
        Aurora.margin(context) - 8, 4, Aurora.margin(context) - 8,
        Aurora.bottomPad(context))
    : const EdgeInsets.fromLTRB(18, 4, 48, 24);

/// One paged category of channels + in-category search.
class _ChannelPane extends ConsumerStatefulWidget {
  const _ChannelPane({
    super.key,
    required this.playlistId,
    required this.group,
    this.compact = false,
  });
  final int playlistId;
  final String group;
  final bool compact;

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
    // Leaving Live clears the in-category channel search too.
    ref.listen<int>(auroraTabProvider, (_, next) {
      if (next != AuroraTab.live.index &&
          (_query.isNotEmpty || _searchCtl.text.isNotEmpty)) {
        _searchCtl.clear();
        _runSearch('');
      }
    });
    final margin = Aurora.margin(context);
    return Column(children: [
      Padding(
        padding: widget.compact
            ? EdgeInsets.fromLTRB(margin, 8, margin, 6)
            : const EdgeInsets.fromLTRB(18, 0, 48, 8),
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
      padding: _listPadding(context, widget.compact),
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
        return _ChannelRow(
            item: state.items[i],
            queue: state.items,
            index: i,
            compact: widget.compact);
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
          padding: _listPadding(context, widget.compact),
          itemExtent: 66,
          itemCount: items.length,
          itemBuilder: (context, i) => _ChannelRow(
              item: items[i],
              queue: items,
              index: i,
              compact: widget.compact),
        );
      },
    );
  }
}

/// A channel row: number · logo · name/EPG · favorite toggle.
class _ChannelRow extends ConsumerWidget {
  const _ChannelRow({
    required this.item,
    required this.queue,
    required this.index,
    this.compact = false,
  });
  final StreamItem item;
  final List<StreamItem> queue;
  final int index;
  final bool compact;

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
          // The channel-number gutter is the first thing to go on a phone —
          // it's the least useful column and the most expensive in width.
          if (!compact)
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
              width: compact ? 58 : 66,
              height: compact ? 36 : 40,
              radius: 8,
              fallbackText: item.name),
          SizedBox(width: compact ? 12 : 14),
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
