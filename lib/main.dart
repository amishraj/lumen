import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart' hide Playlist;

import 'aurora/aurora_theme.dart';
import 'aurora/gate/experience_gate.dart';
import 'aurora/shell.dart';
import 'data/models/models.dart';
import 'state/credential_vault.dart';
import 'state/experience.dart';
import 'state/providers.dart';
import 'ui/input_mode.dart';
import 'ui/screens/home/home_screen.dart';
import 'ui/screens/onboarding/add_source_screen.dart';
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

/// 1.1 ships two complete experiences in one binary:
/// - **Aurora** — the redesigned UI (new home, browse, detail, player)
/// - **Classic** — the 1.0 interface, untouched
///
/// A persisted setting decides which shell boots; a one-time gate asks on
/// first run and both settings screens can switch (no reinstall — which also
/// sidesteps Android's no-downgrade rule for going back).
class LumenApp extends ConsumerWidget {
  const LumenApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final experience = ref.watch(uiExperienceProvider).valueOrNull;
    final classic = experience == kExperienceClassic;

    return MaterialApp(
      title: 'Lumen',
      debugShowCheckedModeBanner: false,
      theme: classic ? LumenTheme.dark() : Aurora.theme(),
      // TV/remote: make Up/Down always move focus spatially, even inside text
      // fields (which would otherwise eat the arrows for cursor movement).
      builder: (context, child) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerHover: (_) => InputMode.pointerActive(),
        onPointerDown: (_) => InputMode.pointerActive(),
        onPointerSignal: (_) => InputMode.pointerActive(),
        child: Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
                TraversalDirection.up,
                ignoreTextFields: false),
            SingleActivator(LogicalKeyboardKey.arrowDown):
                DirectionalFocusIntent(TraversalDirection.down,
                    ignoreTextFields: false),
            SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
          },
          child: child!,
        ),
      ),
      home: const LumenRoot(),
    );
  }
}

/// Boot router: onboarding when no source exists, then the experience gate
/// (once), then whichever shell the user chose.
class LumenRoot extends ConsumerWidget {
  const LumenRoot({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);

    // Remember which source was active across launches, so multi-source users
    // aren't reset to the first one every time.
    ref.listen<Playlist?>(activePlaylistProvider, (_, next) async {
      if (next?.id == null) return;
      final repo = await ref.read(repositoryProvider.future);
      await repo.setSetting('active_playlist_id', '${next!.id}');
    });

    return playlists.when(
      loading: () => const _Splash(),
      error: (e, _) => Scaffold(body: Center(child: Text('$e'))),
      data: (list) {
        if (list.isEmpty) {
          // Fresh install: an OS-restored vault may hold the user's sources +
          // accounts — restore before showing onboarding.
          final restore = ref.watch(vaultRestoreProvider);
          return restore.when(
            loading: () => const _Splash(),
            error: (_, __) => const AddSourceScreen(),
            data: (restored) {
              if (restored) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  ref.invalidate(playlistsProvider);
                  ref.invalidate(uiExperienceProvider);
                });
                return const _Splash();
              }
              return const AddSourceScreen();
            },
          );
        }

        // Default the active source so every shell (and the gate) has one —
        // restoring the last-used source when it still exists.
        final active = ref.watch(activePlaylistProvider);
        if (active == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            final repo = await ref.read(repositoryProvider.future);
            final savedId =
                int.tryParse(await repo.getSetting('active_playlist_id') ?? '');
            final chosen = list.firstWhere((p) => p.id == savedId,
                orElse: () => list.first);
            ref.read(activePlaylistProvider.notifier).state = chosen;
          });
        }

        final experience = ref.watch(uiExperienceProvider);
        return experience.when(
          loading: () => const _Splash(),
          // If the setting can't load, fail safe into the classic shell.
          error: (_, __) => const HomeScreen(),
          data: (exp) => switch (exp) {
            kExperienceAurora => const AuroraShell(),
            kExperienceClassic => const HomeScreen(),
            _ => const ExperienceGateScreen(),
          },
        );
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF06070B),
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ShaderMask(
            shaderCallback: (r) => Aurora.gradient.createShader(r),
            child: const Text('lumen',
                style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.2,
                    color: Colors.white)),
          ),
          const SizedBox(height: 26),
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Color(0xFF4CC2FF)),
          ),
        ]),
      ),
    );
  }
}
