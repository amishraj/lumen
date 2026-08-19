import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart' hide Playlist;

import 'aurora/aurora_theme.dart';
import 'aurora/shell.dart';
import 'data/models/models.dart';
import 'shared/input_mode.dart';
import 'shared/screens/onboarding_flow.dart';
import 'state/credential_vault.dart';
import 'state/providers.dart';

/// Startup instrumentation: ms from main() to the first home-shell frame,
/// surfaced in Settings → Account (diagnostics). "Production grade" needs a
/// number you can watch across releases, not a feeling.
final Stopwatch bootStopwatch = Stopwatch();
int? bootFirstFrameMs;

void main() {
  bootStopwatch.start();
  WidgetsFlutterBinding.ensureInitialized();
  // The in-memory decoded-image budget. Flutter's default is 100 MiB / 1000
  // images — on a 1 GB Fire TV with a ~200 MB heap that single ceiling is
  // half the budget (home holds ~50 live images + up to three ~4 MB hero
  // backdrops). Android (incl. every TV box) gets a tighter cap; desktops
  // keep the default headroom.
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      Platform.isAndroid ? 56 << 20 : 100 << 20;
  // Initialise the libmpv backend used by the player.
  MediaKit.ensureInitialized();
  // Track keyboard/remote vs pointer so focus highlights only show for the former.
  InputMode.install();
  // Keep the reinstall vault fresh whenever an account/API setting changes,
  // wherever it changed from.
  CredentialVault.instance.installAutoSave();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const ProviderScope(child: LumenApp()));
}

/// Root navigator key so app-wide shortcuts (Backspace = Back) can pop the
/// current route from above the [Navigator].
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

class LumenApp extends StatelessWidget {
  const LumenApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Backspace / browser-back act as system Back everywhere. Bound *above*
    // MaterialApp so a focused text field (which consumes Backspace for
    // deletion, via the inner DefaultTextEditingShortcuts) always wins first —
    // it only fires when nothing is being edited.
    void back() => rootNavigatorKey.currentState?.maybePop();

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.backspace): back,
        const SingleActivator(LogicalKeyboardKey.browserBack): back,
      },
      child: MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'Lumen',
      debugShowCheckedModeBanner: false,
      theme: Aurora.theme(),
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
      ),
    );
  }
}

/// Boot router: onboarding when no source exists, then the Aurora shell.
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
            error: (_, __) => const OnboardingFlow(),
            data: (restored) {
              if (restored) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  ref.invalidate(playlistsProvider);
                });
                return const _Splash();
              }
              return const OnboardingFlow();
            },
          );
        }

        // Default the active source so every shell (and the gate) has one —
        // restoring the last-used source when it still exists. Crucially the
        // splash STAYS UP until it's set: building the shell with a null
        // active playlist rendered one frame of empty rows (every provider
        // resolves to [] and the hero collapses), then re-ran ALL of them when
        // the playlist landed — a visible flash plus double the startup work.
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
          return const _Splash();
        }

        return const AuroraShell();
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
