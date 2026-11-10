// ZoroX Sync Worker — zorox-sync
// ================================
// Cloud backup for a ZoroX account: watch history, installed plugins and
// library, restored after an uninstall/reinstall or on another device.
//
// Deploy: dashboard only, no wrangler needed (see DEPLOY.md).
//   KV binding:  ZOROX_SYNC   (one KV namespace, created in the dashboard)
//   Secrets:     TOKEN_SECRET, PASSWORD_PEPPER  (Settings -> Variables -> Add secret)
//
// Endpoints (all JSON):
//   GET  /                        health check
//   POST /register   {email, password}            -> {ok, token, email}
//   POST /login      {email, password}            -> {ok, token, email}
//   POST /sync       {token, backup}              -> {ok, updatedAt}
//   GET  /backup?token=...                        -> {ok, backup, updatedAt}
//   POST /logout     {token}                      -> {ok}
//
// Security:
//   - Passwords are NEVER stored. Each account keeps a PBKDF2-SHA256 hash
//     (100,000 iterations, per-user random salt) of pepper + password.
//   - Session tokens are HMAC-SHA256, 24h, format v1.<b64(payload)>.<b64(sig)>
//     with payload "email|sessionId|exp". The session id is also recorded in
//     KV, so /logout really ends the session (delete the KV entry).
//   - register/login are rate limited: 60 attempts per minute per IP.
//   - One KV entry per user:  user:<email>   (account record)
//                            backup:<email> (the backup JSON + updatedAt)
//                            session:<id>   (live session, 24h TTL)
//   - KV values cap at 25 MB: a watch-history backup is far below that.
//   - Passwords travel over HTTPS only; the app refuses a non-HTTPS URL.

const SESSION_TTL_SECONDS = 24 * 60 * 60; // 24h
const PBKDF2_ITERATIONS = 100000;
const MIN_PASSWORD_LENGTH = 8;
const MAX_BACKUP_BYTES = 5 * 1024 * 1024; // 5 MB sanity cap, KV allows 25 MB
const RATE_LIMIT_PER_MINUTE = 60;

// --- helpers ---------------------------------------------------------------

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "Content-Type",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    },
  });
}

