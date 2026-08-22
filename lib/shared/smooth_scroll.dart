import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/widgets.dart';

/// A [ScrollController] whose mouse-wheel scrolling glides instead of jumping.
///
/// Flutter treats a wheel notch as a teleport: `Scrollable._handlePointerScroll`
/// calls `ScrollPosition.pointerScroll`, which is a `forcePixels` — the content
/// is simply somewhere else on the next frame. Remote and keyboard navigation
/// feel smooth by comparison only because focus traversal moves the viewport
/// with an animation, so the whole app reads as "smooth on the remote, choppy
/// on the mouse".
///
/// There is no global hook for this. A `Listener` wrapped around the app cannot
/// preempt it, because pointer signals are dispatched from the innermost
/// hit-test target outward and `PointerSignalResolver` gives the event to the
/// *first* registrant — always the Scrollable itself. The one place left is the
/// position that Scrollable ends up calling, which is what this replaces.
///
/// Successive notches accumulate into a single moving target rather than
/// restarting the animation, so spinning the wheel fast scrolls further and
/// still lands in one continuous motion.
class SmoothScrollController extends ScrollController {
  SmoothScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
    this.duration = const Duration(milliseconds: 180),
    this.curve = Curves.easeOutCubic,
  });

  /// How long one wheel notch takes to settle. Short enough that the content
  /// keeps up with the hand; long enough to read as motion rather than a cut.
  final Duration duration;
  final Curve curve;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) =>
      _SmoothScrollPosition(
        physics: physics,
        context: context,
        oldPosition: oldPosition,
        debugLabel: debugLabel,
        wheelDuration: duration,
        wheelCurve: curve,
      );
}

class _SmoothScrollPosition extends ScrollPositionWithSingleContext {
  _SmoothScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    super.debugLabel,
    required this.wheelDuration,
    required this.wheelCurve,
  });

  final Duration wheelDuration;
  final Curve wheelCurve;

  /// Where the in-flight wheel animation is heading, or null when no wheel
  /// animation is running. Kept so a second notch extends the same glide
  /// instead of re-aiming from wherever the first one happens to have reached.
  double? _wheelTarget;

  @override
  void pointerScroll(double delta) {
    if (delta == 0.0) {
      // A zero delta is the inertia-cancel signal: stop where we are.
      _wheelTarget = null;
      super.pointerScroll(delta);
      return;
    }

    final target = ((_wheelTarget ?? pixels) + delta)
        .clamp(minScrollExtent, maxScrollExtent);
    if (target == pixels && _wheelTarget == null) return;

    _wheelTarget = target;
    updateUserScrollDirection(
        delta > 0.0 ? ScrollDirection.reverse : ScrollDirection.forward);
    animateTo(target, duration: wheelDuration, curve: wheelCurve).whenComplete(() {
      // Only clear if nothing newer has re-aimed it — otherwise a fast spin
      // would drop its accumulated target halfway through.
      if (_wheelTarget == target) _wheelTarget = null;
    });
  }

  @override
  void goIdle() {
    _wheelTarget = null;
    super.goIdle();
  }

  @override
  void jumpTo(double value) {
    _wheelTarget = null;
    super.jumpTo(value);
  }
}

/// Hands [builder] a [SmoothScrollController] that lives as long as the widget.
///
/// For the scroll views that own no controller of their own — a controller has
/// to be stable across rebuilds, so it cannot simply be constructed inline in
/// `build`. Wrap the scroll view in this and pass the controller through.
class SmoothScrollArea extends StatefulWidget {
  const SmoothScrollArea({super.key, required this.builder});

  final Widget Function(BuildContext context, ScrollController controller)
      builder;

  @override
  State<SmoothScrollArea> createState() => _SmoothScrollAreaState();
}

class _SmoothScrollAreaState extends State<SmoothScrollArea> {
  final _controller = SmoothScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}
