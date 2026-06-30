import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Tracks whether the user is currently driving the UI by keyboard/remote
/// (show focus highlights) or by mouse/trackpad/touch (hide them).
///
/// Flutter lumps mouse in with keyboard as "traditional" highlight mode, which
/// makes the remote-style glow appear during mouse use. We distinguish the two
/// by watching real input events: a navigation key flips us to keyboard mode,
/// any pointer movement flips us back.
class InputMode {
  InputMode._();

  static final ValueNotifier<bool> keyboard = ValueNotifier<bool>(false);

  static final Set<LogicalKeyboardKey> _navKeys = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.gameButtonA,
  };

  static bool _installed = false;

  /// Registers the global key handler. Call once at startup.
  static void install() {
    if (_installed) return;
    _installed = true;
    HardwareKeyboard.instance.addHandler((event) {
      if (event is KeyDownEvent && _navKeys.contains(event.logicalKey)) {
        keyboard.value = true;
      }
      return false; // never consume — just observe
    });
  }

  /// Call on any pointer (mouse/trackpad/touch) activity.
  static void pointerActive() {
    keyboard.value = false; // ValueNotifier no-ops when unchanged
  }
}
