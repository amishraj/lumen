// The sync merge, as data — pure functions producing SQL statements, so the
// exact statements the Worker runs can be executed against a real SQLite in
// tests (node:sqlite) with the same one-transaction semantics as D1 batch().
//
// HARD RULE: no merge decision is made in JavaScript. If the Worker read the
// current row, decided, then wrote, two concurrent requests could both read
// the old row and the later write would silently overwrite the real winner.
// Every predicate runs atomically against the live row, inside one statement.
// The flow is also BRANCHLESS: batch() takes a prebuilt statement list, so
// nothing can be conditioned on an earlier statement's result. Every op emits
// the same three statements; correctness lives in the predicates:
//
//  1. conditional upsert — pure LWW over the total order (updated_at,
//     device_id). Commutative/associative/idempotent, hence convergent.
//  2. log append — fires iff docs now carries THIS exact op (full payload
//     match, not just the stamp: a different op sharing device+tick must not
//     be mistaken for it). UNIQUE(op_id) + OR IGNORE makes retries no-ops.
//  3. seq denormalization onto docs — recomputes the same value when 2 was
//     ignored, so retries don't move anything.

import { canonicalJson, opId } from './canonical.js';

export const NAMESPACES = new Set(['prog', 'fav', 'pin', 'set', 'src', 'cwh']);
export const PAGE_SIZE = 500;

/** Clamp a client stamp to [now-7d, now+5min] — TV boxes without NTP boot
 * with wild clocks, and one device stuck in 2030 must not win LWW forever. */
export function clampStamp(updatedAt, nowMs) {
  const lo = nowMs - 7 * 24 * 3600 * 1000;
  const hi = nowMs + 5 * 60 * 1000;
  return Math.min(Math.max(updatedAt, lo), hi);
}

/** The three statements for one op. `force` drops the merge predicate
 * entirely (authoritative replacement — sign-in "Upload this device"). */
export async function opStatements(userId, deviceId, op, nowMs, { force = false } = {}) {
  const deleted = op.deleted ? 1 : 0;
  const v = deleted ? null : canonicalJson(op.v);
  const at = clampStamp(op.updated_at, nowMs);
  const id = await opId(userId, op.ns, op.k, at, deviceId, deleted, v);
  const predicate = force
    ? ''
    : `WHERE excluded.updated_at > docs.updated_at
         OR (excluded.updated_at = docs.updated_at AND excluded.device_id > docs.device_id)`;
  return {
    opId: id,
    at,
    v,
    statements: [
      {
        sql: `INSERT INTO docs(user_id,ns,k,v,deleted,updated_at,device_id,seq)
              VALUES(?1,?2,?3,?4,?5,?6,?7,0)
              ON CONFLICT(user_id,ns,k) DO UPDATE SET
                v=excluded.v, deleted=excluded.deleted,
                updated_at=excluded.updated_at, device_id=excluded.device_id
              ${predicate}`,
        params: [userId, op.ns, op.k, v, deleted, at, deviceId],
      },
      {
        sql: `INSERT OR IGNORE INTO changes(op_id,user_id,ns,k,v,deleted,updated_at,device_id)
              SELECT ?1,?2,?3,?4,?5,?6,?7,?8
              WHERE EXISTS (SELECT 1 FROM docs
                            WHERE user_id=?2 AND ns=?3 AND k=?4
                              AND updated_at=?7 AND device_id=?8
                              AND deleted=?6 AND v IS ?5)`,
        params: [id, userId, op.ns, op.k, v, deleted, at, deviceId],
      },
      {
        sql: `UPDATE docs SET seq=(SELECT MAX(seq) FROM changes
                                   WHERE user_id=?1 AND ns=?2 AND k=?3)
              WHERE user_id=?1 AND ns=?2 AND k=?3
                AND EXISTS (SELECT 1 FROM changes WHERE user_id=?1 AND ns=?2 AND k=?3)`,
        params: [userId, op.ns, op.k],
      },
    ],
  };
}

/** Post-batch per-op result: did THIS op win? Full-payload comparison — a
 * rejected op must come back as a rejection with the current server doc, or
 * a device whose cursor is already past the winner keeps its losing local
 * value forever (the outbox row is gone; nothing would ever retry). */
export function resultStatement(userId, op, at, v, deviceId) {
  return {
    sql: `SELECT ns,k,v,deleted,updated_at,device_id,seq,
                 (updated_at=?4 AND device_id=?5 AND deleted=?6 AND v IS ?7) AS won
          FROM docs WHERE user_id=?1 AND ns=?2 AND k=?3`,
    params: [userId, op.ns, op.k, at, deviceId, op.deleted ? 1 : 0, v],
  };
}

export function changesPage(userId, cursor) {
  return {
    sql: `SELECT seq,ns,k,v,deleted,updated_at,device_id FROM changes
          WHERE user_id=?1 AND seq>?2 ORDER BY seq LIMIT ${PAGE_SIZE + 1}`,
    params: [userId, cursor],
  };
}

/** Full resync (cursor below the compaction floor). The snapshot must be
 * state AS OF full_cursor: every page filters docs.seq<=full_cursor, or a
 * paged scan could hand back rows newer than the cursor the client stores. */
export function fullPage(userId, fullCursor, afterNs, afterK) {
  return {
    sql: `SELECT ns,k,v,deleted,updated_at,device_id,seq FROM docs
          WHERE user_id=?1 AND seq<=?2 AND (ns>?3 OR (ns=?3 AND k>?4))
          ORDER BY ns,k LIMIT ${PAGE_SIZE + 1}`,
    params: [userId, fullCursor, afterNs ?? '', afterK ?? ''],
  };
}

/** Nightly compaction: drop changes superseded by a later row for the same
 * (user,ns,k), remember the highest dropped seq as the floor. */
export function compactionStatements(userId) {
  return [
    {
      sql: `INSERT INTO sync_meta(user_id, floor_seq)
            SELECT ?1, COALESCE(MAX(c.seq), 0) FROM changes c
            WHERE c.user_id=?1 AND EXISTS (
              SELECT 1 FROM changes c2 WHERE c2.user_id=c.user_id
                AND c2.ns=c.ns AND c2.k=c.k AND c2.seq>c.seq)
            ON CONFLICT(user_id) DO UPDATE SET
              floor_seq=MAX(floor_seq, excluded.floor_seq)`,
      params: [userId],
    },
    {
      sql: `DELETE FROM changes WHERE user_id=?1 AND EXISTS (
              SELECT 1 FROM changes c2 WHERE c2.user_id=changes.user_id
                AND c2.ns=changes.ns AND c2.k=changes.k AND c2.seq>changes.seq)`,
      params: [userId],
    },
  ];
}
