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
void openItem(BuildContext context, WidgetRef ref, StreamItem item) {
  switch (item.kind) {
    case StreamKind.series:
      final pl = ref.read(activePlaylistProvider);
      if (pl == null) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SeriesDetailScreen(playlist: pl, series: item),
      ));
    case StreamKind.movie:
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ContentDetailScreen(item: item),
      ));
    case StreamKind.live:
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlayerScreen(item: item),
      ));
  }
}
