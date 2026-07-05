// Cloudflare Pages advanced-mode Worker (single entry point for the whole site).
// Pages runs this for every request. We handle the two paldb.cc proxy endpoints
// here (setting the Referer header server-side, which a browser on our own origin
// cannot do) and hand everything else to the static assets via env.ASSETS.
//
// Frequently-changing, per-player data (pals/paldeck/eggs/player-effigies/settings)
// is read from the R2 bucket bound as env.DATA, NOT from the deployed static assets.
// This lets that data refresh via cheap R2 object puts (sync_public_data.ps1) without
// any Cloudflare Pages deploy, keeping us far under the 500-deploys/month cap. The
// per-user scoping and Access gating are unchanged -- the Worker still decides which
// R2 key a given authenticated user may read. The rarely-changing static data
// (effigies.json, pal-species.json), portraits, icons, css and index.html still ship
// with the Pages "shell" deploy and are served from env.ASSETS.
//
// Routes:
//   /api/palmaptile?z={z}&x={x}&y={y}  -> cdn.paldb.cc map tile (webp)
//   /api/palspawn?pal=<InternalName>   -> one Pal's entry from the Paldex data
// Everything else -> R2 (scoped data) or static files in the deployed directory.

const TILE_HEADERS = { 'User-Agent': 'Mozilla/5.0', 'Referer': 'https://paldb.cc/' };
const SPAWN_SRC = 'https://paldb.cc/DataTable/UI/DT_PaldexDistributionData.json';

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status: status,
    headers: { 'Content-Type': 'application/json' }
  });
}

async function handleTile(url, ctx) {
  const z = parseInt(url.searchParams.get('z'), 10);
  const x = parseInt(url.searchParams.get('x'), 10);
  const y = parseInt(url.searchParams.get('y'), 10);
  if (!Number.isInteger(z) || !Number.isInteger(x) || !Number.isInteger(y)) {
    return new Response('bad tile', { status: 400 });
  }
  const tileUrl = 'https://cdn.paldb.cc/image/map7/z' + z + 'x' + x + 'y' + y + '.webp';
  const cache = caches.default;
  const cacheKey = new Request(tileUrl, { method: 'GET' });

  let resp = await cache.match(cacheKey);
  if (resp) return resp;

  const upstream = await fetch(tileUrl, { headers: TILE_HEADERS });
  if (!upstream.ok) return new Response('tile not found', { status: 404 });

  resp = new Response(upstream.body, {
    status: 200,
    headers: { 'Content-Type': 'image/webp', 'Cache-Control': 'public, max-age=86400' }
  });
  ctx.waitUntil(cache.put(cacheKey, resp.clone()));
  return resp;
}

async function getAllSpawn(ctx) {
  const cache = caches.default;
  const cacheKey = new Request(SPAWN_SRC, { method: 'GET' });
  let resp = await cache.match(cacheKey);
  if (!resp) {
    const upstream = await fetch(SPAWN_SRC, { headers: TILE_HEADERS });
    if (!upstream.ok) return null;
    resp = new Response(upstream.body, {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=86400' }
    });
    ctx.waitUntil(cache.put(cacheKey, resp.clone()));
  }
  return resp.json();
}

async function handleSpawn(url, ctx) {
  const pal = url.searchParams.get('pal');
  if (!pal) return json({ error: 'missing pal' }, 400);

  const data = await getAllSpawn(ctx);
  if (!data) return json({ error: 'upstream error' }, 502);

  // Upstream is a UE DataTable export: a single-element ARRAY whose object has the
  // per-Pal entries under .Rows, keyed by internal name (e.g. "SheepBall").
  let table = Array.isArray(data) ? data[0] : data;
  const all = (table && table.Rows) ? table.Rows : table;

  let entry = all[pal];
  if (entry === undefined) {
    const lower = pal.toLowerCase();
    const key = Object.keys(all).find(function (k) { return k.toLowerCase() === lower; });
    if (key) entry = all[key];
  }
  if (entry === undefined) return json({ error: 'not found' }, 404);

  return new Response(JSON.stringify(entry), {
    status: 200,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=3600' }
  });
}

