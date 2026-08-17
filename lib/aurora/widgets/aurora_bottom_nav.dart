import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../aurora_focus.dart';
import '../aurora_providers.dart';
import '../aurora_theme.dart';

/// The phone navigation: a floating, frosted tab bar that hovers over the
/// content instead of a top tab strip.
///
/// Behaviour follows the current iOS pattern — the bar rests fully expanded
/// with the active tab labelled in a pill, and **shrinks down to bare icons**
/// as you scroll into a page, springing back the moment you scroll up. It
/// never hides: navigation on a phone should always be one thumb-reach away.
///
/// Real [BackdropFilter] glass is used here deliberately, and only here: this
/// widget renders on compact layouts only, so the 10-foot experience (where
/// Android TV GPUs choke on blur) never pays for it. Everything on the TV path
/// still uses Aurora's layered-translucency "glass".
class AuroraBottomNav extends StatelessWidget {
  const AuroraBottomNav({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.nodes,
    required this.expanded,
  });

  static const tabs = [
    AuroraTabSpec(AuroraTab.home, 'Home', Icons.home_rounded),
    AuroraTabSpec(AuroraTab.movies, 'Movies', Icons.movie_rounded),
    AuroraTabSpec(AuroraTab.shows, 'Shows', Icons.tv_rounded),
    AuroraTabSpec(AuroraTab.live, 'Live', Icons.sensors_rounded),
    AuroraTabSpec(AuroraTab.sports, 'Sports', Icons.sports_basketball_rounded),
    AuroraTabSpec(AuroraTab.myStuff, 'My Stuff', Icons.bookmark_rounded),
  ];

  final int selected;
  final ValueChanged<AuroraTab> onSelect;
  final Map<AuroraTab, FocusNode> nodes;

  /// False while the user is scrolling down — the bar contracts to icons.
  final ValueListenable<bool> expanded;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 0, 14, bottomInset > 0 ? 10 : 14),
      child: ValueListenableBuilder<bool>(
        valueListenable: expanded,
        builder: (context, open, _) => Center(
          child: AnimatedContainer(
            duration: Aurora.normal,
            curve: Curves.easeOutCubic,
            height: open ? 62 : 52,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(34),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: open ? 0.46 : 0.34),
                  blurRadius: 26,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(34),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // Tinted, not opaque: the artwork underneath stays felt.
                    color: const Color(0xFF0B0D14).withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(34),
                    border: Border.all(color: const Color(0x2EFFFFFF)),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: open ? 8 : 6, vertical: 6),
                    // scaleDown so six tabs can never overflow a narrow phone.
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        for (final t in tabs)
                          _NavItem(
                            spec: t,
                            selected: selected == t.tab.index,
                            expanded: open,
                            focusNode: nodes[t.tab],
                            onPick: () => onSelect(t.tab),
                          ),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.spec,
    required this.selected,
    required this.expanded,
    required this.onPick,
    this.focusNode,
  });

  final AuroraTabSpec spec;
  final bool selected;
  final bool expanded;
  final VoidCallback onPick;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    // The active tab wears a label; the rest stay icons. Contracting the bar
    // drops the label too, so scrolled-down state is a pure icon strip.
    final showLabel = selected && expanded;
    return AuroraFocusable(
      ring: false,
      scale: 1.0,
      focusNode: focusNode,
      onActivate: onPick,
      centerOnFocus: false,
      autoScroll: false,
      builder: (context, focused) => AnimatedContainer(
        duration: Aurora.normal,
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: EdgeInsets.symmetric(
            horizontal: showLabel ? 14 : 12, vertical: expanded ? 9 : 6),
        decoration: BoxDecoration(
          color: focused
              ? Colors.white
              : (selected ? const Color(0x24FFFFFF) : Colors.transparent),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(
            spec.icon,
            size: expanded ? 22 : 20,
            color: focused
                ? Aurora.bg
                : (selected ? Aurora.text : Aurora.textDim),
          ),
          // AnimatedSize keeps the pill's growth/shrink continuous with the
          // bar's own height animation instead of snapping a label in.
          AnimatedSize(
            duration: Aurora.normal,
            curve: Curves.easeOutCubic,
            child: showLabel
                ? Padding(
                    padding: const EdgeInsets.only(left: 7, right: 1),
                    child: Text(
                      spec.label,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                        color: focused ? Aurora.bg : Aurora.text,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ]),
      ),
    );
  }
}
