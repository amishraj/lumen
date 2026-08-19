import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
import '../data/sources/trakt_service.dart';
import '../state/providers.dart';
import '../shared/title_utils.dart';
import 'player/aurora_player.dart';
import 'screens/aurora_detail.dart';
import 'screens/aurora_series.dart';

/// Aurora's item router:
/// - series → season/episode screen
/// - movie  → cinematic detail page
/// - live   → straight into the player (optionally with a zap [queue])
///
/// Returning from VOD refreshes only watch-activity providers — the 1.0
/// lesson that keeps "back from playback" instant.
///
/// Every VOD title is also reconciled with Trakt on the way IN and on the way
/// OUT (see [syncTitleWithTrakt]) — the app-open pull alone is too coarse on a
/// slow TV box, where it can be minutes stale by the time you've navigated to
/// something.
void openAuroraItem(
  BuildContext context,
  WidgetRef ref,
  StreamItem item, {
  List<StreamItem>? liveQueue,
}) {
  Future<void> route;
  switch (item.kind) {
    case StreamKind.series:
      final pl = ref.read(activePlaylistProvider);
      if (pl == null) return;
      route = Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AuroraSeriesScreen(playlist: pl, series: item),
      ));
    case StreamKind.movie:
      route = Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AuroraDetailScreen(item: item),
      ));
    case StreamKind.live:
      final queue = liveQueue ?? [item];
      final index = liveQueue == null
          ? 0
          : liveQueue.indexWhere((e) => e.id == item.id && e.url == item.url);
      route = Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AuroraPlayerScreen(
          item: item,
          queue: queue,
          startIndex: index < 0 ? 0 : index,
        ),
      ));
  }
  if (item.kind == StreamKind.live) return;

  final isShow = item.kind == StreamKind.series;
  final title = cleanTitle(item.name).title;
  // Opening: pull this title's state down (resume point, watched episodes) so
  // the page you're reading is right, not up-to-six-hours-old. Held back a
  // beat so it queues *behind* the page's own metadata + debrid prefetch —
  // on a cheap TV box those are what the user is waiting on.
  Future.delayed(const Duration(milliseconds: 700),
      () => unawaited(syncTitleWithTrakt(ref, title, isShow: isShow)));
  route.then((_) {
    try {
      ref.invalidate(continueWatchingProvider);
      ref.invalidate(recentlyWatchedProvider);
      ref.invalidate(watchedIdsProvider);
      ref.invalidate(progressFractionsProvider);
    } catch (_) {/* screen disposed — nothing to refresh */}
    // Leaving: push anything watched here up first, then re-read — so
    // Continue Watching reflects this session immediately rather than at the
    // next app open. `force` skips the cooldown: the state genuinely changed.
    unawaited(
        syncTitleWithTrakt(ref, title, isShow: isShow, push: true, force: true));
  });
}

/// Reconcile one title with Trakt and refresh whatever renders it.
///
/// Deliberately fire-and-forget and fully guarded: it must never delay a page
/// transition, and it must survive the screen being disposed mid-flight.
Future<void> syncTitleWithTrakt(
  WidgetRef ref,
  String title, {
  required bool isShow,
  bool push = false,
  bool force = false,
}) async {
  try {
    if (!await ref.read(traktConnectedProvider.future)) return;
    final svc = await ref.read(traktServiceProvider.future);
    final changed =
        await svc.syncTitle(title, isShow: isShow, push: push, force: force);
    if (!changed) return;
    // Seed any freshly-pulled show progress into the local table so Continue
    // Watching picks it up through its normal path.
    if (isShow) await svc.hydrateEpisodeProgress();
    ref.invalidate(continueWatchingProvider);
    ref.invalidate(progressFractionsProvider);
    if (isShow) ref.invalidate(traktWatchedEpisodesProvider(title));
  } catch (_) {/* offline, not connected, or the screen went away */}
}
