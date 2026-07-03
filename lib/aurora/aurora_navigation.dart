import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
import '../state/providers.dart';
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
  route.then((_) {
    try {
      ref.invalidate(continueWatchingProvider);
      ref.invalidate(recentlyWatchedProvider);
      ref.invalidate(watchedIdsProvider);
      ref.invalidate(progressFractionsProvider);
    } catch (_) {/* screen disposed — nothing to refresh */}
  });
}
