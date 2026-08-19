# Lumen API — Cloudflare Worker + D1

Auth, sync, and metadata catalog for Lumen. Free tier is ample: Workers
100k req/day; D1 5 GB, 5M row-reads/day, 100k row-writes/day.

## One-time setup

```sh
npm i -g wrangler
wrangler login
cd server
wrangler d1 create lumen        # paste the database_id into wrangler.toml
wrangler d1 execute lumen --remote --file=schema.sql
wrangler secret put ADMIN_SECRET          # any long random string
wrangler secret put TMDB_KEY
wrangler secret put OMDB_KEY              # optional (ratings)
wrangler secret put TRAKT_CLIENT_ID       # make a FRESH trakt.tv app —
wrangler secret put TRAKT_CLIENT_SECRET   # the old secret shipped in APKs
wrangler deploy
```

Then mint accounts (no public signup):

```sh
curl -X POST https://lumen-api.<you>.workers.dev/v1/admin/users \
  -H "X-Admin-Secret: $ADMIN_SECRET" -H 'content-type: application/json' \
  -d '{"email":"you@example.com","password":"...","label":"Me"}'
```

## Surface

| Endpoint | Auth | Purpose |
|---|---|---|
| `POST /v1/auth/login` | — | email+password → bearer token |
| `POST /v1/auth/pair/start` / `poll` | — | TV code flow (5-min single-use codes) |
| `POST /v1/auth/pair/approve` | bearer | approve a TV code from a phone |
| `GET /v1/auth/me` | bearer | user + device list (last seen) |
| `POST /v1/auth/logout` / `devices/revoke` / `refresh` | bearer | session control |
| `POST /v1/sync[?force=1]` | bearer | push ops + pull changes, one round trip |
| `GET /v1/tmdb/*`, `GET /v1/omdb` | bearer | key-injecting caching proxies |
| `GET /v1/catalog/home` | bearer | whole discovery home in one response |
| `POST /v1/meta/batch` | bearer | resolve up to 60 titles at once |
| `POST /v1/trakt/oauth/*` | bearer | Trakt device-code flow (secret server-side) |
| `POST /v1/admin/users` etc. | X-Admin-Secret | mint/list/revoke accounts |

## Sync protocol invariants (tested in test/sync.test.mjs)

- No merge decision in JS: pure LWW over `(updated_at, device_id)`, evaluated
  atomically inside the upsert. Convergent under any interleaving.
- `changes.seq` (AUTOINCREMENT) is the only revision allocator; `op_id`
  (server-computed hash of the canonicalized op) makes retries no-ops.
- Rejected ops return `ok:false` + the current server doc — a device can
  never silently keep a losing value.
- Returned `cursor` = highest seq actually included in the page.
- Compaction keeps a per-user floor; stale cursors get a watermarked full
  resync (`docs.seq <= full_cursor`).
- Force mode (sign-in "Upload this device") drops the merge predicate and
  bumps `users.epoch`; concurrent normal syncs 409 until they re-read it.

Run the protocol tests (no install needed):

```sh
cd server && npm test
```
