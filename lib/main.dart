import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'ui/input_mode.dart';
import 'ui/screens/home/home_screen.dart';
import 'ui/theme/lumen_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialise the libmpv backend used by the player.
  MediaKit.ensureInitialized();
  // Track keyboard/remote vs pointer so focus highlights only show for the former.
  InputMode.install();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const ProviderScope(child: LumenApp()));
}

class LumenApp extends StatelessWidget {
  const LumenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lumen',
      debugShowCheckedModeBanner: false,
      theme: LumenTheme.dark(),
      // TV/remote: make Up/Down always move focus spatially, even inside text
      // fields (which would otherwise eat the arrows for cursor movement). This
      // Shortcuts sits below DefaultTextEditingShortcuts so it wins. Left/Right
      // are left alone so desktop keyboard users can still move the cursor.
      builder: (context, child) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerHover: (_) => InputMode.pointerActive(),
        onPointerDown: (_) => InputMode.pointerActive(),
        onPointerSignal: (_) => InputMode.pointerActive(),
        child: Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            // ignoreTextFields:false is the crucial bit — without it the text
            // field's own focus action swallows the arrow and focus never moves,
            // so you can't get from one field to the next on a remote. We do this
            // for Up/Down (vertical field-to-field nav) but leave Left/Right alone
            // so desktop keyboard users keep in-field cursor movement.
            SingleActivator(LogicalKeyboardKey.arrowUp):
                DirectionalFocusIntent(TraversalDirection.up, ignoreTextFields: false),
            SingleActivator(LogicalKeyboardKey.arrowDown):
                DirectionalFocusIntent(TraversalDirection.down, ignoreTextFields: false),
            SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
          },
          child: child!,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
