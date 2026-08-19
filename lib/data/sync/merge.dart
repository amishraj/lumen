/// The single merge rule for watch state: which of two rows claiming the same
/// key wins. Used by the v5 migration (folding id-keyed `progress` into the
/// key space) and later by the sync engine's remote-apply — both must answer
/// the question identically or a migration and a pull could disagree.
///
/// Pure last-write-wins on `updatedAt`. Ties prefer real rows over
/// Trakt-synthesized ones, then the larger position. LWW is deliberately
/// commutative/associative/idempotent so any apply order converges.
class WatchRow {
  final String key;
  final int positionMs;
  final int durationMs;
  final bool watched;
  final int updatedAt;
  final bool deleted; // tombstone — "unwatched" must survive a sync round-trip
  final bool synthetic; // Trakt-seeded fraction row (fake 100000ms duration)
  final String origin; // 'local' | 'trakt'

  const WatchRow({
    required this.key,
    required this.positionMs,
    required this.durationMs,
    required this.watched,
    required this.updatedAt,
    this.deleted = false,
    this.synthetic = false,
    this.origin = 'local',
  });

  factory WatchRow.fromDb(Map<String, Object?> r) => WatchRow(
        key: r['ep_key'] as String,
        positionMs: (r['position_ms'] as int?) ?? 0,
        durationMs: (r['duration_ms'] as int?) ?? 0,
        watched: (r['watched'] as int? ?? 0) == 1,
        updatedAt: (r['updated_at'] as int?) ?? 0,
        deleted: (r['deleted'] as int? ?? 0) == 1,
        synthetic: (r['synthetic'] as int? ?? 0) == 1,
        origin: (r['origin'] as String?) ?? 'local',
      );

  Map<String, Object?> toDb() => {
        'ep_key': key,
        'position_ms': positionMs,
        'duration_ms': durationMs,
        'watched': watched ? 1 : 0,
        'updated_at': updatedAt,
        'deleted': deleted ? 1 : 0,
        'synthetic': synthetic ? 1 : 0,
        'origin': origin,
      };
}

WatchRow mergeWatch(WatchRow? a, WatchRow b) {
  if (a == null) return b;
  if (b.updatedAt != a.updatedAt) return b.updatedAt > a.updatedAt ? b : a;
  if (a.synthetic != b.synthetic) return a.synthetic ? b : a;
  return b.positionMs >= a.positionMs ? b : a;
}
