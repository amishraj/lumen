import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'sync_hooks.dart';

/// Which UI shell the app boots into. Persisted in app settings so the choice
/// survives restarts and re-syncs (the settings table is also vault-backed).
///
/// - null      → never chosen (first run of 1.1) → show the experience gate
/// - 'classic' → the original 1.0 UI
/// - 'aurora'  → the 1.1 redesigned experience
const kExperienceClassic = 'classic';
const kExperienceAurora = 'aurora';

final uiExperienceProvider = FutureProvider<String?>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  return repo.getSetting('ui_experience');
});

/// Persist the chosen experience and rebuild the root shell.
Future<void> setUiExperience(WidgetRef ref, String value) async {
  final repo = await ref.read(repositoryProvider.future);
  await repo.setSetting('ui_experience', value);
  ref.invalidate(uiExperienceProvider);
  onUserDataChanged?.call();
}
