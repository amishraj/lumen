import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
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
import '../data/models/models.dart';

/// The Aurora root: an Apple TV-style translucent top bar over full-bleed
/// pages. Pages live in a lazy IndexedStack so each keeps its scroll/focus
/// state, but nothing builds until first visited.
class AuroraShell extends ConsumerStatefulWidget {
  const AuroraShell({super.key});

  @override
  ConsumerState<AuroraShell> createState() => _AuroraShellState();
}

class _AuroraShellState extends ConsumerState<AuroraShell> {
  DateTime? _lastBack;
  bool _kickedOffSync = false;

  void _select(AuroraTab tab) {
    ref.read(auroraTabProvider.notifier).state = tab.index;
  }

  /// Back bounces to Home first; on Home a second press within 2s exits.
  void _onBack() {
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

    // One delayed background re-sync per session, after first paint has had
    // time to query — kicking it off immediately made first browse sluggish.
    if (active != null && !_kickedOffSync) {
      _kickedOffSync = true;
      Future.delayed(const Duration(seconds: 6), () {
        if (!mounted) return;
        ref.read(syncControllerProvider.notifier).resync(active);
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
          Positioned.fill(
            child: _LazyStack(
              index: tab,
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
          // ---- Top scrim so the bar reads over any artwork ----
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 140,
            child: IgnorePointer(
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
          // ---- Top navigation ----
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: _TopBar(selected: tab, onSelect: _select),
            ),
          ),
        ]),
      ),
    );
  }
}

class _TopBar extends ConsumerStatefulWidget {
  const _TopBar({required this.selected, required this.onSelect});
  final int selected;
  final ValueChanged<AuroraTab> onSelect;

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

  // Tabs switch only on OK/click — never merely on focus. Auto-switching on
  // focus made a left/right sweep flicker through every page and "navigate on
  // its own"; now Left/Right just move the highlight and OK commits.
  void _pickTab(AuroraTab tab) => widget.onSelect(tab);

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
                    // The active tab holds the shared nav node so pages can
                    // send focus back up here (▲ from their top row).
                    focusNode: widget.selected == t.tab.index
                        ? auroraNavFocusNode
                        : null,
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
          focusNode: widget.selected == AuroraTab.settings.index
              ? auroraNavFocusNode
              : null,
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
    required this.onPick,
    required this.compact,
    this.focusNode,
  });

  final AuroraTabSpec spec;
  final bool selected;
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

/// IndexedStack that builds children on first visit only and keeps hidden
/// pages focus-inert (an offstage page must never catch remote focus).
class _LazyStack extends StatefulWidget {
  const _LazyStack({required this.index, required this.builders});
  final int index;
  final List<Widget Function()> builders;

  @override
  State<_LazyStack> createState() => _LazyStackState();
}

class _LazyStackState extends State<_LazyStack>
    with SingleTickerProviderStateMixin {
  final Map<int, Widget> _built = {};

  // A gentle fade + upward glide replays on every tab change, so pages flow
  // into place instead of snapping. IndexedStack still preserves each page's
  // scroll + focus state underneath.
  late final AnimationController _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 300))
    ..value = 1;
  late final Animation<double> _fade =
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
  late final Animation<Offset> _slide = Tween(
    begin: const Offset(0, 0.02),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

  @override
  void didUpdateWidget(covariant _LazyStack old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _ctrl.forward(from: 0);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _built.putIfAbsent(widget.index, () => widget.builders[widget.index]());
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: IndexedStack(
          index: widget.index,
          children: [
            for (var i = 0; i < widget.builders.length; i++)
              ExcludeFocus(
                excluding: i != widget.index,
                child: _built[i] ?? const SizedBox.shrink(),
              ),
          ],
        ),
      ),
    );
  }
}
