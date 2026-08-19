// Executes the EXACT SQL the Worker runs (sync_core.js) against a real
// SQLite (node:sqlite) with D1 batch semantics: one transaction, statements
// in order, no JS decisions in between. This is where the protocol's
// convergence claims stop being an argument and start being a test.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import {
  opStatements, resultStatement, changesPage, fullPage,
  compactionStatements, clampStamp, PAGE_SIZE,
} from '../src/sync_core.js';
import { canonicalJson, opId } from '../src/canonical.js';

const NOW = 1755600000000;
const U = 'user1';

function freshDb() {
  const db = new DatabaseSync(':memory:');
  db.exec(`
    CREATE TABLE docs (user_id TEXT NOT NULL, ns TEXT NOT NULL, k TEXT NOT NULL,
      v TEXT, deleted INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL,
      device_id TEXT NOT NULL, seq INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (user_id, ns, k));
    CREATE TABLE changes (seq INTEGER PRIMARY KEY AUTOINCREMENT,
      op_id TEXT NOT NULL UNIQUE, user_id TEXT NOT NULL, ns TEXT NOT NULL,
      k TEXT NOT NULL, v TEXT, deleted INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL, device_id TEXT NOT NULL);
    CREATE TABLE sync_meta (user_id TEXT PRIMARY KEY,
      floor_seq INTEGER NOT NULL DEFAULT 0);
  `);
  return db;
}

/** node:sqlite needs object binding for ?N placeholders (D1 binds them
 * positionally) — same statements, different call convention. */
function bindArgs(params) {
  return Object.fromEntries(params.map((p, i) => [String(i + 1), p ?? null]));
}

/** D1 batch(): sequential + transactional. */
function runBatch(db, statements) {
  db.exec('BEGIN');
  try {
    for (const st of statements) {
      db.prepare(st.sql).run(bindArgs(st.params));
    }
    db.exec('COMMIT');
  } catch (e) {
    db.exec('ROLLBACK');
    throw e;
  }
}

/** Push a batch of ops for a device; returns per-op results like sync.js. */
async function push(db, deviceId, ops, { force = false } = {}) {
  const stmts = [];
  const metas = [];
  for (const op of ops) {
    const m = await opStatements(U, deviceId, op, NOW, { force });
    metas.push({ op, ...m });
    stmts.push(...m.statements);
  }
  runBatch(db, stmts);
  return metas.map((m) => {
    const st = resultStatement(U, m.op, m.at, m.v, deviceId);
    const row = db.prepare(st.sql).get(bindArgs(st.params));
    return row && Number(row.won) === 1
      ? { ns: m.op.ns, k: m.op.k, ok: true }
      : { ns: m.op.ns, k: m.op.k, ok: false, current: row ?? null };
  });
}

function docs(db) {
  return db.prepare('SELECT * FROM docs ORDER BY ns,k').all();
}
function changes(db) {
  return db.prepare('SELECT * FROM changes ORDER BY seq').all();
}

const prog = (k, p, at, extra = {}) => ({
  ns: 'prog', k, v: { p, d: 7200000, w: 0, ...extra }, deleted: false, updated_at: at,
});

test('convergence: same ops in any order end in identical docs', async () => {
  const ops = [
    prog('movie:dune', 100, NOW - 5000),
    prog('movie:dune', 900, NOW - 1000),
    prog('movie:dune', 500, NOW - 3000),
    { ns: 'fav', k: 'movie:dune', v: { at: NOW - 2000 }, deleted: false, updated_at: NOW - 2000 },
    { ns: 'fav', k: 'movie:dune', v: null, deleted: true, updated_at: NOW - 500 },
  ];
  const devices = ['devA', 'devB', 'devC', 'devA', 'devB'];

  const finals = [];
  // A few hundred random interleavings, one op per batch (worst case).
  for (let trial = 0; trial < 300; trial++) {
    const order = [...ops.keys()].sort(() => Math.random() - 0.5);
    const db = freshDb();
    for (const i of order) await push(db, devices[i], [ops[i]]);
    finals.push(JSON.stringify(
      docs(db).map(({ seq, ...r }) => r))); // seq differs by order; state must not
    db.close();
  }
  assert.equal(new Set(finals).size, 1, 'every order converges to one state');
  // And the winner is the newest write per key.
  const db = freshDb();
  for (const i of ops.keys()) await push(db, devices[i], [ops[i]]);
  const d = docs(db);
  const progRow = d.find((r) => r.ns === 'prog');
  assert.equal(JSON.parse(progRow.v).p, 900);
  const favRow = d.find((r) => r.ns === 'fav');
  assert.equal(favRow.deleted, 1, 'tombstone won (newest)');
  db.close();
});

test('retry idempotence: re-pushing an accepted op burns nothing', async () => {
  const db = freshDb();
  const op = prog('movie:heat', 1000, NOW - 1000);
  await push(db, 'devA', [op]);
  const seqsBefore = changes(db).map((c) => c.seq);
  const res = await push(db, 'devA', [op]); // identical retry
  assert.deepEqual(changes(db).map((c) => c.seq), seqsBefore,
    'no duplicate change, no new seq');
  assert.equal(res[0].ok, true, 'retry still reports success');
  assert.equal(docs(db)[0].seq, seqsBefore[seqsBefore.length - 1]);
  db.close();
});

test('losing write comes back as a rejection with the current doc', async () => {
  const db = freshDb();
  await push(db, 'devA', [prog('movie:up', 5000, NOW - 1000)]);
  const res = await push(db, 'devB', [prog('movie:up', 100, NOW - 60000)]);
  assert.equal(res[0].ok, false);
  assert.equal(JSON.parse(res[0].current.v).p, 5000, 'server doc inlined');
  assert.equal(changes(db).length, 1, 'losing op appended nothing');
  assert.equal(docs(db)[0].device_id, 'devA');
  db.close();
});

