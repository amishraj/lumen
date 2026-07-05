import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Shared, generously-sized on-disk cache for all artwork (posters, backdrops,
/// channel logos).
///
/// The default `CachedNetworkImage` manager caps at **200** objects with a 30-day
/// stale window — far too small for a library of thousands of covers: the LRU
/// evicts art almost immediately, so every launch re-downloads everything and
/// the UI "loads for ages". This raises the cap dramatically and lengthens
/// retention, so once a cover is fetched it stays on disk across sessions and
/// the app opens instantly.
class LumenImageCache {
  LumenImageCache._();

  static const _key = 'lumenArtCache';

  static final CacheManager instance = CacheManager(
    Config(
      _key,
      stalePeriod: const Duration(days: 60),
      maxNrOfCacheObjects: 3000,
    ),
  );
}
