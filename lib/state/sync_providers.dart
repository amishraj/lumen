import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/sync/auth_service.dart';
import '../data/sync/sync_clock.dart';
import '../data/sync/sync_service.dart';
import 'providers.dart';

final authServiceProvider = FutureProvider<AuthService>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  return AuthService(repo);
});

final syncServiceProvider = FutureProvider<SyncService>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final auth = await ref.watch(authServiceProvider.future);
  final svc = SyncService(repo, auth);
  // Restore the measured clock offset before any stamps are issued.
  final rows = await repo.db.db
      .query('sync_state', where: "key='clock_offset'", limit: 1);
  if (rows.isNotEmpty) {
    SyncClock.offsetMs = int.tryParse('${rows.first['value']}') ?? 0;
  }
  svc.installAutoPush();
  return svc;
});

/// Bumped after login/logout so account-dependent UI re-reads.
final lumenAccountRevProvider = StateProvider<int>((ref) => 0);

final lumenSignedInProvider = FutureProvider<bool>((ref) async {
  ref.watch(lumenAccountRevProvider);
  final auth = await ref.watch(authServiceProvider.future);
  return auth.signedIn;
});

final lumenEmailProvider = FutureProvider<String?>((ref) async {
  ref.watch(lumenAccountRevProvider);
  final auth = await ref.watch(authServiceProvider.future);
  return auth.email();
});

/// Run one push/pull and invalidate whatever the pull touched. The single
/// entry point the shell, lifecycle observer and player all use.
Future<void> runSync(WidgetRef ref, {bool notifyProviders = true}) async {
  try {
    final sync = await ref.read(syncServiceProvider.future);
    final changed = await sync.pushPull();
    if (!changed || !notifyProviders) return;
    ref.invalidate(continueWatchingProvider);
    ref.invalidate(watchedIdsProvider);
    ref.invalidate(progressFractionsProvider);
    ref.invalidate(favoriteIdsProvider);
    ref.invalidate(favoriteKeysProvider);
    ref.invalidate(favoritesListProvider);
    ref.invalidate(episodeProgressProvider);
    ref.invalidate(recentlyWatchedProvider);
    if (sync.sourcesChanged) ref.invalidate(playlistsProvider);
  } catch (_) {/* offline — local state is already painted */}
}
