import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
import '../data/sources/trakt_service.dart';
import '../state/providers.dart';
import '../shared/title_utils.dart';
import 'aurora_providers.dart';
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
/// Push [route] and put the shell back on the tab it was pushed from.
///
/// For the player pushes that don't go through [openAuroraItem] (Sports, Live).
/// Any route that returns straight to the shell needs this — see [_restoreTab]
/// for why the landing tab is otherwise a guess.
void pushFromTab(WidgetRef ref, Future<void> route) {
  final from = ref.read(auroraTabProvider);
  route.then((_) => _restoreTab(ref, from));
}

/// Put the shell back on the tab a title was opened from.
///
/// Also suppresses the top bar's focus-selects-tab behaviour for a beat: the
/// focus fallout from a pop arrives over the next few frames, and without the
/// window it would immediately overwrite what we just restored.
void _restoreTab(WidgetRef ref, int tab) {
  auroraSuppressFocusTabUntil =
      DateTime.now().add(const Duration(milliseconds: 600));
  try {
    if (ref.read(auroraTabProvider) != tab) {
      ref.read(auroraTabProvider.notifier).state = tab;
    }
  } catch (_) {/* shell disposed — nothing to restore into */}
}

void openAuroraItem(
  BuildContext context,
  WidgetRef ref,
  StreamItem item, {
  List<StreamItem>? liveQueue,
}) {
  // Where this title was opened FROM. Nothing else in the app remembers it:
  // the landing tab after a pop was whatever `auroraTabProvider` happened to
  // hold, and that is ambient state two unrelated things overwrite. The shell's
  // Back handler force-writes Home whenever a Back reaches the shell route, and
  // the top bar turns *any* nav node gaining focus into a tab switch — so when
  // Flutter restores focus after a pop and falls through to a tab node (the
  // page's own focus scope having been excluded or unmounted underneath the
  // route), the accident is committed as navigation. Home is the node seeded at
  // boot; Search is the reading-order-first one. Those are exactly the two
  // wrong destinations reported.
  //
  // Rather than chase every way focus can drift, record the answer on the way
  // in and assert it on the way out.
  final openedFromTab = ref.read(auroraTabProvider);
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
  if (item.kind == StreamKind.live) {
    route.then((_) => _restoreTab(ref, openedFromTab));
    return;
  }

  final isShow = item.kind == StreamKind.series;
  final title = cleanTitle(item.name).title;
  // Opening: pull this title's state down (resume point, watched episodes) so
  // the page you're reading is right, not up-to-six-hours-old. Held back a
  // beat so it queues *behind* the page's own metadata + debrid prefetch —
  // on a cheap TV box those are what the user is waiting on.
  Future.delayed(const Duration(milliseconds: 700),
      () => unawaited(syncTitleWithTrakt(ref, title, isShow: isShow)));
  route.then((_) {
    _restoreTab(ref, openedFromTab);
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
