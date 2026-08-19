/// The corrected, monotonic stamp every durable write carries.
///
/// Two clock failures, one mechanism: a TV booted at epoch would make
/// legitimate changes that lose LWW forever, and two same-millisecond writes
/// from one device would be indistinguishable (the second silently dropped).
/// So: offset measured from the server's Date header on every sync, and
/// stamps forced strictly increasing per device.
///
/// `_last` is memory-only (persisting it would cost a DB write per stamp);
/// monotonicity across restarts relies on the wall clock, with the server's
/// [-7d, +5min] clamp as the backstop.
class SyncClock {
  SyncClock._();

  /// serverNow - localNow, persisted by the sync engine in sync_state.
  static int offsetMs = 0;

  static int _last = 0;

  static int now() {
    final t = DateTime.now().millisecondsSinceEpoch + offsetMs;
    _last = t > _last ? t : _last + 1;
    return _last;
  }
}