// ── Identity / Access config (from Cloudflare Pages environment variables) ──────
// Set these as Pages -> Settings -> Environment variables (Production). Keeping them in
// the environment (not in this file) means no secrets/PII live in the repo, so this Worker
// is byte-for-byte the one you deploy.
//   ALLOWED_HOSTS  = ["palbox.yourdomain.com"]                  (JSON array, or comma list)
//   ADMINS         = ["you@yourdomain.com"]                     (JSON array; these see everyone)
//   EMAIL_TO_GUID  = {"player@example.com":"<32-hex save GUID>"}(JSON object; email -> player)
//   TEAM_DOMAIN    = your-team.cloudflareaccess.com             (Zero Trust team domain)
//   ACCESS_AUD     = <64-hex>                                   (your Access app's AUD tag)
//
// Access JWT verification (defense in depth): we cryptographically verify the
// Cf-Access-Jwt-Assertion (RS256 against the team JWKS) and check issuer/audience/expiry, so a
// forged header on any path that escaped the Access policy still yields no scope. If
// TEAM_DOMAIN/ACCESS_AUD are wrong or missing, verification fails CLOSED (everyone, incl. admin,
// sees empty data) -- an outage, not a leak.
function _jsonEnv(v, fallback) {
  if (v == null || v === '') return fallback;
  try { return JSON.parse(v); } catch (e) {
    // tolerate a bare comma-separated list for the array-typed vars
    if (Array.isArray(fallback)) return String(v).split(',').map(function (s) { return s.trim(); }).filter(Boolean);
    return fallback;
  }
}
function getIdentity(env) {
  const team = String(env.TEAM_DOMAIN || '').trim();
  const iss = 'https://' + team;
  return {
    allowedHosts: _jsonEnv(env.ALLOWED_HOSTS, []),
    admins: _jsonEnv(env.ADMINS, []).map(function (s) { return String(s).toLowerCase(); }),
    emailToGuid: _jsonEnv(env.EMAIL_TO_GUID, {}),
    teamDomain: team,
    aud: String(env.ACCESS_AUD || '').trim(),
    iss: iss,
    certsUrl: iss + '/cdn-cgi/access/certs'
  };
}

// base64url -> bytes / string (JWT uses base64url, atob expects standard base64).
function b64urlToBytes(s) {
  s = s.replace(/-/g, '+').replace(/_/g, '/');
  const pad = s.length % 4;
  if (pad) s += '='.repeat(4 - pad);
  const bin = atob(s);
  const arr = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
  return arr;
}
function b64urlToString(s) {
  return new TextDecoder().decode(b64urlToBytes(s));
}

// Fetch the Access signing keys (JWKS). Edge-cached so we don't hit the certs
// endpoint per request; returns null if it is unreachable (-> fail closed upstream).
async function getAccessKeys(ctx, id) {
  const cache = caches.default;
  const cacheKey = new Request(id.certsUrl, { method: 'GET' });
  let resp = await cache.match(cacheKey);
  if (!resp) {
    const upstream = await fetch(id.certsUrl);
    if (!upstream.ok) return null;
    resp = new Response(await upstream.text(), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=3600' }
    });
    ctx.waitUntil(cache.put(cacheKey, resp.clone()));
  }
  let data;
  try { data = await resp.json(); } catch (e) { return null; }
  return (data && data.keys) ? data.keys : null;
}

