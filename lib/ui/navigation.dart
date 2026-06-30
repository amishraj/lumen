import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
import '../state/providers.dart';
import 'screens/player/player_screen.dart';
import 'screens/series/series_detail_screen.dart';

/// Central place that decides what tapping an item does: series open a detail
/// screen (episodes are resolved on demand), everything else plays directly.
void openItem(BuildContext context, WidgetRef ref, StreamItem item) {
  if (item.kind == StreamKind.series) {
    final pl = ref.read(activePlaylistProvider);
    if (pl == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SeriesDetailScreen(playlist: pl, series: item),
    ));
  } else {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(item: item),
    ));
  }
}
