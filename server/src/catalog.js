// Metadata catalog: the Worker holds the TMDB/OMDb keys (they stop shipping
// in the APK) and caches at two tiers:
//  - caches.default (the Workers Cache API — free, no write quota) for
//    whole-response GETs: discovery rows are identical for every user, so
//    one TMDB fetch per 6h serves everyone.
//  - the D1 meta_cache table for per-title lookups (durable across POPs;
//    D1's 100k writes/day vs KV's 1k/day is why there's no KV here).
// The Worker never sits in the media path — metadata only.

import { json, err } from './auth.js';

const TMDB = 'https://api.themoviedb.org/3';
const CATALOG_TTL = 6 * 3600; // seconds

/// Make an upstream response safe to hand to the Cache API.
///
/// OMDb answers with `Vary: *`, which the Cache API rejects outright
/// ("Cannot cache response with 'Vary: *' header") — and because the put()
/// threw, the whole request 500'd. Caching is an optimisation; it must never
/// be able to fail the response, hence both the header scrub and the guard
/// around put().
function cacheable(res, ttl) {
  const out = new Response(res.body, res);
  out.headers.delete('vary');
  out.headers.delete('set-cookie');
  out.headers.set('cache-control', `public, max-age=${ttl}`);
  return out;
}

async function putSafe(cacheKey, res) {
  try {
    await caches.default.put(cacheKey, res);
  } catch (e) {
    console.log(`cache put skipped: ${e}`);
  }
}

async function cachedFetch(request, upstreamUrl, ttl) {
  const cacheKey = new Request(new URL(request.url).toString(), { method: 'GET' });
  const hit = await caches.default.match(cacheKey);
  if (hit) return hit;
  const res = await fetch(upstreamUrl);
  if (!res.ok) return new Response(res.body, { status: res.status });
  const out = cacheable(res, ttl);
  await putSafe(cacheKey, out.clone());
  return out;
}

/** GET /v1/tmdb/* — path-preserving proxy with the key injected server-side.
 * The app's TmdbService keeps its exact request shapes; only the base URL
 * changes. Query params pass through (api_key is stripped/overridden). */
export async function tmdbProxy(env, request, url) {
  const sub = url.pathname.replace(/^\/v1\/tmdb/, '');
  if (!/^\/[a-z0-9/_-]*$/i.test(sub) || sub.includes('..')) return err(400, 'bad path');
  const upstream = new URL(TMDB + sub);
  url.searchParams.forEach((v, k) => {
    if (k !== 'api_key') upstream.searchParams.set(k, v);
  });
  upstream.searchParams.set('api_key', env.TMDB_KEY ?? '');
  return cachedFetch(request, upstream.toString(), CATALOG_TTL);
}

/** GET /v1/omdb?t=...&y=... — same idea for OMDb ratings. */
export async function omdbProxy(env, request, url) {
  if (!env.OMDB_KEY) return json({ Response: 'False', Error: 'no key' });
  const upstream = new URL('https://www.omdbapi.com/');
  url.searchParams.forEach((v, k) => {
    if (k !== 'apikey') upstream.searchParams.set(k, v);
  });
  upstream.searchParams.set('apikey', env.OMDB_KEY);
  return cachedFetch(request, upstream.toString(), 7 * 24 * 3600);
}

/** GET /v1/catalog/home — the whole discovery home in ONE response
 * (trending, popular movie/tv, top genres), so a TV cold start is a single
 * ~15KB fetch instead of ~8 TMDB calls. */
export async function catalogHome(env, request) {
  const cacheKey = new Request(new URL(request.url).toString(), { method: 'GET' });
  const hit = await caches.default.match(cacheKey);
  if (hit) return hit;

  const key = env.TMDB_KEY ?? '';
  const get = async (path) => {
    const r = await fetch(`${TMDB}${path}${path.includes('?') ? '&' : '?'}api_key=${key}`);
    return r.ok ? r.json() : { results: [] };
  };
  const [trending, popMovie, popTv, movieGenres, tvGenres] = await Promise.all([
    get('/trending/all/week'),
    get('/movie/popular'),
    get('/tv/popular'),
    get('/genre/movie/list'),
    get('/genre/tv/list'),
  ]);
  const topGenreIds = [28, 35, 18]; // action, comedy, drama — app re-orders by pins
  const genreRows = await Promise.all(topGenreIds.map(async (g) => ({
    genre_id: g,
    results: (await get(`/discover/movie?with_genres=${g}&sort_by=popularity.desc`)).results ?? [],
  })));

  const out = json({
    fetched_at: Date.now(),
    trending: trending.results ?? [],
    popular_movie: popMovie.results ?? [],
    popular_tv: popTv.results ?? [],
    genres: { movie: movieGenres.genres ?? [], tv: tvGenres.genres ?? [] },
    genre_rows: genreRows,
  });
  out.headers.set('cache-control', `public, max-age=${CATALOG_TTL}`);
  await putSafe(cacheKey, out.clone());
  return out;
}

/** POST /v1/meta/batch {titles:[{title,year?,tv?}]} — resolve a page of
 * titles in one round trip (kills the per-card N+1 on watchlist rails).
 * Per-title results live in meta_cache permanently; misses are remembered. */
export async function metaBatch(env, request) {
  const { titles } = await request.json().catch(() => ({}));
  if (!Array.isArray(titles) || titles.length > 60) return err(400, 'titles: 1..60');
  const key = env.TMDB_KEY ?? '';
  const out = [];
  for (const t of titles) {
    const type = t.tv ? 'tv' : 'movie';
    const ck = `meta:${type}:${(t.title ?? '').toLowerCase()}|${t.year ?? ''}`;
    const hit = await env.DB.prepare('SELECT v FROM meta_cache WHERE k=?').bind(ck).first();
    if (hit) {
      out.push(JSON.parse(hit.v));
      continue;
    }
    const q = new URL(`${TMDB}/search/${type}`);
    q.searchParams.set('api_key', key);
    q.searchParams.set('query', t.title ?? '');
    if (t.year) q.searchParams.set(type === 'tv' ? 'first_air_date_year' : 'year', String(t.year));
    const r = await fetch(q).then((x) => (x.ok ? x.json() : { results: [] }));
    const best = (r.results ?? [])[0] ?? null;
    const doc = { title: t.title, year: t.year ?? null, tv: !!t.tv, result: best };
    await env.DB.prepare(
      'INSERT OR REPLACE INTO meta_cache(k,v,fetched_at) VALUES(?,?,?)')
      .bind(ck, JSON.stringify(doc), Date.now()).run();
    out.push(doc);
  }
  return json({ items: out });
}
