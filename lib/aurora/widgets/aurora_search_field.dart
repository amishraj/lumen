import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../aurora_focus.dart';
import '../aurora_theme.dart';

/// TV-safe text input: rests as a navigable tile so the D-pad never gets
/// trapped, becomes a real TextField on OK/click. Same interaction contract
/// as classic's TvTextField, restyled for Aurora.
class AuroraSearchField extends StatefulWidget {
  const AuroraSearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.icon = Icons.search_rounded,
    this.onChanged,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final ValueChanged<String>? onChanged;
  final bool autofocus;

  @override
  State<AuroraSearchField> createState() => _AuroraSearchFieldState();
}

class _AuroraSearchFieldState extends State<AuroraSearchField> {
  final FocusNode _tile = FocusNode(debugLabel: 'aurora-field-tile');
  final FocusNode _edit = FocusNode(debugLabel: 'aurora-field-edit');
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _edit.addListener(_onEditFocus);
  }

  void _onEditFocus() {
    if (!_edit.hasFocus && _editing) {
      setState(() => _editing = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && FocusManager.instance.primaryFocus == null) {
          _tile.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _edit.removeListener(_onEditFocus);
    _tile.dispose();
    _edit.dispose();
    super.dispose();
  }

  void _start() {
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _edit.requestFocus());
  }

  void _finish() {
    setState(() => _editing = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tile.requestFocus();
    });
  }

  void _clear() {
    widget.controller.clear();
    widget.onChanged?.call('');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_editing) {
      return SizedBox(
        height: 52,
        child: TextField(
          controller: widget.controller,
          focusNode: _edit,
          autocorrect: false,
          enableSuggestions: false,
          scrollPadding: const EdgeInsets.only(bottom: 140),
          style: const TextStyle(fontSize: 15),
          textInputAction: TextInputAction.done,
          onChanged: widget.onChanged,
          onSubmitted: (_) => _finish(),
          decoration: InputDecoration(
            hintText: widget.hint,
            prefixIcon: Icon(widget.icon, size: 20),
            suffixIcon: IconButton(
              icon: const Icon(Icons.check_rounded, size: 20),
              onPressed: _finish,
            ),
          ),
        ),
      );
    }

    final value = widget.controller.text;
    final empty = value.isEmpty;
    return AuroraFocusable(
      focusNode: _tile,
      autofocus: widget.autofocus,
      radius: 14,
      scale: 1.01,
      onActivate: _start,
      builder: (context, focused) => Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: focused ? Aurora.glassHi : Aurora.glass,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Aurora.hairline),
        ),
        child: Row(children: [
          Icon(widget.icon, size: 20, color: Aurora.textDim),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              empty ? widget.hint : value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: empty ? Aurora.textFaint : Aurora.text,
                  fontSize: 15),
            ),
          ),
          if (!empty)
            GestureDetector(
              onTap: _clear,
              behavior: HitTestBehavior.opaque,
              child: const Icon(Icons.close_rounded,
                  size: 18, color: Aurora.textDim),
            ),
        ]),
      ),
    );
  }
}

/// One-press native voice search, streaming live partials into [onText].
class AuroraVoiceButton extends StatefulWidget {
  const AuroraVoiceButton({super.key, required this.onText});
  final ValueChanged<String> onText;

  @override
  State<AuroraVoiceButton> createState() => _AuroraVoiceButtonState();
}

class _AuroraVoiceButtonState extends State<AuroraVoiceButton> {
  final SpeechToText _stt = SpeechToText();
  bool _listening = false;

  @override
  void dispose() {
    if (_listening) _stt.cancel();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_listening) {
      await _stt.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    final available = await _stt.initialize(
      onStatus: (s) {
        if ((s == 'done' || s == 'notListening') && mounted) {
          setState(() => _listening = false);
        }
      },
      onError: (_) {
        if (mounted) setState(() => _listening = false);
      },
    );
    if (!available) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Voice search unavailable on this device.')));
      }
      return;
    }
    setState(() => _listening = true);
    await _stt.listen(
      onResult: (r) => widget.onText(r.recognizedWords),
      listenOptions: SpeechListenOptions(
        listenFor: const Duration(seconds: 20),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        cancelOnError: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AuroraFocusable(
      radius: 26,
      onActivate: _toggle,
      builder: (context, focused) => AnimatedContainer(
        duration: Aurora.fast,
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: _listening
              ? Aurora.accent.withValues(alpha: 0.22)
              : (focused ? Aurora.glassHi : Aurora.glass),
          shape: BoxShape.circle,
          border: Border.all(
              color: _listening ? Aurora.accent : Aurora.hairline),
        ),
        child: Icon(
          _listening ? Icons.mic_rounded : Icons.mic_none_rounded,
          size: 22,
          color: _listening ? Aurora.accent : Aurora.textDim,
        ),
      ),
    );
  }
}
