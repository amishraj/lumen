import 'package:flutter/material.dart';

/// Owns a [ScrollController] for a page and hands it to [builder] — so a
/// stateless page can drive its own scrollable (needed for scroll-to-top on
/// Up-at-top, which the focus traversal policy performs on the focused
/// element's enclosing scroller).
///
/// The Up-to-nav behaviour itself now lives in the page focus policies
/// (see `auroraUpToNav` + [AuroraRowTraversalPolicy]/[AuroraUpNavPolicy] in
/// aurora_focus.dart): a `Focus.onKeyEvent` on a non-focusable wrapper proved
/// unreliable — it didn't fire before directional traversal — so it was
/// replaced by policy-level routing, which the framework always runs for
/// arrow keys.
class AuroraNavScrollView extends StatefulWidget {
  const AuroraNavScrollView({super.key, required this.builder});
  final Widget Function(ScrollController controller) builder;

  @override
  State<AuroraNavScrollView> createState() => _AuroraNavScrollViewState();
}

class _AuroraNavScrollViewState extends State<AuroraNavScrollView> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_controller);
}
