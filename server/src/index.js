// Lumen backend router. ~600 lines total across src/, no framework.
//
// Auth model:
//   /v1/admin/*  — X-Admin-Secret header (owner-minted accounts, no signup)
//   /v1/auth/login, /v1/auth/pair/start|poll — public (rate-limited by shape)
//   everything else — Bearer token (hashed in D1, revocable)

import {
  authenticate, adminCreateUser, adminListUsers, adminRevokeUser,
  login, logout, me, refresh, revokeDevice,
  pairStart, pairApprove, pairPoll, err, json,
} from './auth.js';
import { handleSync, compact } from './sync.js';
import { tmdbProxy, omdbProxy, catalogHome, metaBatch } from './catalog.js';
import { traktProxy, traktClientId } from './trakt.js';

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const p = url.pathname;
    const m = request.method;

    try {
      // ---- public ----
      if (p === '/v1/health') return json({ ok: true, at: Date.now() });
      if (p === '/v1/auth/login' && m === 'POST') return login(env, request);
      if (p === '/v1/auth/pair/start' && m === 'POST') return pairStart(env, request);
      if (p === '/v1/auth/pair/poll' && m === 'POST') return pairPoll(env, request);

      // ---- admin ----
      if (p.startsWith('/v1/admin/')) {
        if (request.headers.get('x-admin-secret') !== env.ADMIN_SECRET || !env.ADMIN_SECRET) {
          return err(403, 'forbidden');
        }
        if (p === '/v1/admin/users' && m === 'POST') return adminCreateUser(env, request);
        if (p === '/v1/admin/users' && m === 'GET') return adminListUsers(env);
        if (p === '/v1/admin/revoke' && m === 'POST') return adminRevokeUser(env, request);
        return err(404, 'not found');
      }

      // ---- authenticated ----
      const auth = await authenticate(env, request);
      if (!auth) return err(401, 'unauthorized');

      if (p === '/v1/auth/me' && m === 'GET') return me(env, auth);
      if (p === '/v1/auth/logout' && m === 'POST') return logout(env, auth);
      if (p === '/v1/auth/refresh' && m === 'POST') return refresh(env, auth);
      if (p === '/v1/auth/devices/revoke' && m === 'POST') return revokeDevice(env, auth, request);
      if (p === '/v1/auth/pair/approve' && m === 'POST') return pairApprove(env, auth, request);

      if (p === '/v1/sync' && m === 'POST') return handleSync(env, auth, request, url);

      if (p.startsWith('/v1/tmdb/') && m === 'GET') return tmdbProxy(env, request, url);
      if (p === '/v1/omdb' && m === 'GET') return omdbProxy(env, request, url);
      if (p === '/v1/catalog/home' && m === 'GET') return catalogHome(env, request);
      if (p === '/v1/meta/batch' && m === 'POST') return metaBatch(env, request);

      if (p.startsWith('/v1/trakt/oauth/') && m === 'POST') return traktProxy(env, request, url);
      if (p === '/v1/trakt/client_id' && m === 'GET') return traktClientId(env);

      return err(404, 'not found');
    } catch (e) {
      return err(500, `${e}`);
    }
  },

  async scheduled(_event, env) {
    await compact(env);
  },
};
