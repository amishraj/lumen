import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/sources/trakt_service.dart';
import '../main.dart' show bootFirstFrameMs, bootStopwatch;
import '../state/providers.dart';
import '../state/sync_providers.dart';
import '../state/service_status.dart';
import 'aurora_focus.dart';
import 'aurora_providers.dart';
import 'aurora_theme.dart';
import 'pages/aurora_browse.dart';
import 'pages/aurora_home.dart';
import 'pages/aurora_live.dart';
import 'pages/aurora_my_stuff.dart';
import 'pages/aurora_search.dart';
import 'pages/aurora_settings.dart';
import 'pages/aurora_sports.dart';
import 'widgets/aurora_bottom_nav.dart';
import '../data/models/models.dart';

/// The Aurora root: an Apple TV-style translucent top bar over full-bleed
/// pages. Pages live in a lazy IndexedStack so each keeps its scroll/focus
/// state, but nothing builds until first visited.
class AuroraShell extends ConsumerStatefulWidget {
  const AuroraShell({super.key});

  @override
  ConsumerState<AuroraShell> createState() => _AuroraShellState();
}

class _AuroraShellState extends ConsumerState<AuroraShell>
    with WidgetsBindingObserver {
  DateTime? _lastBack;
  bool _kickedOffSync = false;
  DateTime _lastResumeSync = DateTime.fromMillisecondsSinceEpoch(0);

  /// Compact (phone) only: true = the floating bottom bar is fully expanded
  /// (active tab labelled). It contracts to bare icons while you scroll down
  /// and springs back the instant you scroll up — it never hides, so the tabs
  /// are always a thumb-reach away.
  final ValueNotifier<bool> _navExpanded = ValueNotifier(true);

  /// Bumped to tell [_LazyStack] to drop every page but the one on screen.
  /// Fired on an OS memory-pressure warning — see [didHaveMemoryPressure].
  final ValueNotifier<int> _purgePages = ValueNotifier(0);

  // Stable per-tab focus nodes — created once, never swapped, and owned by the
  // shell rather than by a bar, because on compact the tabs are split across
  // two surfaces (main tabs in the floating bottom bar, Search + Settings in
  // the slim header). The selected tab's node is published as
  // [auroraNavTarget] so pages can return focus to the nav, and the whole map
  // as [auroraTabNodes] for programmatic tab switches.
  final Map<AuroraTab, FocusNode> _nodes = {
    for (final t in AuroraTab.values)
      t: FocusNode(debugLabel: 'aurora-tab-${t.name}'),
  };

  @override
  void initState() {
    super.initState();
    auroraTabNodes
      ..clear()
      ..addAll(_nodes);
    // Aurora's focus model is RELATIVE — arrow keys only move when something is
    // already focused. An empty/loading Home (no billboard Play button, no
    // rows) leaves primaryFocus null and the remote completely dead. Watch for
    // focus falling to null and seed it back onto the active top-nav tab, so
    // the app is always drivable and the nav (Settings → Add source) is always
    // reachable — no matter what has or hasn't loaded.
    FocusManager.instance.addListener(_ensureFocus);
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureFocus());
    // App resume is THE cross-device moment ("picked up the other device") —
    // there was no lifecycle observer anywhere before this, so a device
    // living in background for a day never re-synced anything.
    WidgetsBinding.instance.addObserver(this);
    // First shell frame = the moment the user sees their home.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (bootStopwatch.isRunning) {
        bootStopwatch.stop();
        bootFirstFrameMs = bootStopwatch.elapsedMilliseconds;
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 60s floor so quick app-switches don't spam the Worker.
      if (DateTime.now().difference(_lastResumeSync).inSeconds >= 60) {
        _lastResumeSync = DateTime.now();
        unawaited(runSync(ref));
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Push-only on the way out: whatever the outbox holds should reach the
      // server before the OS freezes us.
      unawaited(() async {
        try {
          final sync = await ref.read(syncServiceProvider.future);
          await sync.pushPull();
        } catch (_) {}
      }());
    }
  }

  /// Android sends this via onTrimMemory/onLowMemory — on a 2 GB Google TV it
  /// arrives well before the kill, which makes it the one chance the app gets
  /// to shed memory instead of being shot.
  ///
  /// Flutter's own default handler only clears the *cached* half of the image
  /// cache. The half that actually matters here is the live half: every
  /// decoded image still referenced by a mounted widget, which no size cap
  /// applies to. Home's shelves plus a few pages parked in the lazy stack keep
  /// dozens of those alive, so we drop the parked pages first (that releases
  /// their references), then clear both halves of the cache.
  @override
  void didHaveMemoryPressure() {
    super.didHaveMemoryPressure();
    _purgePages.value++;
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(_ensureFocus);
    _navExpanded.dispose();
    _purgePages.dispose();
    for (final e in _nodes.entries) {
      if (auroraTabNodes[e.key] == e.value) auroraTabNodes.remove(e.key);
      e.value.dispose();
    }
    super.dispose();
  }

  bool _seeding = false;
  void _ensureFocus() {
    if (!mounted || _seeding) return;
    if (FocusManager.instance.primaryFocus != null) return;
    // A pushed screen (Add source, player, detail) owns focus while it's front.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    _seeding = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _seeding = false;
      if (!mounted || FocusManager.instance.primaryFocus != null) return;
      final nav = auroraNavTarget;
      if (nav != null && nav.canRequestFocus) nav.requestFocus();
    });
  }

  void _select(AuroraTab tab) {
    _navExpanded.value = true; // a tab switch always restores the full bar
    ref.read(auroraTabProvider.notifier).state = tab.index;
  }

  /// Expand/contract the floating bar from a page's vertical scroll direction.
  /// Horizontal shelf scrolling is ignored so swiping a rail never toggles it.
  bool _onPageScroll(UserScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n.direction == ScrollDirection.reverse) {
      _navExpanded.value = false; // scrolling down
    } else if (n.direction == ScrollDirection.forward) {
      _navExpanded.value = true; // scrolling up
    }
    return false;
  }

  /// Back bounces to Home first; on Home a second press within 2s exits.
  void _onBack() {
    // A Back that arrives in the settling window straight after a title screen
    // popped is the tail of that same gesture, not a new one. Acting on it
    // bounced the user to Home the instant they returned from a title.
    if (auroraFocusTabSuppressed) return;
    final current = ref.read(auroraTabProvider);
    if (current != AuroraTab.home.index) {
      _select(AuroraTab.home);
      return;
    }
    final now = DateTime.now();
    if (_lastBack == null ||
        now.difference(_lastBack!) > const Duration(seconds: 2)) {
      _lastBack = now;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(
          content: Text('Press back again to exit'),
          duration: Duration(seconds: 2),
        ));
      return;
    }
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final tab = ref.watch(auroraTabProvider);
    final active = ref.watch(activePlaylistProvider);
    final compact = Aurora.isCompact(context);
    // Publish the selected tab's node so pages can return focus to the nav
    // (▲ from their top row). Done here, not in a bar, because on compact the
    // tabs are split between the header and the floating bottom bar.
    auroraNavTarget = _nodes[AuroraTab.values[tab]];

    // Startup sequence (all background, none gates the first paint — home
    // renders instantly off its persisted snapshots; the title index kicks
    // itself off from the first home build with its own built-in yield):
    //  ~2s    flush any queued Trakt writes (watch events that failed to send
    //         last session), then force-fresh Trakt pull (resume points /
    //         watched / watchlist) — cross-device progress lands seconds
    //         after open, not when a 6h cache TTL happens to lapse;
    //  ~6s    the once-a-WEEK playlist re-sync (no-op the other days).
    if (active != null && !_kickedOffSync) {
      _kickedOffSync = true;
      Future.delayed(const Duration(seconds: 2), () async {
        if (!mounted) return;
        // Account sync FIRST (one edge round trip): pulled prog rows must be
        // in place before hydrateEpisodeProgress evaluates its freshness
        // guard, or it re-seeds rows a peer already superseded.
        await runSync(ref);
        if (!mounted) return;
        try {
          final svc = await ref.read(traktServiceProvider.future);
          // Local watch events queued while offline / token-expired reach
          // Trakt BEFORE the pull below, so the refreshed snapshots already
          // include them — local and Trakt agree within seconds of open.
          await svc.flushOutbox();
          final changed = await svc.refreshHomeSnapshots();
          if (changed && mounted) {
            // Something new landed on Trakt since last open — re-run the
            // reconciliation now (not on the hourly timer) and re-emit every
            // row that overlays Trakt state.
            final repo = await ref.read(repositoryProvider.future);
            await repo.setSetting('trakt_watched_sync_at', '0');
            ref.invalidate(continueWatchingProvider);
            ref.invalidate(watchedIdsProvider);
            ref.invalidate(progressFractionsProvider);
            ref.invalidate(traktWatchlistProvider);
            ref.invalidate(traktWatchedEpisodesProvider);
          }
        } catch (_) {/* offline — snapshots already shown */}
      });
      Future.delayed(const Duration(seconds: 6), () async {
        if (!mounted) return;
        ref.read(syncControllerProvider.notifier).resync(active);
        try {
          final repo = await ref.read(repositoryProvider.future);
          await repo.db.pruneOrphanCaches();
        } catch (_) {/* housekeeping — never surfaces */}
      });
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        body: Stack(children: [
          // ---- Pages ----
          // NB: row-aware Up/Down traversal is applied *per page* (only on the
          // shelf-stack pages — Home, My Stuff), never globally: pages with
          // side-by-side vertical lists (Live) must keep default directional
          // traversal or Up/Down would jump across columns.
          Positioned.fill(
            child: NotificationListener<UserScrollNotification>(
              onNotification: compact ? _onPageScroll : null,
              child: _LazyStack(
                index: tab,
                purge: _purgePages,
                builders: [
                  () => const AuroraSearchPage(),
                  () => const AuroraHomePage(),
                  () => const AuroraBrowsePage(kind: StreamKind.movie),
                  () => const AuroraBrowsePage(kind: StreamKind.series),
                  () => const AuroraLivePage(),
                  () => const AuroraSportsPage(),
                  () => const AuroraMyStuffPage(),
                  () => const AuroraSettingsPage(),
                ],
              ),
            ),
          ),
          // ---- Top scrim so the translucent bar reads over any artwork ----
          // Compact gets a shorter one: the slim header floats over the hero
          // rather than sitting on an opaque strip.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: compact ? MediaQuery.of(context).padding.top + 78 : 140,
            child: const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xE606070B), Color(0x0006070B)],
                  ),
                ),
              ),
            ),
          ),
          // ---- Navigation ----
          // Wide (10-foot): one top tab bar, driven by the remote.
          // Compact (phone): a slim header that carries only the wordmark and
          // the Search / Settings icons, with the tabs themselves in a
          // floating glass bar at the bottom — thumb-reachable, and it shrinks
          // to bare icons as you scroll.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: compact
                  ? _CompactHeader(
                      selected: tab, onSelect: _select, nodes: _nodes)
                  : _TopBar(selected: tab, onSelect: _select, nodes: _nodes),
            ),
          ),
          if (compact)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AuroraBottomNav(
                selected: tab,
                onSelect: _select,
                nodes: _nodes,
                expanded: _navExpanded,
              ),
            ),
        ]),
      ),
    );
  }
}

