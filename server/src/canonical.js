// Canonical JSON + the op idempotency key.
//
// Both op_id and the merge's `v IS ?` comparison depend on a byte-stable
// representation: a client that formats its JSON differently on a retry must
// still produce an identical string. So the Worker ALWAYS re-serializes the
// parsed op with this — never the raw bytes off the wire — and the
// canonicalization is RECURSIVE: object keys sorted at every depth, array
// order preserved, JSON.stringify's number/escape normalization throughout.
// (src/prog values are nested; a shallow sort would let two encodings of the
// same document hash differently, silently breaking retry idempotence.)

export function canonicalize(value) {
  if (value === undefined) return null;
  return JSON.parse(JSON.stringify(value)); // strips undefined, normalizes -0 etc.
}

export function canonicalJson(value) {
  const walk = (v) => {
    if (v === null || typeof v !== 'object') return JSON.stringify(v);
    if (Array.isArray(v)) return `[${v.map((e) => walk(e ?? null)).join(',')}]`;
    const keys = Object.keys(v).filter((k) => v[k] !== undefined).sort();
    return `{${keys
      .map((k) => `${JSON.stringify(k)}:${walk(v[k])}`)
      .join(',')}}`;
  };
  return walk(canonicalize(value));
}

/// Server-computed idempotency key. Derived entirely from the op, so a retry
/// produces the same id and INSERT OR IGNORE drops it. Server-side because a
/// client that chose its own op_id could collide with an existing one and
/// suppress its own log entry.
export async function opId(userId, ns, k, updatedAt, deviceId, deleted, vCanonical) {
  const input = canonicalJson([userId, ns, k, updatedAt, deviceId, deleted ? 1 : 0, vCanonical]);
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
