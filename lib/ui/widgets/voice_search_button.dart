import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../theme/lumen_theme.dart';
import 'focusable_item.dart';

/// Mic button for the search bar: native on-device speech-to-text with live
/// partial results. Streams recognised text to [onText] as the user speaks so
/// results update in real time, and pulses while listening.
///
/// (Keyboard voice-typing already works everywhere via the OS keyboard's own
/// mic — this adds a one-tap, remote-friendly voice affordance on top.)
class VoiceSearchButton extends StatefulWidget {
  const VoiceSearchButton({super.key, required this.onText});
  final ValueChanged<String> onText;

  @override
  State<VoiceSearchButton> createState() => _VoiceSearchButtonState();
}

class _VoiceSearchButtonState extends State<VoiceSearchButton> {
  final SpeechToText _stt = SpeechToText();
  bool _available = false;
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
    _available = await _stt.initialize(
      onStatus: (s) {
        if ((s == 'done' || s == 'notListening') && mounted) {
          setState(() => _listening = false);
        }
      },
      onError: (_) {
        if (mounted) setState(() => _listening = false);
      },
    );
    if (!_available) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Voice search unavailable on this device.')));
      }
      return;
    }
    setState(() => _listening = true);
    await _stt.listen(
      onResult: (r) => widget.onText(r.recognizedWords),
      listenFor: const Duration(seconds: 20),
      pauseFor: const Duration(seconds: 3),
      listenOptions: SpeechListenOptions(
        partialResults: true, // live-update the query as the user speaks
        cancelOnError: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FocusableItem(
      borderRadius: 22,
      onActivate: _toggle,
      builder: (context, focused) => Container(
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: _listening
              ? LumenTheme.accent.withValues(alpha: 0.22)
              : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: Icon(_listening ? Icons.mic : Icons.mic_none,
            size: 20,
            color: _listening ? LumenTheme.accent : const Color(0xFF9AA0B0)),
      ),
    );
  }
}
