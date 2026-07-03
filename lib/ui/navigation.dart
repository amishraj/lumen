import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
import '../state/providers.dart';
import 'screens/detail/content_detail_screen.dart';
import 'screens/player/player_screen.dart';
import 'screens/series/series_detail_screen.dart';

/// Central place that decides what tapping an item does:
/// - series → episode browser (resolved on demand)
/// - movie  → detail page (ratings/plot, then Play)
/// - live   → play immediately (no detail screen for channels)
///
/// When the pushed route pops we refresh only the *watch-activity* providers
/// (continue watching / recently watched / seen-marks). Everything else on the
/// home screen is session-cached and must NOT refetch here — that's what made
/// Trakt content reload on every scroll before.
void openItem(BuildContext context, WidgetRef ref, StreamItem item) {
  Future<void> route;
  switch (item.kind) {
    case StreamKind.series:
      final pl = ref.read(activePlaylistProvider);
      if (pl == null) return;
      route = Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SeriesDetailScreen(playlist: pl, series: item),
      ));
    case StreamKind.movie:
      route = Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ContentDetailScreen(item: item),
      ));
    case StreamKind.live:
      route = Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlayerScreen(item: item),
      ));
  }
  // Live channels have no watch progress / continue-watching, so refreshing
  // those providers on return is pure waste — and each refetch does dozens of
  // title lookups + Trakt calls, which made "back from a channel" hang. Only
  // VOD updates watch activity.
  if (item.kind == StreamKind.live) return;
  route.then((_) {
    try {
      ref.invalidate(continueWatchingProvider);
      ref.invalidate(recentlyWatchedProvider);
      ref.invalidate(watchedIdsProvider);
      ref.invalidate(progressFractionsProvider);
    } catch (_) {/* ref disposed with the screen — nothing to refresh */}
  });
}