/// Phone header: wordmark, background-sync spinner, Search and Settings.
/// Deliberately spare — every destination lives in the bottom bar now, so
/// this strip only carries the two actions that aren't tabs you dwell in.
class _CompactHeader extends ConsumerWidget {
  const _CompactHeader({
    required this.selected,
    required this.onSelect,
    required this.nodes,
  });
  final int selected;
  final ValueChanged<AuroraTab> onSelect;
  final Map<AuroraTab, FocusNode> nodes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final margin = Aurora.margin(context);
    final sync = ref.watch(syncControllerProvider);
    return SizedBox(
      height: 54,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: margin - 4),
        child: Row(children: [
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: ShaderMask(
              shaderCallback: (r) => Aurora.gradient.createShader(r),
              child: const Text('lumen',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.8,
                      color: Colors.white)),
            ),
          ),
          const Spacer(),
          if (sync.running) ...[
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Aurora.textDim),
            ),
            const SizedBox(width: 12),
          ],
          _HeaderIcon(
            icon: Icons.search_rounded,
            label: 'Search',
            selected: selected == AuroraTab.search.index,
            focusNode: nodes[AuroraTab.search],
            onPick: () => onSelect(AuroraTab.search),
          ),
          const SizedBox(width: 2),
          _HeaderIcon(
            icon: Icons.settings_outlined,
            label: 'Settings',
            selected: selected == AuroraTab.settings.index,
            focusNode: nodes[AuroraTab.settings],
            onPick: () => onSelect(AuroraTab.settings),
          ),
        ]),
      ),
    );
  }
}

