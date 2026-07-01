import 'package:flutter/material.dart';

import '../theme/lumen_theme.dart';
import 'focusable_item.dart';

/// A TV/remote-friendly text field. In its resting state it's a *navigable
/// tile* (a button) — so the D-pad moves between fields normally and a text
/// field never traps the arrow keys. Selecting/clicking it switches to an
/// editable [TextField] (opening the keyboard); finishing returns to the tile
/// so navigation resumes. This is the reliable pattern for 10-foot UIs.
class TvTextField extends StatefulWidget {
  const TvTextField({
    super.key,
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.keyboard,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;
  final TextInputType? keyboard;
  final bool autofocus;

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _fieldFocus.requestFocus());
  }

  void _finishEditing() {
    setState(() => _editing = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tileFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_editing) {
      return TextField(
        controller: widget.controller,
        focusNode: _fieldFocus,
        obscureText: widget.obscure,
        keyboardType: widget.keyboard,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _finishEditing(),
        decoration: InputDecoration(
          hintText: widget.hint,
          prefixIcon: Icon(widget.icon, size: 20),
          suffixIcon: IconButton(
            icon: const Icon(Icons.check, size: 20),
            onPressed: _finishEditing,
          ),
        ),
      );
    }

    final value = widget.controller.text;
    final empty = value.isEmpty;
    final display = empty
        ? widget.hint
        : (widget.obscure ? '•' * value.length.clamp(1, 16) : value);

    return FocusableItem(
      focusNode: _tileFocus,
      autofocus: widget.autofocus,
      borderRadius: 14,
      onActivate: _startEditing,
      builder: (context, focused) => Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: LumenTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF2A2E3A)),
        ),
        child: Row(
          children: [
            Icon(widget.icon, size: 20, color: const Color(0xFF9AA0B0)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: empty ? const Color(0xFF6B7080) : Colors.white,
                  fontSize: 15,
                ),
              ),
            ),
            const Icon(Icons.edit, size: 16, color: Color(0xFF6B7080)),
          ],
        ),
      ),
    );
  }
}