test('offline completion survives a later-arriving stale checkpoint', async () => {
  const db = freshDb();
  // TV completes at T (watched flag in v).
  await push(db, 'tv', [prog('breaking bad|s5e14', 7000000, NOW - 3600000, { w: 1 })]);
  // Phone was offline since T-2h with a 40% checkpoint; reconnects at T+1h
  // and pushes — its stamp is checkpoint time, so it correctly loses.
  const res = await push(db, 'phone',
    [prog('breaking bad|s5e14', 2880000, NOW - 2 * 3600000)]);
  assert.equal(res[0].ok, false);
  assert.equal(JSON.parse(docs(db)[0].v).w, 1, 'completion survives');
  db.close();
});

test('same-key concurrent pushes: deterministic winner, never flips', async () => {
  for (let i = 0; i < 200; i++) {
    const db = freshDb();
    const a = prog('movie:tie', 111, NOW - 1000);
    const b = prog('movie:tie', 222, NOW - 1000); // same stamp, different device
    if (Math.random() < 0.5) {
      await push(db, 'devA', [a]); await push(db, 'devB', [b]);
    } else {
      await push(db, 'devB', [b]); await push(db, 'devA', [a]);
    }
    // Tiebreak: higher device_id wins regardless of arrival order.
    assert.equal(docs(db)[0].device_id, 'devB');
    assert.equal(JSON.parse(docs(db)[0].v).p, 222);
    db.close();
  }
});

test('paging: a client that stops mid-loop resumes without skipping', async () => {
  const db = freshDb();
  const n = PAGE_SIZE + 137;
  for (let i = 0; i < n; i++) {
    await push(db, 'devA', [prog(`movie:m${i}`, i, NOW - 100000 + i)]);
  }
  const got = [];
  let cursor = 0;
  for (;;) {
    const st = changesPage(U, cursor);
    const page = db.prepare(st.sql).all(bindArgs(st.params));
    const more = page.length > PAGE_SIZE;
    const rows = more ? page.slice(0, PAGE_SIZE) : page;
    got.push(...rows.map((r) => r.k));
    if (!rows.length) break;
    cursor = rows[rows.length - 1].seq; // highest seq INCLUDED in the page
    if (!more) break;
  }
  assert.equal(new Set(got).size, n, 'every change delivered exactly once');
  db.close();
});

test('compaction: floor forces full resync; snapshot is as-of the watermark', async () => {
  const db = freshDb();
  for (let i = 0; i < 40; i++) {
    await push(db, 'devA', [prog('movie:same', i, NOW - 100000 + i)]);
  }
  await push(db, 'devA', [prog('movie:other', 1, NOW - 50)]);
  runBatch(db, compactionStatements(U));
  const floor = db.prepare('SELECT floor_seq FROM sync_meta WHERE user_id=?').get(U).floor_seq;
  assert.ok(floor >= 39, 'floor covers the superseded rows');
  assert.equal(changes(db).length, 2, 'one live row per key survives');

  // Stale-cursor client: full pull filtered to seq<=full_cursor, then a
  // change written MID-SCAN is still delivered afterwards via the cursor.
  const fullCursor = db.prepare(
    'SELECT MAX(seq) AS m FROM changes WHERE user_id=?').get(U).m;
  await push(db, 'devB', [prog('movie:midscan', 7, NOW - 10)]); // during scan
  const st = fullPage(U, fullCursor, null, null);
  const snap = db.prepare(st.sql).all(bindArgs(st.params));
  assert.ok(!snap.some((r) => r.k === 'movie:midscan'),
    'snapshot excludes rows newer than the watermark');
  const st2 = changesPage(U, fullCursor);
  const tail = db.prepare(st2.sql).all(bindArgs(st2.params));
  assert.ok(tail.some((r) => r.k === 'movie:midscan'),
    'mid-scan write arrives via seq>full_cursor');
  db.close();
});

test('force mode overrides newer server rows (upload-this-device)', async () => {
  const db = freshDb();
  await push(db, 'devA', [prog('movie:x', 999, NOW - 10)]); // newer on server
  const res = await push(db, 'devB', [prog('movie:x', 5, NOW - 99999)], { force: true });
  assert.equal(res[0].ok, true, 'force bypasses the merge predicate');
  assert.equal(JSON.parse(docs(db)[0].v).p, 5);
  db.close();
});

test('clamp: a 2030 clock cannot win LWW forever', () => {
  const y2030 = NOW + 4 * 365 * 24 * 3600 * 1000;
  assert.equal(clampStamp(y2030, NOW), NOW + 5 * 60 * 1000);
  assert.equal(clampStamp(0, NOW), NOW - 7 * 24 * 3600 * 1000);
  assert.equal(clampStamp(NOW - 1000, NOW), NOW - 1000, 'sane stamps untouched');
});

test('canonical JSON: nested reordering cannot change the op id', async () => {
  const a = { src: { url: 'http://x', creds: { user: 'u', pass: 'p' }, tags: [1, 2] } };
  const b = { src: { tags: [1, 2], creds: { pass: 'p', user: 'u' }, url: 'http://x' } };
  assert.equal(canonicalJson(a), canonicalJson(b));
  assert.notEqual(canonicalJson({ a: [1, 2] }), canonicalJson({ a: [2, 1] }),
    'array order is semantic and preserved');
  assert.equal(
    await opId(U, 'src', 'k', 1, 'd', 0, canonicalJson(a)),
    await opId(U, 'src', 'k', 1, 'd', 0, canonicalJson(b)));
});
