import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../aurora_providers.dart';

/// Wraps a scrollable page so that pressing **Up while already at the top**
/// snaps fully to offset 0 and returns focus to the top nav (the active tab).
///
/// It never interferes with normal upward navigation: when the page is scrolled
/// down, Up falls through to ordinary directional focus (moving to the row
/// above, which scrolls it into view). Only once the user is at the very top
/// does Up escape to the nav — so pressing Up repeatedly always ends cleanly at
/// the top of every page, with nothing tucked under the nav bar.
class AuroraUpToNav extends StatelessWidget {
  const AuroraUpToNav({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    if (!controller.hasClients || controller.offset > 12) {
      return KeyEventResult.ignored; // still scrolling up through the page
    }
    if (controller.offset > 0) {
      controller.animateTo(0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic);
    }
    auroraNavTarget?.requestFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: child,
    );
  }
}

/// Convenience wrapper that owns a [ScrollController] and applies
/// [AuroraUpToNav] — so a stateless page can get the "Up-at-top → nav + snap to
/// 0" behaviour without becoming stateful. Hand the controller to your
/// scrollable inside [builder].
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
  Widget build(BuildContext context) {
    return AuroraUpToNav(
      controller: _controller,
      child: widget.builder(_controller),
    );
  }
}
