// Trakt OAuth proxy — ONLY the three endpoints that need the app client
// secret live here (device code, device token, refresh). Scrobbles and all
// /sync reads stay app-direct with the user's access token: they're
// authenticated by the USER's token, not the app secret, and routing
// playback traffic through a Worker would add latency for nothing.

import { json, err } from './auth.js';

const TRAKT = 'https://api.trakt.tv';

async function forward(env, path, body) {
  const res = await fetch(`${TRAKT}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      ...body,
      client_id: env.TRAKT_CLIENT_ID,
      client_secret: env.TRAKT_CLIENT_SECRET,
    }),
  });
  const text = await res.text();
  return new Response(text, {
    status: res.status,
    headers: { 'content-type': 'application/json' },
  });
}

export async function traktProxy(env, request, url) {
  const body = await request.json().catch(() => ({}));
  switch (url.pathname) {
    case '/v1/trakt/oauth/device/code':
      return forward(env, '/oauth/device/code', {});
    case '/v1/trakt/oauth/device/token':
      return forward(env, '/oauth/device/token', { code: body.code });
    case '/v1/trakt/oauth/token':
      return forward(env, '/oauth/token', {
        refresh_token: body.refresh_token,
        grant_type: 'refresh_token',
        redirect_uri: 'urn:ietf:wg:oauth:2.0:oob',
      });
    default:
      return err(404, 'not found');
  }
}

/** GET /v1/trakt/client_id — the PUBLIC client id, so the app can send the
 * trakt-api-key header on its direct calls without embedding it. */
export function traktClientId(env) {
  return json({ client_id: env.TRAKT_CLIENT_ID ?? '' });
}