class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPick,
    this.focusNode,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPick;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return AuroraFocusable(
      ring: false,
      scale: 1.0,
      focusNode: focusNode,
      onActivate: onPick,
      centerOnFocus: false,
      autoScroll: false,
      builder: (context, focused) => AnimatedContainer(
        duration: Aurora.fast,
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: focused
              ? Colors.white
              : (selected ? Aurora.glass : Colors.transparent),
          shape: BoxShape.circle,
        ),
        child: Icon(icon,
            size: 21,
            semanticLabel: label,
            color: focused
                ? Aurora.bg
                : (selected ? Aurora.text : Aurora.textDim)),
      ),
    );
  }
}

class _TopBar extends ConsumerStatefulWidget {
  const _TopBar({
    required this.selected,
    required this.onSelect,
    required this.nodes,
  });
  final int selected;
  final ValueChanged<AuroraTab> onSelect;
  final Map<AuroraTab, FocusNode> nodes;

  @override
  ConsumerState<_TopBar> createState() => _TopBarState();
}

class _TopBarState extends ConsumerState<_TopBar> {
  static const _mainTabs = [
    AuroraTabSpec(AuroraTab.search, 'Search', Icons.search_rounded),
    AuroraTabSpec(AuroraTab.home, 'Home'),
    AuroraTabSpec(AuroraTab.movies, 'Movies'),
    AuroraTabSpec(AuroraTab.shows, 'TV Shows'),
    AuroraTabSpec(AuroraTab.live, 'Live'),
    AuroraTabSpec(AuroraTab.sports, 'Sports'),
    AuroraTabSpec(AuroraTab.myStuff, 'My Stuff'),
  ];

