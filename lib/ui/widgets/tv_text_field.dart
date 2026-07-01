import 'package:flutter/material.dart';

import '../theme/lumen_theme.dart';
import 'focusable_item.dart';

/// A TV/remote-friendly text field. In its resting state it's a *navigable
/// tile* (a button) — so the D-pad moves between fields normally and a text
/// field never traps the arrow keys. Selecting/clicking it switches to an
/// editable [TextField] (opening the keyboard); finishing returns to the tile
/// so navigation resumes. This is the reliable pattern for 10-foot UIs.
///
/// Supports live [onChanged] (so it can back search-as-you-type fields) and an
/// optional clear affordance via [onCleared]. [dense] gives a compact height
/// for tight spots like the app-bar search.
class TvTextField extends StatefulWidget {
  const TvTextField({
    super.key,
    required this.controller,
    required this.hint,
    this.icon,
    this.obscure = false,
    this.keyboard,
    this.autofocus = false,
    this.onChanged,
    this.onCleared,
    this.dense = false,
  });

  final TextEditingController controller;
  final String hint;
  final IconData? icon;
  final bool obscure;
  final TextInputType? keyboard;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onCleared;
  final bool dense;

  @override
  State<TvTextField> createState() => _TvTextFieldState();
}

class _TvTextFieldState extends State<TvTextField> {
  final FocusNode _tileFocus = FocusNode(debugLabel: 'tvfield-tile');
  final FocusNode _fieldFocus = FocusNode(debugLabel: 'tvfield-edit');
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _fieldFocus.addListener(_onFieldFocusChange);
  }

  void _onFieldFocusChange() {
    // Left the field (back button, moved focus, tapped away) → leave edit mode.
    if (!_fieldFocus.hasFocus && _editing) {
      setState(() => _editing = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Only reclaim focus if nothing else took it (e.g. closed the keyboard
        // without moving), so we never fight another field for focus.
        if (mounted && FocusManager.instance.primaryFocus == null) {
          _tileFocus.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _fieldFocus.removeListener(_onFieldFocusChange);
    _tileFocus.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  void _startEditing() {
    setState(() => _editing = true);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _fieldFocus.requestFocus());
  }

  void _finishEditing() {
    setState(() => _editing = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tileFocus.requestFocus();
    });
  }

  void _clear() {
    widget.controller.clear();
    widget.onChanged?.call('');
    widget.onCleared?.call();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final height = widget.dense ? 44.0 : 56.0;
    if (_editing) {
      return SizedBox(
        height: height,
        child: TextField(
          controller: widget.controller,
          focusNode: _fieldFocus,
          obscureText: widget.obscure,
          keyboardType: widget.keyboard,
          autocorrect: false,
          enableSuggestions: false,
          style: TextStyle(fontSize: widget.dense ? 14 : 15),
          textInputAction: TextInputAction.done,
          onChanged: widget.onChanged,
          onSubmitted: (_) => _finishEditing(),
          decoration: InputDecoration(
            isDense: widget.dense,
            hintText: widget.hint,
            prefixIcon:
                widget.icon == null ? null : Icon(widget.icon, size: 20),
            suffixIcon: IconButton(
              icon: const Icon(Icons.check, size: 20),
              onPressed: _finishEditing,
            ),
          ),
        ),
      );
    }

    final value = widget.controller.text;
    final empty = value.isEmpty;
    final display = empty
        ? widget.hint
        : (widget.obscure ? '•' * value.length.clamp(1, 16) : value);
    final showClear = !empty && widget.onCleared != null;

    return FocusableItem(
      focusNode: _tileFocus,
      autofocus: widget.autofocus,
      borderRadius: 14,
      onActivate: _startEditing,
      builder: (context, focused) => Container(
        height: height,
        padding: EdgeInsets.symmetric(horizontal: widget.dense ? 12 : 14),
        decoration: BoxDecoration(
          color: LumenTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF2A2E3A)),
        ),
        child: Row(
          children: [
            Icon(widget.icon ?? Icons.search,
                size: widget.dense ? 18 : 20, color: const Color(0xFF9AA0B0)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: empty ? const Color(0xFF6B7080) : Colors.white,
                  fontSize: widget.dense ? 14 : 15,
                ),
              ),
            ),
            if (showClear)
              GestureDetector(
                onTap: _clear,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Icon(Icons.close, size: 17, color: Color(0xFF9AA0B0)),
                ),
              )
            else
              Icon(Icons.edit,
                  size: widget.dense ? 14 : 16, color: const Color(0xFF6B7080)),
          ],
        ),
      ),
    );
  }
}
