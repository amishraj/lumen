import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../ui/input_mode.dart' show InputMode;
import 'aurora_providers.dart' show auroraNavTarget;

/// Route Up out of a page's top row: smooth-scroll the focused element's
/// enclosing vertical scroller to the top and move focus to the active tab in
/// the top nav. Returns true when there's a nav target — so the traversal
/// policy reports the key handled and focus never leaks to a spatially-nearest
/// (wrong) tab, which was the "Up from Settings lands on TV Shows" bug.
///
/// Lives here (not in a Focus.onKeyEvent, which proved unreliable — a
/// non-focusable wrapper's key handler didn't fire) because the traversal
/// policy's inDirection IS the mechanism the framework runs for arrow keys.
bool auroraUpToNav(FocusNode from) {
  final ctx = from.context;
  if (ctx != null) {
    ScrollableState? s = Scrollable.maybeOf(ctx);
    while (s != null) {
      final pos = s.position;
      if (pos.axis == Axis.vertical) {
        // Guard the animate: hasContentDimensions/hasPixels rule out an
        // un-laid-out or detached position, and the try/catch covers the rare
        // race where the scroller disposes between check and call.
        try {
          if (pos.hasContentDimensions && pos.hasPixels && pos.pixels > 0) {
            pos.animateTo(0,
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic);
          }
        } catch (_) {/* detached mid-navigation — focus move still stands */}
        break;
      }
      s = s.context.findAncestorStateOfType<ScrollableState>();
    }
  }
  final nav = auroraNavTarget;
  if (nav == null || !nav.canRequestFocus) return false;
  try {
    nav.requestFocus();
  } catch (_) {
    return false; // node disposed between the check and here
  }
  return true;
}

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
    this.onLongPress,
    this.centerOnFocus = true,
    this.autoScroll = true,
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

  /// Pointer long-press (e.g. long-press a category chip to pin it).
  final VoidCallback? onLongPress;

  /// When focused inside a *horizontal* scroller, glide that scroller so this
  /// item eases toward centre — the "cards flow rather than jump" feel. No-op
  /// when the nearest scroller is vertical (page scroll stays calm).
  final bool centerOnFocus;

  /// Set false for surfaces that drive their own scroll on focus (e.g. the
  /// home hero, which snaps the page to the very top). Otherwise the reveal
  /// glide would fight that explicit scroll and land somewhere in between.
  final bool autoScroll;

  @override
  State<AuroraFocusable> createState() => _AuroraFocusableState();
}

class _AuroraFocusableState extends State<AuroraFocusable> {
  bool _focused = false;

  /// Smoothly bring this item into view when it gains focus. Flutter's focus
  /// traversal snaps (zero-duration ensureVisible); easing right after turns
  /// that snap into a glide. We walk *every* enclosing scrollable so a card
  /// glides toward the centre of its horizontal rail **and** the page eases
  /// vertically to keep the focused row clear of the nav bar and bottom edge —
  /// the fix that makes vertical navigation feel as smooth as horizontal.
  void _glideIntoView() {
    if (!mounted) return;
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.attached) return;

