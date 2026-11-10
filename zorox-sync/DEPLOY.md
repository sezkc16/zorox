# Deploy the ZoroX Sync Worker (5 min, phone-friendly)

Same pattern as the converter's `toji-license-server` Worker. No terminal
needed — everything happens in the Cloudflare dashboard.

## Step 1 — Create the KV namespace

1. Safari → **dash.cloudflare.com** → log in.
2. Left menu → **Workers & Pages** → **KV** (in the left menu under Workers).
3. Tap **Create a namespace** → name it **`zorox-sync`** → **Add**.
   (The namespace name is just a label; the binding name in Step 3 is what
   the code reads.)

## Step 2 — Create the Worker

1. Left menu → **Workers & Pages** → **Create** → **Create Worker**.
2. Name it **`zorox-sync`** → **Deploy** (it deploys a hello-world Worker
   first — that is fine, it gets replaced next).
3. Tap the Worker name to open it → **Edit Code** → select all → delete →
   paste the whole `worker.js` from this folder → **Deploy**.

## Step 3 — Bind the KV namespace

Same Worker → **Settings → Variables → KV Namespace Bindings** → **Add binding**:

- **Variable name:** `ZOROX_SYNC` (exactly this — the code reads `env.ZOROX_SYNC`)
- **KV namespace:** pick the `zorox-sync` namespace from Step 1.

Tap **Deploy** again (or Save) so the binding takes effect.

## Step 4 — Set the two secrets

Same Worker → **Settings → Variables → Add secret** (NOT a plain variable
— secrets are hidden):

- **`TOKEN_SECRET`** — a long random string, e.g. 64 hex chars.
  Generate one: `openssl rand -hex 32` (or any password generator).
- **`PASSWORD_PEPPER`** — a DIFFERENT long random string. This one is mixed
  into every password hash: **do not change it later** — changing it locks
  out every account, because stored passwords would no longer verify.

Deploy again after adding the secrets.

## Step 5 — Put the Worker URL into the app

The Worker URL looks like:

```
https://zorox-sync.<your-subdomain>.workers.dev
```

(Find it on the Worker's page, top right — tap the URL to copy it.)

In the app: **Settings → Accounts → ZoroX Account → "Sync server"** →
paste the URL → Save. The account screen then says "Cloud sync ready"
instead of "Cloud sync not set up yet".

Until the URL is set, the app still works: **Export backup / Import backup**
in the same ZoroX Account section restores everything without any server.

## Test after deploying (2 min)

1. Open the Worker's URL in Safari — it must show
   `{"ok":true,"service":"zorox-sync","version":1}`.
2. In the app, create an account (ZoroX Account → Create account).
   Log out, log back in with the same email/password — it must work.
3. Watch something for a few seconds, then **Sync now**.
4. Delete the app, reinstall, log in with the same account — the title
   must be back in Continue Watching with its position, and the installed
   plugins must come back.
5. Test Export backup too: Export → save the file somewhere → Import it —
   the counts in the confirmation must match what was exported.

## If something fails

- **"Server misconfigured (secrets missing)"** — one of the two secrets in
  Step 4 is missing or was added as a plain variable instead of a secret.
- **"Session expired. Log in again."** right after logging in — the KV
  binding in Step 3 is missing or named something other than `ZOROX_SYNC`.
- **"Cloud sync not set up yet"** in the app — the Worker URL in Step 5 is
  empty or does not start with `https://`.
- **Register says "already exists" for a new email** — the email was already
  registered (emails are lower-cased; `You@x.com` and `you@x.com` are the
  same account). Log in instead.

## Owner notes

- There is no admin panel and no email verification. Anyone with the Worker
  URL can create an account. That is fine for personal use; if it is ever
  abused, delete the bad `user:<email>` / `backup:<email>` entries in the
  dashboard (Workers & Pages → KV → `zorox-sync` → browse entries).
- If `TOKEN_SECRET` leaks, set a new one: all sessions end at once and
  everyone logs in again. Passwords stay safe.
- Backups are capped at 5 MB per upload. A normal backup (history +
  library + plugin lists) is a few hundred KB at most.
