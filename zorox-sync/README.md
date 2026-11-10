# ZoroX Sync Worker — README

Cloud backup for a ZoroX account: watch history, installed plugins and
library, restored after an uninstall/reinstall or on another device.

## What lives here

| File | What it is |
|---|---|
| `worker.js` | The whole Worker. Single file, no npm dependencies. |
| `DEPLOY.md` | Exact dashboard steps (phone-friendly). Start here. |
| `wrangler.toml` | Optional: only for deploying from a terminal. |

## Setup summary (full steps in DEPLOY.md)

1. **KV binding name: `ZOROX_SYNC`** — one KV namespace, bound to the Worker
   under exactly that name. The Worker reads `env.ZOROX_SYNC`; a different
   binding name means the Worker sees no storage at all.
2. **Secrets** (Settings → Variables → Add secret, never plain variables):
   - `TOKEN_SECRET` — long random string, used to sign session tokens.
     Generate: `openssl rand -hex 32` (or any password generator).
   - `PASSWORD_PEPPER` — a DIFFERENT long random string, mixed into every
     password hash. Changing it later locks out every account (passwords
     would no longer verify), so keep it safe and do not rotate it casually.
3. **Worker URL** goes into the app: Settings → Accounts → ZoroX Account →
   "Sync server". It must start with `https://` and look like
   `https://zorox-sync.<your-subdomain>.workers.dev`.

## Endpoints

| Method | Path | Body / query | Returns |
|---|---|---|---|
| GET | `/` | — | `{ok, service: "zorox-sync", version: 1}` |
| POST | `/register` | `{email, password}` | `{ok, token, email}` (201) |
| POST | `/login` | `{email, password}` | `{ok, token, email}` |
| POST | `/sync` | `{token, backup}` | `{ok, updatedAt}` |
| GET | `/backup?token=...` | — | `{ok, backup, updatedAt}` (404 when no backup yet) |
| POST | `/logout` | `{token}` | `{ok}` |

## Security model

- **Passwords are never stored.** Each account keeps a PBKDF2-SHA256 hash
  (100,000 iterations, per-user random salt) of `pepper + password`.
  The pepper is a Worker secret; without it, a leaked KV dump cannot be
  brute-forced offline either (the attacker would still need the pepper).
- **Sessions** are HMAC-SHA256 tokens, 24h, `v1.<payload>.<signature>`.
  The session id is also recorded in KV, so `/logout` really ends the
  session (the KV entry is deleted) — unlike a purely stateless token.
- **Rate limiting:** register/login allow 60 attempts per minute per IP.
- **One KV entry per user** (`user:<email>` for the account,
  `backup:<email>` for the backup blob). Backups are capped at 5 MB
  (KV allows 25 MB; a real watch-history backup is far below that).

## Honest limits

- This is a personal sync service, not a bank. Anyone with the Worker URL
  can create an account; there is no email verification and no admin panel.
  If abuse ever becomes a problem, add a registration allow-list or turn
  the Worker off — the app keeps working, Export/Import still restores
  everything, and no data is lost.
- If `TOKEN_SECRET` leaks, generate a new one: every session token stops
  working at once and everyone just logs in again. Passwords stay safe
  (they are hashed with the pepper, not the token secret).
- If `PASSWORD_PEPPER` leaks, every password hash becomes brute-forceable
  offline. Rotate it only together with a password reset for all accounts
  (there is no reset endpoint yet — accounts would need to re-register).
- The app never sends the password anywhere except this Worker over HTTPS.
  It never stores the password on the device — only the session token, in
  the platform keychain/keystore.
