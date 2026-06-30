import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'ui/screens/home/home_screen.dart';
import 'ui/theme/lumen_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialise the libmpv backend used by the player.
  MediaKit.ensureInitialized();
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
      builder: (context, child) => Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowUp):
              DirectionalFocusIntent(TraversalDirection.up),
          SingleActivator(LogicalKeyboardKey.arrowDown):
              DirectionalFocusIntent(TraversalDirection.down),
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
        },
        child: child!,
      ),
      home: const HomeScreen(),
    );
  }
}
