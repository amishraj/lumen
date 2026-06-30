import 'package:flutter/material.dart';

import '../theme/lumen_theme.dart';

/// Wraps any tappable surface to make it remote/keyboard friendly:
/// - reachable with arrow keys (MaterialApp maps them to directional focus)
/// - clearly highlighted while focused (scale + accent glow)
/// - activates on Enter / Space / D-pad-select, and on tap/click
///
/// This is the building block for end-to-end TV navigation.
class FocusableItem extends StatefulWidget {
  const FocusableItem({
    super.key,
    required this.onActivate,
    required this.builder,
    this.autofocus = false,
    this.borderRadius = 14,
    this.focusNode,
  });

  final VoidCallback onActivate;
  final Widget Function(BuildContext context, bool focused) builder;
  final bool autofocus;
  final double borderRadius;
  final FocusNode? focusNode;

  @override
  State<FocusableItem> createState() => _FocusableItemState();
}

class _FocusableItemState extends State<FocusableItem> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (v) {
        if (mounted) setState(() => _focused = v);
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onActivate();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onActivate,
        child: AnimatedScale(
          scale: _focused ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              border: Border.all(
                color: _focused ? LumenTheme.accent : Colors.transparent,
                width: 2.5,
              ),
              boxShadow: _focused
                  ? [
                      BoxShadow(
                        color: LumenTheme.accent.withValues(alpha: 0.45),
                        blurRadius: 18,
                        spreadRadius: 1,
                      )
                    ]
                  : null,
            ),
            child: widget.builder(context, _focused),
          ),
        ),
      ),
    );
  }
}
