import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../ui/input_mode.dart' show InputMode;

/// Aurora's single focus primitive. Every interactive surface in the new
/// experience goes through this so the whole app speaks one focus language:
/// a white ring, a gentle lift and a soft drop shadow — Apple TV-style —
/// shown only while the user is actually driving with a remote/keyboard.
///
/// [onLeft]/[onRight]/[onUp]/[onDown] intercept edge arrows at this item
/// (paging a hero, jumping to a sibling control); unhandled arrows fall
/// through to normal spatial traversal.
class AuroraFocusable extends StatefulWidget {
  const AuroraFocusable({
    super.key,
    required this.onActivate,
    required this.builder,
    this.autofocus = false,
    this.focusNode,
    this.radius = 14,
    this.scale = 1.05,
    this.ring = true,
    this.onLeft,
    this.onRight,
    this.onUp,
    this.onDown,
    this.onFocusChange,
    this.centerOnFocus = true,
  });

  final VoidCallback onActivate;

  /// Builds the content; [focused] is true only in remote/keyboard mode.
  final Widget Function(BuildContext context, bool focused) builder;
  final bool autofocus;
  final FocusNode? focusNode;
  final double radius;
  final double scale;

  /// Set false when the surface draws its own focus treatment (e.g. tabs).
  final bool ring;
  final VoidCallback? onLeft;
  final VoidCallback? onRight;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final ValueChanged<bool>? onFocusChange;

  /// When focused inside a *horizontal* scroller, glide that scroller so this
  /// item eases toward centre — the "cards flow rather than jump" feel. No-op
  /// when the nearest scroller is vertical (page scroll stays calm).
  final bool centerOnFocus;

  @override
  State<AuroraFocusable> createState() => _AuroraFocusableState();
}

class _AuroraFocusableState extends State<AuroraFocusable> {
  bool _focused = false;

  /// Smoothly bring this item toward the centre of its nearest *horizontal*
  /// scrollable. Flutter's focus traversal snaps (zero-duration ensureVisible);
  /// easing to centre right after turns that snap into a glide.
  void _glideIntoView() {
    if (!widget.centerOnFocus || !mounted) return;
    final scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) return;
    final pos = scrollable.position;
    if (pos.axis != Axis.horizontal) return;
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.attached) return;
    try {
      final viewport = RenderAbstractViewport.of(ro);
      final target = viewport
          .getOffsetToReveal(ro, 0.5)
          .offset
          .clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if ((target - pos.pixels).abs() < 2) return;
      pos.animateTo(target,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic);
    } catch (_) {/* no viewport / detached — nothing to glide */}
  }

  KeyEventResult _onEdgeKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowLeft && widget.onLeft != null) {
      widget.onLeft!();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight && widget.onRight != null) {
      widget.onRight!();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp && widget.onUp != null) {
      widget.onUp!();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown && widget.onDown != null) {
      widget.onDown!();
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
        if (mounted && v != _focused) {
          setState(() => _focused = v);
          widget.onFocusChange?.call(v);
        }
      },
      onFocusChange: (v) {
        // Fires on true focus (remote or pointer), so gliding works even when
        // the highlight is suppressed during pointer use.
        if (v) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _glideIntoView());
        }
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onActivate();
            return null;
          },
        ),
      },
      child: ValueListenableBuilder<bool>(
        valueListenable: InputMode.keyboard,
        builder: (context, keyboardMode, _) {
          final hi = _focused && keyboardMode;
          return GestureDetector(
            onTap: widget.onActivate,
            child: AnimatedScale(
              scale: hi ? widget.scale : 1.0,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              child: widget.ring
                  ? AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOutCubic,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(widget.radius),
                        border: Border.all(
                          color: hi ? Colors.white : Colors.transparent,
                          width: 2.4,
                        ),
                        boxShadow: hi
                            ? const [
                                BoxShadow(
                                  color: Color(0x8A000000),
                                  blurRadius: 26,
                                  offset: Offset(0, 10),
                                ),
                              ]
                            : null,
                      ),
                      child: widget.builder(context, hi),
                    )
                  : widget.builder(context, hi),
            ),
          );
        },
      ),
    );

    final hasEdges = widget.onLeft != null ||
        widget.onRight != null ||
        widget.onUp != null ||
        widget.onDown != null;
    if (!hasEdges) return detector;
    // Intercept edge arrows without becoming a focus stop itself.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onEdgeKey,
      child: detector,
    );
  }
}
