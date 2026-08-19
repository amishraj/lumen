/// Where a durable write came from — the bit that decides whether it enters
/// the sync outbox. Explicit parameter, not an ambient flag: a pull's await
/// interleaves with the player's concurrent 5-second checkpoint, and an
/// ambient flag would suppress the checkpoint.
enum SyncOrigin {
  /// A user action on this device → journal it.
  local,

  /// Derived from the Trakt account → never journal. A Trakt fact is by
  /// construction already reachable by every device holding the account;
  /// routing it through our server duplicates it along a second path with a
  /// worse timestamp — the ping-pong generator.
  trakt,

  /// Applied from OUR server's pull → never journal (it came from there).
  remote,

  /// Vault restore, library re-map, migrations → never journal.
  system,
}

extension SyncOriginJournal on SyncOrigin {
  bool get journals => this == SyncOrigin.local;
}
