import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
import '../data/sources/omdb_service.dart';
import '../data/sources/realdebrid_service.dart';
import '../data/sources/tmdb_service.dart';
import '../data/sources/trakt_service.dart';
import 'providers.dart';

/// Health of one external metadata/account service, for the top-bar status
/// chip and the Sources screen.
enum HealthLevel { ok, off, error }

class ServiceHealth {
  final String name;
  final HealthLevel level;
  final String detail;
  const ServiceHealth(this.name, this.level, this.detail);
}

ServiceHealth _map(String name, ({bool configured, bool ok, String detail}) r) {
  final level = !r.configured
      ? HealthLevel.off
      : (r.ok ? HealthLevel.ok : HealthLevel.error);
  return ServiceHealth(name, level, r.detail);
}

/// Runs a live probe of Trakt / TMDB / OMDb in parallel. Re-run by invalidating
/// this provider (the top-bar chip's "Retry" and the Sources screen do so).
final serviceHealthProvider =
    FutureProvider.autoDispose<List<ServiceHealth>>((ref) async {
  final trakt = await ref.watch(traktServiceProvider.future);
  final tmdb = await ref.watch(tmdbServiceProvider.future);
  final omdb = await ref.watch(omdbServiceProvider.future);
  final rd = await ref.watch(realDebridServiceProvider.future);
  final results = await Future.wait([
    trakt.ping(),
    tmdb.ping(),
    omdb.ping(),
    rd.ping(),
  ]);
  return [
    _map('Trakt', results[0]),
    _map('TMDB', results[1]),
    _map('OMDb (ratings)', results[2]),
    _map('Real-Debrid', results[3]),
  ];
});

/// Whether anything the home screen relies on is in an *error* state (i.e.
/// configured but not working) — drives the amber/red dot on the chip. A
/// service that's simply off (no key) is not an error.
final anyServiceErrorProvider = Provider.autoDispose<bool>((ref) {
  final health = ref.watch(serviceHealthProvider).valueOrNull;
  if (health == null) return false;
  return health.any((h) => h.level == HealthLevel.error);
});

// ---------------------------------------------------------------------------
// Background playlist re-sync (kicked off on app load).
// ---------------------------------------------------------------------------

class SyncState {
  final bool running;
  final String? stage; // e.g. "Parsing channels…"
  final int? playlistId;
  const SyncState({this.running = false, this.stage, this.playlistId});
}

class SyncController extends StateNotifier<SyncState> {
  SyncController(this.ref) : super(const SyncState());
  final Ref ref;

  /// Re-sync a playlist in the background, streaming coarse progress into
  /// [state] so the top bar can show a live indicator. Invalidates the home
  /// providers on completion so freshly-synced content appears.
  ///
  /// [minInterval] skips the sync if the source was refreshed recently —
  /// playlists rarely change, and re-downloading + re-parsing 40k channels on
  /// every launch made browsing feel slow. Defaults to **once a day**: an
  /// index at most every 24h, so repeated opens are instant off the persisted
  /// SQLite library. Manual re-sync (Settings) forces it with Duration.zero.
  Future<void> resync(Playlist pl,
      {Duration minInterval = const Duration(hours: 24)}) async {
    if (state.running || pl.id == null) return;
    final repo = await ref.read(repositoryProvider.future);
    // Read the AUTHORITATIVE last-sync time from the DB — the passed-in
    // Playlist is a snapshot taken at app launch and its lastSyncedAt can be
    // stale, which made the 12h guard misfire and re-index on every launch.
    if (minInterval > Duration.zero) {
      final matches =
          (await repo.playlists()).where((p) => p.id == pl.id).toList();
      final last = matches.isEmpty ? null : matches.first.lastSyncedAt;
      if (last != null &&
          DateTime.now().millisecondsSinceEpoch - last <
              minInterval.inMilliseconds) {
        return; // synced recently — keep the existing index
      }
    }
    state = SyncState(running: true, stage: 'Refreshing…', playlistId: pl.id);
    try {
      await for (final p in repo.sync(pl)) {
        state = SyncState(running: true, stage: p.stage, playlistId: pl.id);
      }
      // Refresh everything that reads the library.
      ref.invalidate(playlistsProvider);
      ref.invalidate(featuredProvider);
      ref.invalidate(continueWatchingProvider);
      ref.invalidate(recentlyWatchedProvider);
      ref.invalidate(kindSampleProvider);
      ref.invalidate(categoriesProvider);
    } catch (_) {/* leave old content in place on failure */} finally {
      state = const SyncState();
    }
  }
}

final syncControllerProvider = StateNotifierProvider<SyncController, SyncState>(
    (ref) => SyncController(ref));
