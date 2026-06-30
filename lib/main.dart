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
      home: const HomeScreen(),
    );
  }
}
