import 'package:flutter/material.dart';

import '../aurora_focus.dart';
import '../aurora_theme.dart';

/// Aurora's pill button. [primary] renders the Apple-TV-style solid white
/// pill (dark label); otherwise a glass pill. Focus = ring + lift, and the
/// glass variant also brightens so the state reads at 10 feet.
class AuroraPillButton extends StatelessWidget {
  const AuroraPillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.primary = false,
    this.autofocus = false,
    this.focusNode,
    this.onLeft,
    this.onRight,
    this.onUp,
    this.onDown,
    this.compact = false,
    this.autoScroll = true,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool primary;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback? onLeft;
  final VoidCallback? onRight;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final bool compact;

  /// Set false when a parent drives its own scroll on focus (home hero).
  final bool autoScroll;

  @override
  Widget build(BuildContext context) {
    final fg = primary ? Aurora.bg : Aurora.text;
    return AuroraFocusable(
      autofocus: autofocus,
      focusNode: focusNode,
      onActivate: onPressed,
      onLeft: onLeft,
      onRight: onRight,
      onUp: onUp,
      onDown: onDown,
      autoScroll: autoScroll,
      radius: 28,
      scale: 1.04,
      builder: (context, focused) => AnimatedContainer(
        duration: Aurora.fast,
        padding: EdgeInsets.symmetric(
            horizontal: compact ? 18 : 26, vertical: compact ? 10 : 13),
        decoration: BoxDecoration(
          color: primary
              ? Colors.white
              : (focused ? Aurora.glassHi : Aurora.glass),
          borderRadius: BorderRadius.circular(28),
          border: primary ? null : Border.all(color: Aurora.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: compact ? 18 : 21, color: fg),
              const SizedBox(width: 8),
            ],
            Text(label,
                style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w700,
                    fontSize: compact ? 13.5 : 15)),
          ],
        ),
      ),
    );
  }
}

/// Circular glass icon button (player chrome, top-bar actions).
class AuroraIconButton extends StatelessWidget {
  const AuroraIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size = 20,
    this.enabled = true,
    this.active = false,
    this.autofocus = false,
    this.focusNode,
    this.onActivity,
    this.onLeft,
    this.onRight,
    this.onUp,
    this.onDown,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final double size;
  final bool enabled;

  /// Highlights the icon (e.g. favorited, subtitle on).
  final bool active;
  final bool autofocus;
  final FocusNode? focusNode;

  /// Fired on every activation — lets the player keep its hide-timer alive.
  final VoidCallback? onActivity;

  /// Edge-arrow intercepts (e.g. the player's big play button seeks on ◀ ▶).
  final VoidCallback? onLeft;
  final VoidCallback? onRight;
  final VoidCallback? onUp;
  final VoidCallback? onDown;

  @override
  Widget build(BuildContext context) {
    final btn = AuroraFocusable(
      autofocus: autofocus,
      focusNode: focusNode,
      radius: 40,
      scale: 1.08,
      onLeft: onLeft,
      onRight: onRight,
      onUp: onUp,
      onDown: onDown,
      onActivate: () {
        onActivity?.call();
        if (enabled) onPressed();
      },
      builder: (context, focused) => AnimatedContainer(
        duration: Aurora.fast,
        padding: EdgeInsets.all(size * 0.52),
        decoration: BoxDecoration(
          color: focused ? Aurora.glassHi : const Color(0x59000000),
          shape: BoxShape.circle,
          border: Border.all(
              color: focused ? Colors.transparent : Aurora.hairline),
        ),
        child: Icon(
          icon,
          size: size,
          color: !enabled
              ? Aurora.textFaint
              : (active ? Aurora.accent : Colors.white),
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// A quiet list row used across Aurora settings/panels: leading icon,
/// title/subtitle, chevron or custom trailing.
class AuroraListRow extends StatelessWidget {
  const AuroraListRow({
    super.key,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.icon,
    this.iconColor,
    this.trailing,
    this.autofocus = false,
    this.destructive = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? iconColor;
  final Widget? trailing;
  final VoidCallback onTap;
  final bool autofocus;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return AuroraFocusable(
      autofocus: autofocus,
      onActivate: onTap,
      radius: 16,
      scale: 1.01,
      builder: (context, focused) => AnimatedContainer(
        duration: Aurora.fast,
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: focused ? Aurora.glassHi : Aurora.glass,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Aurora.hairline),
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon,
                  size: 21,
                  color: destructive
                      ? Aurora.live
                      : (iconColor ?? Aurora.textDim)),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14.5,
                          color: destructive ? Aurora.live : Aurora.text)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12.5, color: Aurora.textDim)),
                  ],
                ],
              ),
            ),
            trailing ??
                const Icon(Icons.chevron_right_rounded,
                    color: Aurora.textFaint),
          ],
        ),
      ),
    );
  }
}
