import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../aurora/aurora_theme.dart';
import '../../aurora/screens/aurora_account.dart';
import '../../state/providers.dart';
import '../../state/sync_providers.dart';
import 'add_source_screen.dart';

/// Fresh-install onboarding: sign in (everything restores from the account)
/// or set up manually. Signing in pulls `src` docs → playlists fill → the
/// boot router leaves this screen on its own (same handoff shape the vault
/// restore uses).
class OnboardingFlow extends ConsumerWidget {
  const OnboardingFlow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The account sync may have just delivered sources — when playlists land,
    // LumenRoot swaps this screen out; nothing to do here but offer paths.
    ref.listen(lumenSignedInProvider, (_, next) {
      if (next.valueOrNull == true) ref.invalidate(playlistsProvider);
    });
    return Scaffold(
      backgroundColor: const Color(0xFF06070B),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ShaderMask(
                    shaderCallback: (r) => Aurora.gradient.createShader(r),
                    child: const Text('lumen',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 44,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1.2,
                            color: Colors.white)),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Welcome. Sign in and everything follows you —\n'
                    'sources, keys, progress, favorites.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF8B93A7), height: 1.5),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    height: 54,
                    child: FilledButton.icon(
                      autofocus: true,
                      icon: const Icon(Icons.person_rounded),
                      label: const Text('Sign in to your Lumen account'),
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const AuroraAccountScreen())),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 54,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.playlist_add_rounded),
                      label: const Text('Set up manually'),
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const AddSourceScreen())),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
