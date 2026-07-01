import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../input_mode.dart' show InputMode;
import '../theme/lumen_theme.dart';

/// Wraps any tappable surface to make it remote/keyboard friendly:
/// - reachable with arrow keys (MaterialApp maps them to directional focus)
/// - clearly highlighted while focused (scale + accent glow)
/// - activates on Enter / Space / D-pad-select, and on tap/click
///
/// [onLeft]/[onRight] optionally intercept the left/right arrows at this item
/// (e.g. to page a carousel from its edge button); when they don't fire, the
/// arrow falls through to normal directional focus traversal.
class FocusableItem extends StatefulWidget {
  const FocusableItem({
    super.key,
    required this.onActivate,
    required this.builder,
    this.autofocus = false,
    this.borderRadius = 14,
    this.focusNode,
    this.onLeft,
    this.onRight,
  });

  final VoidCallback onActivate;
  final Widget Function(BuildContext context, bool focused) builder;
  final bool autofocus;
  final double borderRadius;
  final FocusNode? focusNode;
  final VoidCallback? onLeft;
  final VoidCallback? onRight;

  @override
  State<FocusableItem> createState() => _FocusableItemState();
}

class _FocusableItemState extends State<FocusableItem> {
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
        widget.onLeft != null) {
      widget.onLeft!();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
        widget.onRight != null) {
      widget.onRight!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final detector = FocusableActionDetector(
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
      // Only paint the remote-style highlight when the user is actually driving
      // by keyboard/remote — never during mouse/trackpad use.
      child: ValueListenableBuilder<bool>(
        valueListenable: InputMode.keyboard,
        builder: (context, keyboardMode, _) {
          final hi = _focused && keyboardMode;
          return GestureDetector(
            onTap: widget.onActivate,
            child: AnimatedScale(
              scale: hi ? 1.04 : 1.0,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.borderRadius),
                  border: Border.all(
                    color: hi ? LumenTheme.accent : Colors.transparent,
                    width: 2.5,
                  ),
                  boxShadow: hi
                      ? [
                          BoxShadow(
                            color: LumenTheme.accent.withValues(alpha: 0.45),
                            blurRadius: 18,
                            spreadRadius: 1,
                          )
                        ]
                      : null,
                ),
                child: widget.builder(context, hi),
              ),
            ),
          );
        },
      ),
    );

    if (widget.onLeft == null && widget.onRight == null) return detector;
    // Intercept edge arrows without becoming a focus stop itself.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: detector,
    );
  }
}
