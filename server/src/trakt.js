// Trakt OAuth proxy — ONLY the three endpoints that need the app client
// secret live here (device code, device token, refresh). Scrobbles and all
// /sync reads stay app-direct with the user's access token: they're
// authenticated by the USER's token, not the app secret, and routing
// playback traffic through a Worker would add latency for nothing.

import { json, err } from './auth.js';

const TRAKT = 'https://api.trakt.tv';

// Trim: `echo "x" | wrangler secret put` stores a trailing newline, and Trakt
// rejects the credential without ever saying why.
const clientId = (env) => (env.TRAKT_CLIENT_ID ?? '').trim();
const clientSecret = (env) => (env.TRAKT_CLIENT_SECRET ?? '').trim();

async function forward(env, path, body) {
  if (!clientId(env) || !clientSecret(env)) {
    return json(
      { error: 'Trakt is not configured on the server — set TRAKT_CLIENT_ID and TRAKT_CLIENT_SECRET.' },
      500);
  }

  let res;
  try {
    res = await fetch(`${TRAKT}${path}`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'trakt-api-version': '2',
        'trakt-api-key': clientId(env),
        // REQUIRED. Workers' fetch() sends no User-Agent, and Trakt sits
        // behind Cloudflare bot protection which answers a UA-less request
        // with an HTML 403 — never reaching Trakt's API at all. This looked
        // exactly like "bad client id" and no amount of re-setting the
        // secrets could have fixed it.
        'user-agent': 'Lumen/2.0 (+https://github.com/amishraj/lumen)',
        accept: 'application/json',
      },
      body: JSON.stringify(body),
    });
  } catch (e) {
    return json({ error: `Could not reach Trakt: ${e}` }, 502);
  }

  const text = await res.text();

  // Diagnostic (safe): never logs the credentials, only their shape.
  //
  // HTTP 400 on device/token is NOT an error — it is the device flow's
  // "authorization pending" while the user types the code at
  // trakt.tv/activate, and the app polls every few seconds. Logging it
  // buried the real failures in noise.
  const pending = path === '/oauth/device/token' && res.status === 400;
  if (res.status !== 200 && !pending) {
    console.log(
      `trakt ${path} -> HTTP ${res.status} | id_len=${clientId(env).length} ` +
      `secret_len=${clientSecret(env).length} | body=${text.slice(0, 300)}`);
  }

  // Only claim application/json when the body actually IS json. Relabelling
  // an HTML error page (or an empty body) as json turned every upstream
  // failure into an opaque "FormatException: Unexpected character (at
  // offset 0)" in the app, hiding what Trakt actually said.
  try {
    JSON.parse(text);
    return new Response(text, {
      status: res.status,
      headers: { 'content-type': 'application/json' },
    });
  } catch {
    const detail = text.trim() ? text.trim().slice(0, 200) : 'empty response body';
    return json(
      {
        error: `Trakt returned HTTP ${res.status}: ${detail}`,
        upstream_status: res.status,
      },
      // A non-json 200 is an upstream fault, not a client error.
      res.status === 200 ? 502 : res.status);
  }
}

export async function traktProxy(env, request, url) {
  const body = await request.json().catch(() => ({}));
  switch (url.pathname) {
    // Per Trakt's device-flow docs this endpoint takes client_id ONLY —
    // the secret is for the token exchange.
    case '/v1/trakt/oauth/device/code':
      return forward(env, '/oauth/device/code', { client_id: clientId(env) });
    case '/v1/trakt/oauth/device/token':
      return forward(env, '/oauth/device/token', {
        code: body.code,
        client_id: clientId(env),
        client_secret: clientSecret(env),
      });
    case '/v1/trakt/oauth/token':
      return forward(env, '/oauth/token', {
        refresh_token: body.refresh_token,
        client_id: clientId(env),
        client_secret: clientSecret(env),
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
  return json({ client_id: clientId(env) });
}