function b64urlEncode(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64urlDecode(str) {
  str = str.replace(/-/g, "+").replace(/_/g, "/");
  while (str.length % 4) str += "=";
  const bin = atob(str);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

function randomHex(bytes = 16) {
  const b = new Uint8Array(bytes);
  crypto.getRandomValues(b);
  return [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(text) {
  const hash = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(text),
  );
  return [...new Uint8Array(hash)]
    .map((x) => x.toString(16).padStart(2, "0"))
    .join("");
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function normalizeEmail(raw) {
  return typeof raw === "string" ? raw.trim().toLowerCase() : "";
}

// --- rate limiting (register/login only) ------------------------------------

async function rateLimited(env, ip) {
  const key = `rl:${ip}`;
  const raw = await env.ZOROX_SYNC.get(key);
  const count = raw ? parseInt(raw, 10) || 0 : 0;
  if (count >= RATE_LIMIT_PER_MINUTE) return true;
  // Best effort: a race here only ever lets one extra attempt through.
  await env.ZOROX_SYNC.put(key, String(count + 1), { expirationTtl: 60 });
  return false;
}

// --- passwords ---------------------------------------------------------------

async function hashPassword(env, password, saltHex) {
  const salt = new Uint8Array(
    saltHex.match(/../g).map((h) => parseInt(h, 16)),
  );
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(`${env.PASSWORD_PEPPER}:${password}`),
    "PBKDF2",
    false,
    ["deriveBits"],
  );
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", salt, iterations: PBKDF2_ITERATIONS, hash: "SHA-256" },
    key,
    256,
  );
  return [...new Uint8Array(bits)]
    .map((x) => x.toString(16).padStart(2, "0"))
    .join("");
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// --- sessions -----------------------------------------------------------------

async function signToken(secret, email, sessionId, exp) {
  const payload = `${email}|${sessionId}|${exp}`;
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    cryptoKey,
    new TextEncoder().encode(payload),
  );
  return `v1.${b64urlEncode(new TextEncoder().encode(payload))}.${b64urlEncode(new Uint8Array(sig))}`;
}

/// Returns the session's email, or null. Checks the HMAC, the expiry, and
/// that the session still exists in KV (so /logout really ends it).
async function verifyToken(env, token) {
  try {
    if (!token || typeof token !== "string") return null;
    const parts = token.split(".");
    if (parts.length !== 3 || parts[0] !== "v1") return null;
    const payload = new TextDecoder().decode(b64urlDecode(parts[1]));
    const [email, sessionId, expStr] = payload.split("|");
    const exp = parseInt(expStr, 10);
    if (!email || !sessionId || !exp || exp * 1000 < Date.now()) return null;
    const expected = await signToken(env.TOKEN_SECRET, email, sessionId, exp);
    if (!timingSafeEqual(expected, token)) return null;
    const live = await env.ZOROX_SYNC.get(`session:${sessionId}`);
    if (live !== email) return null;
    return { email, sessionId, exp };
  } catch {
    return null;
  }
}

async function issueSession(env, email) {
  const sessionId = randomHex(16);
  const exp = Math.floor(Date.now() / 1000) + SESSION_TTL_SECONDS;
  const token = await signToken(env.TOKEN_SECRET, email, sessionId, exp);
  await env.ZOROX_SYNC.put(`session:${sessionId}`, email, {
    expirationTtl: SESSION_TTL_SECONDS,
  });
  return token;
}

// --- handlers ------------------------------------------------------------------

async function handleRegister(env, body, ip) {
  if (!env.TOKEN_SECRET || !env.PASSWORD_PEPPER) {
    return json(
      { ok: false, error: "Server misconfigured (secrets missing)." },
      500,
    );
  }
  if (await rateLimited(env, ip)) {
    return json(
      { ok: false, error: "Too many attempts. Try again in a minute." },
      429,
    );
  }
  const email = normalizeEmail(body?.email);
  const password = typeof body?.password === "string" ? body.password : "";
  if (!EMAIL_RE.test(email)) {
    return json({ ok: false, error: "Enter a valid email address." }, 400);
  }
  if (password.length < MIN_PASSWORD_LENGTH) {
    return json(
      { ok: false, error: "Password must be at least 8 characters." },
      400,
    );
  }
  const existing = await env.ZOROX_SYNC.get(`user:${email}`);
  if (existing) {
    return json(
      { ok: false, error: "An account with this email already exists." },
      409,
    );
  }
  const salt = randomHex(16);
  const hash = await hashPassword(env, password, salt);
  await env.ZOROX_SYNC.put(
    `user:${email}`,
    JSON.stringify({
      salt,
      hash,
      iterations: PBKDF2_ITERATIONS,
      created: Date.now(),
    }),
  );
  const token = await issueSession(env, email);
  return json({ ok: true, token, email }, 201);
}

async function handleLogin(env, body, ip) {
  if (!env.TOKEN_SECRET || !env.PASSWORD_PEPPER) {
    return json(
      { ok: false, error: "Server misconfigured (secrets missing)." },
      500,
    );
  }
  if (await rateLimited(env, ip)) {
    return json(
      { ok: false, error: "Too many attempts. Try again in a minute." },
      429,
    );
  }
  const email = normalizeEmail(body?.email);
  const password = typeof body?.password === "string" ? body.password : "";
  if (!EMAIL_RE.test(email) || password.length === 0) {
    // Same message either way: do not reveal whether the email exists.
    return json({ ok: false, error: "Wrong email or password." }, 401);
  }
  const raw = await env.ZOROX_SYNC.get(`user:${email}`);
  if (!raw) {
    return json({ ok: false, error: "Wrong email or password." }, 401);
  }
  let record;
  try {
    record = JSON.parse(raw);
  } catch {
    return json({ ok: false, error: "Wrong email or password." }, 401);
  }
  const hash = await hashPassword(env, password, record.salt);
  if (!timingSafeEqual(hash, record.hash)) {
    return json({ ok: false, error: "Wrong email or password." }, 401);
  }
  const token = await issueSession(env, email);
  return json({ ok: true, token, email });
}

async function handleSync(env, body) {
  const session = await verifyToken(env, body?.token);
  if (!session) {
    return json(
      { ok: false, error: "Session expired. Log in again." },
      401,
    );
  }
  const backup = body?.backup;
  if (!backup || typeof backup !== "object" || backup.format !== "zorox-backup") {
    return json({ ok: false, error: "That is not a ZoroX backup." }, 400);
  }
  const encoded = JSON.stringify(backup);
  if (new TextEncoder().encode(encoded).length > MAX_BACKUP_BYTES) {
    return json(
      { ok: false, error: "Backup is too large (over 5 MB)." },
      400,
    );
  }
  const updatedAt = Date.now();
  await env.ZOROX_SYNC.put(
    `backup:${session.email}`,
    JSON.stringify({ backup, updatedAt }),
  );
  return json({ ok: true, updatedAt });
}

async function handleBackup(env, request) {
  const token = new URL(request.url).searchParams.get("token") ?? "";
  const session = await verifyToken(env, token);
  if (!session) {
    return json(
      { ok: false, error: "Session expired. Log in again." },
      401,
    );
  }
  const raw = await env.ZOROX_SYNC.get(`backup:${session.email}`);
  if (!raw) {
    return json({ ok: false, error: "No backup saved yet." }, 404);
  }
  let stored;
  try {
    stored = JSON.parse(raw);
  } catch {
    return json({ ok: false, error: "Saved backup is damaged." }, 500);
  }
  return json({ ok: true, backup: stored.backup, updatedAt: stored.updatedAt });
}

async function handleLogout(env, body) {
  const session = await verifyToken(env, body?.token);
  if (session) {
    await env.ZOROX_SYNC.delete(`session:${session.sessionId}`);
  }
  // Always ok: logging out must work even with an expired token.
  return json({ ok: true });
}

// --- router --------------------------------------------------------------------

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (request.method === "OPTIONS") {
        return json({ ok: true });
      }
      if (request.method === "GET" && url.pathname === "/") {
        return json({ ok: true, service: "zorox-sync", version: 1 });
      }
      if (request.method === "POST" && url.pathname === "/register") {
        return await handleRegister(
          env,
          await request.json().catch(() => null),
          request.headers.get("CF-Connecting-IP") ?? "unknown",
        );
      }
      if (request.method === "POST" && url.pathname === "/login") {
        return await handleLogin(
          env,
          await request.json().catch(() => null),
          request.headers.get("CF-Connecting-IP") ?? "unknown",
        );
      }
      if (request.method === "POST" && url.pathname === "/sync") {
        return await handleSync(env, await request.json().catch(() => null));
      }
      if (request.method === "GET" && url.pathname === "/backup") {
        return await handleBackup(env, request);
      }
      if (request.method === "POST" && url.pathname === "/logout") {
        return await handleLogout(env, await request.json().catch(() => null));
      }
      return json({ ok: false, error: "Not found." }, 404);
    } catch (e) {
      return json({ ok: false, error: `Server error: ${e.message}` }, 500);
    }
  },
};
