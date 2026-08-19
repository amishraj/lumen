// POST /v1/sync — one endpoint, both directions, which gets the ordering
// right for free: push is applied, then the page of changes (including this
// push's own accepted docs) comes back with per-op results.

import {
  NAMESPACES, PAGE_SIZE, opStatements, resultStatement, changesPage,
  fullPage, compactionStatements,
} from './sync_core.js';
import { json, err } from './auth.js';

export async function handleSync(env, auth, request, url) {
  const body = await request.json().catch(() => null);
  if (!body) return err(400, 'bad json');
  const force = url.searchParams.get('force') === '1';
  const cursor = Number(body.cursor ?? 0);
  const ops = Array.isArray(body.ops) ? body.ops : [];
  const now = Date.now();

  const u = await env.DB.prepare('SELECT epoch FROM users WHERE id=?')
    .bind(auth.userId).first();
  if (!u) return err(401, 'no user');

  // Epoch guard: a force-mode replacement is running (or ran) — a normal
  // sync writing into the replacement scan would create rows the scan then
  // tombstones. Stale clients get 409, re-pull /auth/me, and retry.
  const clientEpoch = Number(body.epoch ?? 0);
  if (!force && clientEpoch !== u.epoch) {
    return json({ error: 'stale epoch', epoch: u.epoch }, 409);
  }

  for (const op of ops) {
    if (!NAMESPACES.has(op.ns) || typeof op.k !== 'string' || op.k.length > 512) {
      return err(400, `bad op ${op.ns}:${op.k}`);
    }
  }

  // Build the branchless statement list: 3 per op, then 1 result-SELECT per
  // op, then the changes page — ONE batch(), one transaction, no JS between.
  const stmts = [];
  const metas = [];
  for (const op of ops) {
    const m = await opStatements(auth.userId, auth.deviceId, op, now, { force });
    metas.push({ op, ...m });
    for (const st of m.statements) {
      stmts.push(env.DB.prepare(st.sql).bind(...st.params.map((p) => p ?? null)));
    }
  }
  for (const m of metas) {
    const st = resultStatement(auth.userId, m.op, m.at, m.v, auth.deviceId);
    stmts.push(env.DB.prepare(st.sql).bind(...st.params.map((p) => p ?? null)));
  }

  // Compaction floor check for the pull side.
  const meta = await env.DB.prepare('SELECT floor_seq FROM sync_meta WHERE user_id=?')
    .bind(auth.userId).first();
  const floor = meta?.floor_seq ?? 0;
  const needsFull = cursor > 0 && cursor < floor;
  const pull = needsFull
    ? fullPage(auth.userId, Number(body.full_cursor ?? 0) || await maxSeq(env, auth.userId),
        body.full_after?.ns, body.full_after?.k)
    : changesPage(auth.userId, cursor);
  stmts.push(env.DB.prepare(pull.sql).bind(...pull.params.map((p) => p ?? null)));

  const results = await env.DB.batch(stmts);

  // Post-hoc reads only — the merge already happened, atomically, in SQL.
  const opResults = [];
  const base = ops.length * 3;
  for (let i = 0; i < metas.length; i++) {
    const rows = results[base + i].results ?? [];
    const row = rows[0];
    if (row && Number(row.won) === 1) {
      opResults.push({ ns: metas[i].op.ns, k: metas[i].op.k, ok: true });
    } else {
      opResults.push({
        ns: metas[i].op.ns, k: metas[i].op.k, ok: false,
        current: row
          ? { ns: row.ns, k: row.k, v: row.v, deleted: row.deleted,
              updated_at: row.updated_at, device_id: row.device_id }
          : null,
      });
    }
  }

  const page = results[results.length - 1].results ?? [];
  const more = page.length > PAGE_SIZE;
  const rows = more ? page.slice(0, PAGE_SIZE) : page;

  if (needsFull) {
    const fullCursor = Number(body.full_cursor ?? 0) || await maxSeq(env, auth.userId);
    const last = rows[rows.length - 1];
    return json({
      full: true,
      full_cursor: fullCursor,
      // Cursor semantics for the snapshot: resume keyset, then switch to
      // seq>full_cursor once more=false.
      full_after: last ? { ns: last.ns, k: last.k } : null,
      changes: rows.map(docRow),
      results: opResults,
      more,
      epoch: u.epoch,
    });
  }

  // The returned cursor is the highest seq ACTUALLY INCLUDED in this page —
  // never the server's current max, or more:true would let a client skip
  // rows it never received.
  const newCursor = rows.length ? rows[rows.length - 1].seq : cursor;
  await env.DB.prepare('UPDATE devices SET last_seen=? WHERE id=?')
    .bind(now, auth.deviceId).run();

  if (force) {
    // Authoritative replacement finished this batch: tombstone server docs
    // absent locally happens client-side by pushing explicit tombstones;
    // here we just bump the epoch once the client says it's done.
    if (body.force_complete) {
      await env.DB.prepare('UPDATE users SET epoch=epoch+1 WHERE id=?')
        .bind(auth.userId).run();
      const nu = await env.DB.prepare('SELECT epoch FROM users WHERE id=?')
        .bind(auth.userId).first();
      return json({ cursor: newCursor, changes: rows.map(docRow),
        results: opResults, more, epoch: nu.epoch });
    }
  }

  return json({
    cursor: newCursor,
    changes: rows.map(docRow),
    results: opResults,
    more,
    epoch: u.epoch,
  });
}

function docRow(r) {
  return {
    seq: r.seq, ns: r.ns, k: r.k, v: r.v, deleted: r.deleted,
    updated_at: r.updated_at, device_id: r.device_id,
  };
}

async function maxSeq(env, userId) {
  const r = await env.DB.prepare('SELECT MAX(seq) AS m FROM changes WHERE user_id=?')
    .bind(userId).first();
  return r?.m ?? 0;
}

/** Nightly cron: compaction + expired-pairing GC. */
export async function compact(env) {
  const { results: users } = await env.DB.prepare('SELECT id FROM users').all();
  for (const u of users) {
    const stmts = compactionStatements(u.id)
      .map((st) => env.DB.prepare(st.sql).bind(...st.params));
    await env.DB.batch(stmts);
  }
  await env.DB.prepare('DELETE FROM pairings WHERE expires_at < ?')
    .bind(Date.now() - 24 * 3600 * 1000).run();
}
