// Accounts, tokens, TV pairing. No JWTs: bearers are 32 random bytes, stored
// as SHA-256 hashes, long-lived and revocable — one indexed lookup per
// request, and "sign this TV out" actually works.

const PW_ITERS = 100_000;

const enc = new TextEncoder();

export async function sha256hex(s) {
  const d = await crypto.subtle.digest('SHA-256', enc.encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function b64(buf) {
  return btoa(String.fromCharCode(...new Uint8Array(buf)));
}

function randomHex(nBytes) {
  const a = crypto.getRandomValues(new Uint8Array(nBytes));
  return [...a].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function pbkdf2(password, saltB64, iters) {
  const salt = Uint8Array.from(atob(saltB64), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('raw', enc.encode(password), 'PBKDF2', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', hash: 'SHA-256', salt, iterations: iters }, key, 256);
  return b64(bits);
}

export function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

export function err(status, message) {
  return json({ error: message }, status);
}

/** Resolve the bearer token to {userId, deviceId} or null. A superseded
 * token (rotation grace) stays valid for 24h — instant supersession strands
 * a device that crashed before persisting its replacement. */
export async function authenticate(env, request) {
  const h = request.headers.get('authorization') ?? '';
  if (!h.startsWith('Bearer ')) return null;
  const hash = await sha256hex(h.slice(7));
  const row = await env.DB.prepare(
    `SELECT t.user_id, t.device_id, t.superseded_at, u.disabled
     FROM tokens t JOIN users u ON u.id=t.user_id
     WHERE t.hash=? AND t.revoked=0`).bind(hash).first();
  if (!row || row.disabled) return null;
  if (row.superseded_at && Date.now() - row.superseded_at > 24 * 3600 * 1000) return null;
  return { userId: row.user_id, deviceId: row.device_id, tokenHash: hash };
}

async function mintToken(env, userId, deviceLabel, platform) {
  const token = randomHex(32);
  const deviceId = randomHex(8);
  const now = Date.now();
  await env.DB.batch([
    env.DB.prepare(
      'INSERT INTO devices(id,user_id,label,platform,last_seen,created_at) VALUES(?,?,?,?,?,?)')
      .bind(deviceId, userId, deviceLabel ?? 'device', platform ?? 'unknown', now, now),
    env.DB.prepare(
      'INSERT INTO tokens(hash,user_id,device_id,created_at) VALUES(?,?,?,?)')
      .bind(await sha256hex(token), userId, deviceId, now),
  ]);
  return { token, deviceId };
}

// ---- Admin (X-Admin-Secret) ------------------------------------------------

export async function adminCreateUser(env, request) {
  const { email, password, label } = await request.json();
  if (!email || !password) return err(400, 'email and password required');
  const salt = b64(crypto.getRandomValues(new Uint8Array(16)));
  const hash = await pbkdf2(password, salt, PW_ITERS);
  const id = randomHex(8);
  try {
    await env.DB.prepare(
      `INSERT INTO users(id,email,label,pw_hash,pw_salt,pw_iters,created_at)
       VALUES(?,?,?,?,?,?,?)`)
      .bind(id, email.toLowerCase(), label ?? email, hash, salt, PW_ITERS, Date.now())
      .run();
  } catch {
    return err(409, 'email already exists');
  }
  return json({ id, email: email.toLowerCase() });
}

export async function adminListUsers(env) {
  const { results } = await env.DB.prepare(
    `SELECT u.id, u.email, u.label, u.disabled, u.created_at,
            (SELECT COUNT(*) FROM devices d WHERE d.user_id=u.id) AS devices
     FROM users u ORDER BY u.created_at`).all();
  return json({ users: results });
}

export async function adminRevokeUser(env, request) {
  const { user_id, disable } = await request.json();
  await env.DB.batch([
    env.DB.prepare('UPDATE tokens SET revoked=1 WHERE user_id=?').bind(user_id),
    env.DB.prepare('UPDATE users SET disabled=? WHERE id=?').bind(disable ? 1 : 0, user_id),
  ]);
  return json({ ok: true });
}

// ---- Login / devices -------------------------------------------------------

export async function login(env, request) {
  const { email, password, device, platform } = await request.json();
  const u = await env.DB.prepare('SELECT * FROM users WHERE email=? AND disabled=0')
    .bind((email ?? '').toLowerCase()).first();
  if (!u) return err(401, 'invalid credentials');
  const hash = await pbkdf2(password ?? '', u.pw_salt, u.pw_iters);
  if (hash !== u.pw_hash) return err(401, 'invalid credentials');
  const { token, deviceId } = await mintToken(env, u.id, device, platform);
  return json({
    token,
    device_id: deviceId,
    user: { id: u.id, email: u.email, label: u.label, epoch: u.epoch },
  });
}

export async function me(env, auth) {
  const u = await env.DB.prepare('SELECT id,email,label,epoch FROM users WHERE id=?')
    .bind(auth.userId).first();
  const { results: devices } = await env.DB.prepare(
    `SELECT d.id, d.label, d.platform, d.last_seen, d.created_at,
            (SELECT COUNT(*) FROM tokens t WHERE t.device_id=d.id AND t.revoked=0) AS active
     FROM devices d WHERE d.user_id=? ORDER BY d.last_seen DESC`)
    .bind(auth.userId).all();
  return json({ user: u, devices });
}

export async function logout(env, auth) {
  await env.DB.prepare('UPDATE tokens SET revoked=1 WHERE hash=?').bind(auth.tokenHash).run();
  return json({ ok: true });
}

export async function revokeDevice(env, auth, request) {
  const { device_id } = await request.json();
  await env.DB.prepare('UPDATE tokens SET revoked=1 WHERE user_id=? AND device_id=?')
    .bind(auth.userId, device_id).run();
  return json({ ok: true });
}

/** Explicit rotation with a grace window: the old token keeps working for
 * 24h (marked superseded), so a crash before the new token persists cannot
 * strand the device. Never invalidate on issue. */
export async function refresh(env, auth) {
  const token = randomHex(32);
  const now = Date.now();
  await env.DB.batch([
    env.DB.prepare('INSERT INTO tokens(hash,user_id,device_id,created_at) VALUES(?,?,?,?)')
      .bind(await sha256hex(token), auth.userId, auth.deviceId, now),
    env.DB.prepare('UPDATE tokens SET superseded_at=? WHERE hash=? AND superseded_at IS NULL')
      .bind(now, auth.tokenHash),
  ]);
  return json({ token });
}

// ---- TV pairing (5-minute, single-use codes) -------------------------------

export async function pairStart(env, request) {
  const { device, platform } = await request.json().catch(() => ({}));
  const deviceCode = randomHex(24);
  // 6-digit code the user types on their phone; uniqueness enforced by retry.
  const userCode = String(crypto.getRandomValues(new Uint32Array(1))[0] % 900000 + 100000);
  const now = Date.now();
  await env.DB.prepare(
    `INSERT INTO pairings(device_code,user_code,device_label,platform,created_at,expires_at)
     VALUES(?,?,?,?,?,?)`)
    .bind(deviceCode, userCode, device ?? 'TV', platform ?? 'tv', now, now + 5 * 60 * 1000)
    .run();
  return json({ device_code: deviceCode, user_code: userCode, expires_in: 300, interval: 5 });
}

export async function pairApprove(env, auth, request) {
  const { user_code } = await request.json();
  const row = await env.DB.prepare(
    'SELECT device_code FROM pairings WHERE user_code=? AND used=0 AND user_id IS NULL AND expires_at>?')
    .bind(user_code ?? '', Date.now()).first();
  if (!row) return err(404, 'code not found or expired');
  await env.DB.prepare('UPDATE pairings SET user_id=? WHERE device_code=?')
    .bind(auth.userId, row.device_code).run();
  return json({ ok: true });
}

export async function pairPoll(env, request) {
  const { device_code } = await request.json();
  const row = await env.DB.prepare('SELECT * FROM pairings WHERE device_code=?')
    .bind(device_code ?? '').first();
  if (!row || row.used || row.expires_at < Date.now()) return err(410, 'expired');
  if (row.attempts > 200) return err(429, 'too many polls');
  await env.DB.prepare('UPDATE pairings SET attempts=attempts+1 WHERE device_code=?')
    .bind(device_code).run();
  if (!row.user_id) return err(428, 'authorization pending');
  await env.DB.prepare('UPDATE pairings SET used=1 WHERE device_code=?').bind(device_code).run();
  const { token, deviceId } = await mintToken(env, row.user_id, row.device_label, row.platform);
  const u = await env.DB.prepare('SELECT id,email,label,epoch FROM users WHERE id=?')
    .bind(row.user_id).first();
  return json({ token, device_id: deviceId, user: u });
}