// Verify a Cloudflare Access JWT and return its claims, or null if anything fails.
async function verifyAccessJwt(token, ctx, id) {
  if (!token || !id.teamDomain || !id.aud) return null;
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  const head = parts[0], body = parts[1], sig = parts[2];

  let header, payload;
  try {
    header = JSON.parse(b64urlToString(head));
    payload = JSON.parse(b64urlToString(body));
  } catch (e) { return null; }
  if (!header || header.alg !== 'RS256' || !header.kid) return null;

  // Claim checks BEFORE the crypto: issuer, audience (this app only), time bounds.
  const now = Math.floor(Date.now() / 1000);
  if (payload.iss !== id.iss) return null;
  const auds = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  if (auds.indexOf(id.aud) === -1) return null;
  if (typeof payload.exp === 'number' && now >= payload.exp) return null;
  if (typeof payload.nbf === 'number' && now < payload.nbf - 60) return null;

  const keys = await getAccessKeys(ctx, id);
  if (!keys) return null;
  const jwk = keys.find(function (k) { return k.kid === header.kid; });
  if (!jwk) return null;

  let pub;
  try {
    pub = await crypto.subtle.importKey(
      'jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
  } catch (e) { return null; }

  const signed = new TextEncoder().encode(head + '.' + body);
  let ok = false;
  try {
    ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', pub, b64urlToBytes(sig), signed);
  } catch (e) { return null; }
  return ok ? payload : null;
}

// Returns 'all' (admin), a guid string (scoped), or null (deny / show nothing).
// Identity comes ONLY from a cryptographically verified token -- a missing or invalid
// token, or an authenticated-but-unmapped email, all resolve to null (empty data).
async function resolveScope(request, env, ctx) {
  const id = getIdentity(env);
  const payload = await verifyAccessJwt(request.headers.get('Cf-Access-Jwt-Assertion'), ctx, id);
  if (!payload || !payload.email) return null;
  const email = String(payload.email).toLowerCase();
  if (id.admins.includes(email)) return 'all';
  return id.emailToGuid[email] || null;
}

// Serve a JSON object from the R2 data bucket (env.DATA binding) by key. Returns the
// supplied fallback Response when the key is missing OR the binding isn't present --
// e.g. before the first data sync has populated R2, or if the R2 bucket binding was
// not configured on the Pages project. This makes the site degrade to empty data
// rather than throwing, so a missing binding shows "no pals" instead of a 500.
async function r2Serve(env, key, fallback) {
  if (!env.DATA) return fallback;
  const obj = await env.DATA.get(key);
  if (!obj) return fallback;
  return new Response(obj.body, {
    status: 200,
    headers: { 'Content-Type': 'application/json' }
  });
}

function emptyData(name) {
  let body;
  if (name === 'paldeck.json') body = { players: [] };
  else if (name === 'eggs.json') body = { eggs: [], summary: {} };
  else body = { players: [], containers: {}, pals: [] };
  return json(body, 200);
}

// Per-user responses must never be cached (edge or browser): the same URL returns
// different data per authenticated user, so a cached copy could leak across users.
function noStore(resp) {
  const h = new Headers(resp.headers);
  h.set('Cache-Control', 'private, no-store');
  return new Response(resp.body, { status: resp.status, statusText: resp.statusText, headers: h });
}

// ── Per-user UI preferences (cross-device) ──────────────────────────────────────
// A tiny read/write store so a player's filter / sort / selected-player choices follow
// them across refreshes, sessions AND devices. Keyed by the verified Access email. This
// is the ONLY write path on the site, and it stores opaque view preferences only -- never
// anything that controls the server -- so it does not weaken the read-only guarantee.
// The PUT is gated by the same Access JWT verification as every read; an attacker page
// cannot mint the Cf-Access-* assertion (the edge adds it only for requests through Access),
// so it cannot forge a write. Body is size-capped and must parse as JSON.
const PREFS_MAX_BYTES = 16384;
function prefsKey(email) {
  return 'prefs/' + String(email).toLowerCase().replace(/[^a-z0-9._@+-]/g, '_') + '.json';
}
async function handlePrefs(request, env, ctx) {
  const payload = await verifyAccessJwt(request.headers.get('Cf-Access-Jwt-Assertion'), ctx, getIdentity(env));
  if (!payload || !payload.email) return noStore(json({}, 200));  // unauthenticated -> empty prefs
  const key = prefsKey(payload.email);
  if (request.method === 'GET') {
    return noStore(await r2Serve(env, key, json({}, 200)));
  }
  if (request.method === 'PUT' || request.method === 'POST') {
    if (!env.DATA) return noStore(json({ ok: false, error: 'no store' }, 200));
    const text = await request.text();
    if (text.length > PREFS_MAX_BYTES) return noStore(json({ ok: false, error: 'too large' }, 413));
    try { JSON.parse(text); } catch (e) { return noStore(json({ ok: false, error: 'bad json' }, 400)); }
    await env.DATA.put(key, text, { httpMetadata: { contentType: 'application/json' } });
    return noStore(json({ ok: true }, 200));
  }
  return noStore(json({ ok: false }, 405));
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    const allowedHosts = getIdentity(env).allowedHosts;
    if (!allowedHosts.includes(url.hostname)) {
      return new Response('This site is private.' + (allowedHosts[0] ? (' Access it at https://' + allowedHosts[0]) : ''), {
        status: 403,
        headers: { 'Content-Type': 'text/plain' }
      });
    }

    const path = url.pathname;

    // Public paldb.cc proxies (not player-specific).
    if (path === '/api/palmaptile') return handleTile(url, ctx);
    if (path === '/api/palspawn') return handleSpawn(url, ctx);

    // Per-user UI preferences (read/write, keyed by the verified Access email).
    if (path === '/api/prefs') return handlePrefs(request, env, ctx);

    const scope = await resolveScope(request, env, ctx);  // 'all' | <guid> | null

    // The physical scoped/admin data locations are internal only. Match
    // case-insensitively so a request like /data/ALL/... can't slip past the guard.
    const lpath = path.toLowerCase();
    if (lpath.startsWith('/data/all/') || lpath.startsWith('/data/by-player/')) {
      return new Response('forbidden', { status: 403 });
    }

    // Pals + Paldeck + Eggs are scoped per authenticated user, served from R2.
    // R2 keys mirror the old static layout minus the /data/ prefix:
    //   admin  -> all/<name>           (e.g. all/pals.json)
    //   scoped -> by-player/<guid>/<name>
    if (path === '/data/pals.json' || path === '/data/paldeck.json' || path === '/data/eggs.json') {
      const name = path.slice('/data/'.length);
      if (scope === 'all') return noStore(await r2Serve(env, 'all/' + name, emptyData(name)));
      if (scope) return noStore(await r2Serve(env, 'by-player/' + scope + '/' + name, emptyData(name)));
      return noStore(emptyData(name));
    }

    // Per-player effigy collection: only your own (admins: any), served from R2.
    if (path.startsWith('/data/player-effigies/')) {
      const g = path.slice('/data/player-effigies/'.length).replace(/\.json$/i, '');
      if (scope === 'all' || (scope && g.toLowerCase() === scope.toLowerCase())) {
        // R2 keys use the save's canonical UPPERCASE guid; normalize so a differently
        // cased URL still resolves (a scoped user is pinned to their own canonical guid).
        const keyGuid = (scope === 'all') ? g.toUpperCase() : scope;
        return noStore(await r2Serve(env, 'player-effigies/' + keyGuid + '.json', json({ collected: [] }, 200)));
      }
      return noStore(json({ collected: [] }, 200));
    }

    // Per-player journal/diary note collection: same scoping as player-effigies above.
    if (path.startsWith('/data/player-notes/')) {
      const g = path.slice('/data/player-notes/'.length).replace(/\.json$/i, '');
      if (scope === 'all' || (scope && g.toLowerCase() === scope.toLowerCase())) {
        const keyGuid = (scope === 'all') ? g.toUpperCase() : scope;
        return noStore(await r2Serve(env, 'player-notes/' + keyGuid + '.json', json({ collected: [] }, 200)));
      }
      return noStore(json({ collected: [] }, 200));
    }

    // Per-player bounty-boss (named Alpha) defeat state: same scoping as player-effigies above.
    if (path.startsWith('/data/player-bounties/')) {
      const g = path.slice('/data/player-bounties/'.length).replace(/\.json$/i, '');
      if (scope === 'all' || (scope && g.toLowerCase() === scope.toLowerCase())) {
        const keyGuid = (scope === 'all') ? g.toUpperCase() : scope;
        return noStore(await r2Serve(env, 'player-bounties/' + keyGuid + '.json', json({ collected: [] }, 200)));
      }
      return noStore(json({ collected: [] }, 200));
    }

    // Per-player NPC talked-to state: same scoping as player-effigies above.
    if (path.startsWith('/data/player-npcs/')) {
      const g = path.slice('/data/player-npcs/'.length).replace(/\.json$/i, '');
      if (scope === 'all' || (scope && g.toLowerCase() === scope.toLowerCase())) {
        const keyGuid = (scope === 'all') ? g.toUpperCase() : scope;
        return noStore(await r2Serve(env, 'player-npcs/' + keyGuid + '.json', json({ collected: [] }, 200)));
      }
      return noStore(json({ collected: [] }, 200));
    }

    // Per-player Wanted Fugitive defeat state: same scoping as player-effigies above.
    if (path.startsWith('/data/player-fugitives/')) {
      const g = path.slice('/data/player-fugitives/'.length).replace(/\.json$/i, '');
      if (scope === 'all' || (scope && g.toLowerCase() === scope.toLowerCase())) {
        const keyGuid = (scope === 'all') ? g.toUpperCase() : scope;
        return noStore(await r2Serve(env, 'player-fugitives/' + keyGuid + '.json', json({ collected: [] }, 200)));
      }
      return noStore(json({ collected: [] }, 200));
    }

    // Per-player Eagle Statue unlock state: same scoping as player-effigies above.
    if (path.startsWith('/data/player-eagles/')) {
      const g = path.slice('/data/player-eagles/'.length).replace(/\.json$/i, '');
      if (scope === 'all' || (scope && g.toLowerCase() === scope.toLowerCase())) {
        const keyGuid = (scope === 'all') ? g.toUpperCase() : scope;
        return noStore(await r2Serve(env, 'player-eagles/' + keyGuid + '.json', json({ collected: [] }, 200)));
      }
      return noStore(json({ collected: [] }, 200));
    }

    // Per-player live world position (Translation/Rotation): same scoping as
    // player-effigies above. A scoped (non-admin) user can only ever request their own
    // guid anyway (the public page never shows anyone else's), but the Worker enforces
    // it server-side regardless, same as every other per-player route.
    if (path.startsWith('/data/player-location/')) {
      const g = path.slice('/data/player-location/'.length).replace(/\.json$/i, '');
      if (scope === 'all' || (scope && g.toLowerCase() === scope.toLowerCase())) {
        const keyGuid = (scope === 'all') ? g.toUpperCase() : scope;
        return noStore(await r2Serve(env, 'player-location/' + keyGuid + '.json', json({}, 200)));
      }
      return noStore(json({}, 200));
    }

    // Server settings: same redacted view for every authenticated user, from R2.
    // Not per-user, so it need not be no-store, but it still requires having passed
    // Access (host guard above).
    if (path === '/data/settings.json') {
      return r2Serve(env, 'settings.json', json({ active: {}, defaults: {} }, 200));
    }

    // Data freshness marker ({ savedAt, syncedAt }), written by sync_public_data.ps1
    // on each R2 sync. Same for everyone; the page uses it to show the true data age
    // (the shell's baked generation time is wrong now that data updates without a
    // shell deploy). Empty object fallback -> page falls back to its baked stamp.
    if (path === '/data/meta.json') {
      return r2Serve(env, 'meta.json', json({}, 200));
    }

    // Recent server broadcasts for the chat banner. Same for everyone (broadcasts aren't
    // per-user), mirrored from the admin feed by push_server_messages.ps1. no-store so the
    // banner reflects new messages within a poll instead of a cached copy. Empty-array
    // fallback before the first push (or if the binding is absent).
    if (path === '/data/server-messages.json') {
      return noStore(await r2Serve(env, 'server-messages.json', json([], 200)));
    }

    // Everything else: index.html, portraits, icons, css, and the shared STATIC data
    // (data/effigies.json, data/pal-species.json) that ships with the Pages shell.
    // All require having passed Access (host guard above).
    return env.ASSETS.fetch(request);
  }
};
