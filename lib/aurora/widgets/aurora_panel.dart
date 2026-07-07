import 'package:flutter/material.dart';

import '../aurora_focus.dart';
import '../aurora_theme.dart';

/// A right-hand slide-in panel that floats over content (video keeps playing
/// behind it). Focus-inert while closed — the fix that stopped hidden drawers
/// from stealing remote focus in 1.0 — and Aurora-glass while open.
///
/// Stateful so it can pull remote/keyboard focus *into* itself when opened:
/// the panels are permanently in the tree (slid off-screen when closed), so
/// their children's `autofocus` never re-fires on open by itself — which left
/// the Audio/Subtitles menus impossible to enter with a remote. On open we
/// re-key the content (so its `autofocus` registers afresh) and focus the
/// panel's own [FocusScope], landing on the selected/first row.
class AuroraSidePanel extends StatefulWidget {
  const AuroraSidePanel({
    super.key,
    required this.open,
    required this.title,
    required this.onClose,
    required this.child,
    this.width,
  });

  final bool open;
  final String title;
  final VoidCallback onClose;
  final Widget child;
  final double? width;

  @override
  State<AuroraSidePanel> createState() => _AuroraSidePanelState();
}

class _AuroraSidePanelState extends State<AuroraSidePanel> {
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'aurora-side-panel');

  @override
  void didUpdateWidget(covariant AuroraSidePanel old) {
    super.didUpdateWidget(old);
    if (widget.open && !old.open) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusIntoPanel());
    }
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  /// Land focus on the panel's content once it's laid out and interactive.
  void _focusIntoPanel() {
    if (!mounted || !widget.open) return;
    // Making our scope the focused scope resolves the freshly-registered
    // `autofocus` (the selected/first row).
    _scope.requestFocus();
    // Safety net: if nothing self-selected, focus the first control so the
    // remote can still drive the panel.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.open) return;
      if (_scope.focusedChild == null) {
        final nodes = _scope.traversalDescendants.toList();
        if (nodes.isNotEmpty) nodes.first.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final open = widget.open;
    final w = widget.width ??
        (MediaQuery.of(context).size.width * 0.4).clamp(320.0, 440.0);
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !open,
        child: ExcludeFocus(
          excluding: !open,
          child: Stack(children: [
            AnimatedOpacity(
              opacity: open ? 1 : 0,
              duration: Aurora.normal,
              child: GestureDetector(
                onTap: widget.onClose,
                child: const ColoredBox(color: Color(0x8005060A)),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: AnimatedSlide(
                // Closed: slide fully off-screen *including* the left-pointing
                // drop shadow (blur 44, offset -8) + the 12px margin — a plain
                // Offset(1,0) stops one card-width out, leaving that shadow
                // bleeding back onto the right edge of the video.
                offset: open ? Offset.zero : Offset(1 + 72 / w, 0),
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                child: Container(
                  width: w,
                  margin: const EdgeInsets.all(12),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: const Color(0xF60C0E15),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: Aurora.hairline),
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x99000000),
                          blurRadius: 44,
                          offset: Offset(-8, 0)),
                    ],
                  ),
                  child: FocusScope(
                    node: _scope,
                    child: SafeArea(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(22, 18, 14, 10),
                            child: Row(children: [
                              Expanded(
                                  child: Text(widget.title,
                                      style: Aurora.title)),
                              AuroraFocusable(
                                radius: 22,
                                onActivate: widget.onClose,
                                builder: (context, focused) => Container(
                                  padding: const EdgeInsets.all(7),
                                  decoration: BoxDecoration(
                                    color: focused
                                        ? Aurora.glassHi
                                        : Aurora.glass,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.close_rounded,
                                      size: 18),
                                ),
                              ),
                            ]),
                          ),
                          // Re-key on open so the child's `autofocus` fires
                          // afresh each time the panel is shown.
                          Expanded(
                            child: KeyedSubtree(
                              key: ValueKey(open),
                              child: widget.child,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// A selectable option row for panels (audio tracks, subtitles, seasons…).
class AuroraOptionRow extends StatelessWidget {
  const AuroraOptionRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelect,
    this.sublabel,
    this.autofocus = false,
  });

  final String label;
  final String? sublabel;
  final bool selected;
  final VoidCallback onSelect;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return AuroraFocusable(
      autofocus: autofocus,
      onActivate: onSelect,
      radius: 12,
      scale: 1.0,
      builder: (context, focused) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: focused
              ? Aurora.glassHi
              : (selected ? Aurora.glass : Colors.transparent),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            selected ? FontWeight.w800 : FontWeight.w500,
                        color: selected ? Colors.white : Aurora.textDim)),
                if (sublabel != null)
                  Text(sublabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11.5, color: Aurora.textFaint)),
              ],
            ),
          ),
          if (selected)
            const Icon(Icons.check_rounded, color: Aurora.accent, size: 19),
        ]),
      ),
    );
  }
}