  Map<AuroraTab, FocusNode> get _nodes => widget.nodes;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// Focusing a tab switches to it — a quick debounce coalesces a fast
  /// left/right sweep so only the tab you settle on commits (and its page
  /// cross-dissolves in). This is the "auto fade switch on focus" behaviour.
  void _focusTab(AuroraTab tab, bool focused) {
    if (!focused) return;
    // Not while a route sits above us, and not in the settling window right
    // after one popped: focus lands on a tab node by accident in both cases,
    // and committing that as navigation is the "Back went to Home / Search"
    // bug. See [auroraSuppressFocusTabUntil].
    if (auroraFocusTabSuppressed) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 90), () {
      if (mounted && !auroraFocusTabSuppressed) widget.onSelect(tab);
    });
  }

  void _pickTab(AuroraTab tab) {
    _debounce?.cancel();
    widget.onSelect(tab);
  }

  @override
  Widget build(BuildContext context) {
    final margin = Aurora.margin(context);
    final sync = ref.watch(syncControllerProvider);
    final wide = MediaQuery.of(context).size.width >= 760;

    return Container(
      height: 64,
      padding: EdgeInsets.symmetric(horizontal: margin),
      child: Row(children: [
        // Brand
        ShaderMask(
          shaderCallback: (r) => Aurora.gradient.createShader(r),
          child: const Text('lumen',
              style: TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                  color: Colors.white)),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: Aurora.hairline),
          ),
          child: const Text('AURORA',
              style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
                  color: Aurora.textDim)),
        ),
        SizedBox(width: wide ? 28 : 12),
        // Tabs
        Expanded(
          child: FocusTraversalGroup(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              child: Row(children: [
                for (final t in _mainTabs)
                  _TabItem(
                    spec: t,
                    selected: widget.selected == t.tab.index,
                    focusNode: _nodes[t.tab],
                    onFocus: (f) => _focusTab(t.tab, f),
                    onPick: () => _pickTab(t.tab),
                    compact: !wide,
                  ),
              ]),
            ),
          ),
        ),
        // Background re-sync status — quiet, informative.
        if (sync.running) ...[
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Aurora.textDim),
          ),
          const SizedBox(width: 8),
          if (wide)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Text(sync.stage ?? 'Refreshing…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Aurora.caption),
            ),
          const SizedBox(width: 12),
        ],
        _TabItem(
          spec: const AuroraTabSpec(
              AuroraTab.settings, 'Settings', Icons.settings_outlined),
          selected: widget.selected == AuroraTab.settings.index,
          focusNode: _nodes[AuroraTab.settings],
          onFocus: (f) => _focusTab(AuroraTab.settings, f),
          onPick: () => _pickTab(AuroraTab.settings),
          compact: true, // icon-only, always
        ),
      ]),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.spec,
    required this.selected,
    required this.onFocus,
    required this.onPick,
    required this.compact,
    this.focusNode,
  });

  final AuroraTabSpec spec;
  final bool selected;
  final ValueChanged<bool> onFocus;
  final VoidCallback onPick;
  final bool compact;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final iconOnly = spec.icon != null && compact;
    return AuroraFocusable(
      ring: false,
      scale: 1.0,
      focusNode: focusNode,
      onActivate: onPick,
      onFocusChange: onFocus,
      builder: (context, focused) => AnimatedContainer(
        duration: Aurora.fast,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: EdgeInsets.symmetric(
            horizontal: iconOnly ? 10 : 15, vertical: 7.5),
        decoration: BoxDecoration(
          color: focused
              ? Colors.white
              : (selected ? Aurora.glass : Colors.transparent),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (spec.icon != null)
            Icon(spec.icon,
                size: 19,
                color: focused
                    ? Aurora.bg
                    : (selected ? Aurora.text : Aurora.textDim)),
          if (!iconOnly) ...[
            if (spec.icon != null) const SizedBox(width: 6),
            Text(
              spec.label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected || focused
                    ? FontWeight.w800
                    : FontWeight.w600,
                color: focused
                    ? Aurora.bg
                    : (selected ? Aurora.text : Aurora.textDim),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

/// Lazy, state-preserving page host with a true cross-dissolve between tabs.
///
/// Like an IndexedStack, pages build on first visit and stay mounted (Offstage)
/// so scroll + focus state survives — but on a tab change the outgoing and
/// incoming pages are painted together with crossfading opacity, so switching
/// is a seamless fade rather than a blank-then-appear flicker.
class _LazyStack extends StatefulWidget {
  const _LazyStack({
    required this.index,
    required this.builders,
    required this.purge,
  });
  final int index;
  final List<Widget Function()> builders;

  /// Bumped by the shell on OS memory pressure: drop every parked page.
  final ValueListenable<int> purge;

  @override
  State<_LazyStack> createState() => _LazyStackState();
}

class _LazyStackState extends State<_LazyStack>
    with SingleTickerProviderStateMixin {
  final Map<int, Widget> _built = {};

  /// Least-recently-shown first. Bounds how many pages stay mounted.
  final List<int> _mru = [];

  /// How many pages keep their state while parked.
  ///
  /// Unbounded retention is what made "it gets slower and then dies" a
  /// browsing pattern rather than a one-off: an Offstage page is still a
  /// mounted subtree, so every card image it ever resolved stays a LIVE image
  /// — and live images are exempt from `imageCache.maximumSizeBytes`. Visit
  /// all eight tabs and the cap is enforcing nothing at all. Three covers the
  /// realistic there-and-back (Home → Movies → detail → Home) with scroll and
  /// focus intact; anything older rebuilds from its providers, which are
  /// snapshot-backed and repaint immediately.
  static const _keepAlive = 3;

  late final AnimationController _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 260))
    ..value = 1;

  late int _to = widget.index; // fading in / shown
  int _from = 0; // fading out during a transition

  @override
  void initState() {
    super.initState();
    widget.purge.addListener(_purgeParked);
  }

  @override
  void didUpdateWidget(covariant _LazyStack old) {
    super.didUpdateWidget(old);
    if (old.purge != widget.purge) {
      old.purge.removeListener(_purgeParked);
      widget.purge.addListener(_purgeParked);
    }
    if (old.index != widget.index) {
      _from = _to;
      _to = widget.index;
      _ctrl.forward(from: 0);
    }
  }

  /// Memory pressure: nothing but the page being looked at survives.
  void _purgeParked() {
    if (!mounted) return;
    setState(() {
      _built.removeWhere((i, _) => i != _to);
      _mru
        ..clear()
        ..add(_to);
      _from = _to;
    });
  }

  /// Evict the oldest parked pages once more than [_keepAlive] are mounted.
  /// Never the page on screen, and never the one still fading out.
  void _trim() {
    while (_mru.length > _keepAlive) {
      final victim = _mru.firstWhere((i) => i != _to && i != _from,
          orElse: () => -1);
      if (victim < 0) break;
      _mru.remove(victim);
      _built.remove(victim);
    }
  }

  @override
  void dispose() {
    widget.purge.removeListener(_purgeParked);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _built.putIfAbsent(_to, () => widget.builders[_to]());
    _mru
      ..remove(_to)
      ..add(_to);
    // Build the outgoing page only while actually transitioning (not on first
    // mount) so we don't eagerly build a page the user never opened.
    if (_from != _to && _ctrl.value < 1) {
      _built.putIfAbsent(_from, () => widget.builders[_from]());
    }
    _trim();
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_ctrl.value);
        final settled = _ctrl.value >= 1;
        return Stack(fit: StackFit.expand, children: [
          for (var i = 0; i < widget.builders.length; i++)
            _layer(i, t, settled),
        ]);
      },
    );
  }

  Widget _layer(int i, double t, bool settled) {
    final child = _built[i];
    if (child == null) return const SizedBox.shrink();
    double opacity;
    if (settled) {
      opacity = i == _to ? 1 : 0;
    } else if (i == _to) {
      opacity = t;
    } else if (i == _from) {
      opacity = 1 - t;
    } else {
      opacity = 0;
    }
    final visible = opacity > 0.001;
    // Only the destination page is interactive/focusable; the fading-out page
    // is inert. Offstage keeps hidden pages mounted (state preserved).
    return Offstage(
      offstage: !visible,
      child: IgnorePointer(
        ignoring: i != _to,
        child: ExcludeFocus(
          excluding: i != _to,
          child: Opacity(opacity: opacity.clamp(0.0, 1.0), child: child),
        ),
      ),
    );
  }
}