    var didHorizontal = false;
    var didVertical = false;
    ScrollableState? s = Scrollable.maybeOf(context);
    while (s != null && (!didHorizontal || !didVertical)) {
      final pos = s.position;
      if (pos.axis == Axis.horizontal) {
        if (!didHorizontal) {
          didHorizontal = true;
          if (widget.centerOnFocus) _glideHorizontalCentre(pos, ro);
        }
      } else if (!didVertical) {
        didVertical = true;
        // Reveal-only with margins: never re-centre a row that's already
        // comfortably on screen (which would fight the hero's snap-to-top and
        // cause jitter when moving sideways within a row).
        _glideVerticalReveal(s, ro);
      }
      s = s.context.findAncestorStateOfType<ScrollableState>();
    }
  }

  /// Glide a horizontal rail so [ro] eases toward its centre.
  void _glideHorizontalCentre(ScrollPosition pos, RenderBox ro) {
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
    } catch (_) {/* no viewport / detached */}
  }

  /// Ease the vertical page just enough to keep [ro] clear of the top nav bar
  /// and the bottom edge — computed from the card's box relative to the
  /// scrollable's viewport, so it's correct even though the card also lives
  /// inside a nested horizontal viewport. No-op when comfortably visible.
  void _glideVerticalReveal(ScrollableState s, RenderBox ro) {
    try {
      final pos = s.position;
      final viewportBox = s.context.findRenderObject();
      if (viewportBox is! RenderBox || !viewportBox.attached) return;
      final cardTop = ro.localToGlobal(Offset.zero, ancestor: viewportBox).dy;
      final cardBottom = cardTop + ro.size.height;
      final viewportH = viewportBox.size.height;
      const topMargin = 96.0; // clear the translucent top nav bar
      const bottomMargin = 44.0;
      double delta;
      if (cardTop < topMargin) {
        delta = cardTop - topMargin; // under the nav → ease down
      } else if (cardBottom > viewportH - bottomMargin) {
        delta = cardBottom - (viewportH - bottomMargin); // too low → ease up
      } else {
        return; // comfortably visible
      }
      final target = (pos.pixels + delta)
          .clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if ((target - pos.pixels).abs() < 2) return;
      pos.animateTo(target,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic);
    } catch (_) {/* detached — nothing to glide */}
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
        if (v && widget.autoScroll) {
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
            onLongPress: widget.onLongPress,
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

/// Up/Down traversal tuned for a page of horizontal rails. The default
/// directional policy scores by raw geometric distance, so from a card on the
/// right of one row it can skip sideways or miss the next row entirely when the
/// rows are horizontally offset. This picks the *nearest row* in the requested
/// direction, then the horizontally closest card within it — the "always lands
/// one row up/down, under your thumb" behaviour TV UIs expect.
///
/// Purely additive: Left/Right and any case with no candidate fall straight
/// through to the default policy, so it can never trap focus or regress tab
/// order. Focus is moved with a bare requestFocus() (no zero-duration
/// ensureVisible), leaving [AuroraFocusable]'s glide to scroll smoothly.
/// Must be paired with a [FocusScope] around the page content (not just this
/// [FocusTraversalGroup]) — the search below is bounded by
/// `currentNode.nearestScope`, and without a page-local scope that resolves to
/// the whole route's scope, which also contains the top nav bar. A shelf card
/// near the left margin can then line up closer to the leftmost nav tab than
/// to the actual row above it, and Up escapes to the nav bar instead of
/// moving within the page. See [AuroraRowScope].
class AuroraRowTraversalPolicy extends ReadingOrderTraversalPolicy {
  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    if (direction == TraversalDirection.up ||
        direction == TraversalDirection.down) {
      final scope = currentNode.nearestScope;
      if (scope != null) {
        final cur = currentNode.rect;
        final down = direction == TraversalDirection.down;
        FocusNode? best;
        var bestV = double.infinity;
        var bestH = double.infinity;
        for (final n in scope.traversalDescendants) {
          if (n == currentNode || !n.canRequestFocus || n.skipTraversal) {
            continue;
          }
          final r = n.rect;
          if (r.isEmpty) continue;
          final dy = r.center.dy - cur.center.dy;
          if (down ? dy <= 2 : dy >= -2) continue; // wrong direction
          final v = dy.abs();
          final h = (r.center.dx - cur.center.dx).abs();
          // Rows within ~8px count as the same band: prefer the nearer row,
          // then the horizontally closest card in it.
          if (v < bestV - 4 || (v <= bestV + 4 && h < bestH)) {
            bestV = v;
            bestH = h;
            best = n;
          }
        }
        if (best != null) {
          best.requestFocus();
          return true;
        }
      }
      // No row in that direction. For Up, hand off to the active tab in the
      // nav and snap the page to the top — never fall through to the default
      // policy, which escapes this page's scope to a spatially-nearest tab.
      if (direction == TraversalDirection.up && auroraUpToNav(currentNode)) {
        return true;
      }
    }
    return super.inDirection(currentNode, direction);
  }
}

/// Directional traversal that keeps the default geometric behaviour but, when
/// Up has no in-page destination, routes to the active tab (never a
/// spatially-nearest wrong one). For pages with side-by-side columns (Live,
/// Browse) where [AuroraRowTraversalPolicy]'s row-nearest logic would jump
/// between columns.
class AuroraUpNavPolicy extends ReadingOrderTraversalPolicy {
  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    if (super.inDirection(currentNode, direction)) return true;
    if (direction == TraversalDirection.up) return auroraUpToNav(currentNode);
    return false;
  }
}

/// Bounds a page in its own [FocusScope] + [AuroraUpNavPolicy] so Up from the
/// top returns to the page's own nav pill (and never leaks to the top bar via
/// spatial traversal). Use on pages that are NOT a single vertical stack of
/// rails — those use [AuroraRowScope].
class AuroraUpNavScope extends StatelessWidget {
  const AuroraUpNavScope({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      child: FocusTraversalGroup(
        policy: AuroraUpNavPolicy(),
        child: child,
      ),
    );
  }
}

/// Applies [AuroraRowTraversalPolicy] to a page of vertically-stacked
/// horizontal rails (Home, My Stuff). Wraps the content in its own
/// [FocusScope] so the policy's search is bounded to the page — never the top
/// nav bar, which lives in the same route but must stay untouched by Up/Down.
///
/// Don't use this on pages with side-by-side vertical lists (e.g. Live's
/// category rail + channel list) — row-nearest logic would jump between the
/// columns instead of moving within one, breaking Left/Right.
class AuroraRowScope extends StatelessWidget {
  const AuroraRowScope({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      child: FocusTraversalGroup(
        policy: AuroraRowTraversalPolicy(),
        child: child,
      ),
    );
  }
}
