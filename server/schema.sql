-- Lumen D1 schema. Apply with:
--   wrangler d1 execute lumen --remote --file=schema.sql

CREATE TABLE IF NOT EXISTS users (
  id         TEXT PRIMARY KEY,
  email      TEXT NOT NULL UNIQUE,
  label      TEXT,
  pw_hash    TEXT NOT NULL,           -- PBKDF2-SHA256, base64
  pw_salt    TEXT NOT NULL,           -- base64
  pw_iters   INTEGER NOT NULL,
  epoch      INTEGER NOT NULL DEFAULT 0,  -- bumped by force-mode uploads
  disabled   INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS devices (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL,
  label      TEXT,
  platform   TEXT,
  last_seen  INTEGER,
  created_at INTEGER NOT NULL
);

-- Bearer tokens, stored as SHA-256 hashes — the bearer itself never lands in
-- the database. Long-lived and revocable ("sign this TV out" works).
CREATE TABLE IF NOT EXISTS tokens (
  hash          TEXT PRIMARY KEY,
  user_id       TEXT NOT NULL,
  device_id     TEXT,
  created_at    INTEGER NOT NULL,
  superseded_at INTEGER,              -- refresh grace: old token valid 24h
  revoked       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_tokens_user ON tokens(user_id);

-- Current state, one row per (user, namespace, key). seq denormalizes
-- MAX(changes.seq) for the key so full-pull watermarking is well-defined.
CREATE TABLE IF NOT EXISTS docs (
  user_id    TEXT NOT NULL,
  ns         TEXT NOT NULL,           -- prog | fav | pin | set | src | cwh
  k          TEXT NOT NULL,
  v          TEXT,                    -- canonical JSON; NULL iff deleted=1
  deleted    INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL,        -- client corrected-clock ms, clamped
  device_id  TEXT NOT NULL,
  seq        INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, ns, k)
);

-- Append-only change log. seq is THE revision allocator — AUTOINCREMENT
-- hands out monotone values with no read-modify-write, so two devices
-- syncing at once can never duplicate or clobber a revision counter.
-- op_id is the idempotency key (server-computed hash of the op): a retried
-- push INSERT OR IGNOREs into a no-op instead of burning a new seq.
CREATE TABLE IF NOT EXISTS changes (
  seq        INTEGER PRIMARY KEY AUTOINCREMENT,
  op_id      TEXT NOT NULL UNIQUE,
  user_id    TEXT NOT NULL,
  ns         TEXT NOT NULL,
  k          TEXT NOT NULL,
  v          TEXT,
  deleted    INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL,
  device_id  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_changes_user ON changes(user_id, seq);

-- Per-user compaction floor: a cursor below this must full-resync from docs.
CREATE TABLE IF NOT EXISTS sync_meta (
  user_id   TEXT PRIMARY KEY,
  floor_seq INTEGER NOT NULL DEFAULT 0
);

-- TV pairing codes: 5-minute, single-use.
CREATE TABLE IF NOT EXISTS pairings (
  device_code TEXT PRIMARY KEY,
  user_code   TEXT NOT NULL,
  device_label TEXT,
  platform    TEXT,
  user_id     TEXT,                   -- set on approve
  attempts    INTEGER NOT NULL DEFAULT 0,
  used        INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL,
  expires_at  INTEGER NOT NULL
);

-- Per-title TMDB/OMDb results. Deliberately D1, not KV: the KV free plan
-- allows only 1k writes/day, which a per-title cache would burn through.
CREATE TABLE IF NOT EXISTS meta_cache (
  k          TEXT PRIMARY KEY,
  v          TEXT NOT NULL,
  fetched_at INTEGER NOT NULL
);
