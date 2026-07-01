import 'package:flutter/material.dart';

import '../theme/lumen_theme.dart';
import 'focusable_item.dart';

class NavRailItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const NavRailItem(this.icon, this.selectedIcon, this.label);
}

/// Netflix-style left navigation: collapsed to icons for a clean look, expands
/// to reveal labels when hovered or when any item is focused (remote/keyboard).
class NavRail extends StatefulWidget {
  const NavRail({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<NavRailItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  State<NavRail> createState() => _NavRailState();
}

class _NavRailState extends State<NavRail> {
  bool _hovered = false;
  bool _focused = false;

  bool get _expanded => _hovered || _focused;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (has) => setState(() => _focused = has),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: _expanded ? 212 : 72,
          decoration: const BoxDecoration(
            color: Color(0xFF0D0E13),
            border: Border(right: BorderSide(color: Color(0xFF1C1F29))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              for (var i = 0; i < widget.items.length; i++)
                _RailButton(
                  item: widget.items[i],
                  selected: i == widget.selectedIndex,
                  expanded: _expanded,
                  onTap: () => widget.onSelect(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.item,
    required this.selected,
    required this.expanded,
    required this.onTap,
  });

  final NavRailItem item;
  final bool selected;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: FocusableItem(
        borderRadius: 12,
        onActivate: onTap,
        builder: (context, focused) => Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: selected
                ? LumenTheme.accent.withValues(alpha: 0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                selected ? item.selectedIcon : item.icon,
                size: 22,
                color: selected || focused
                    ? LumenTheme.accent
                    : const Color(0xFFC7CBD6),
              ),
              if (expanded) ...[
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? Colors.white : const Color(0xFFC7CBD6),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
