# Hosting

How `api.saathi.dev` is put together, and the decisions behind it. The rationale used to live in a
`"//"` key inside `vercel.json`; Vercel's schema validation rejects unknown top-level properties
outright (`Invalid vercel.json - should NOT have additional property "//"`), so it lives here
instead. **`vercel.json` cannot carry comments of any kind.**

## The shape

Three tiers, matching the three provider modes — and the point is that most users touch none of it:

| Mode | Infrastructure |
|---|---|
| `local` *(default)*, `openai`, `anthropic`, `sarvam` | **none.** The client talks to the model directly. |
| `hosted` | a stateless Vercel Function on `api.saathi.dev`, plus Postgres for accounts |
| self-hosted | `selfhost/` — the same container, on your own box |

Because `local` is the default and own-key modes bypass the backend entirely, hosted traffic is the
*minority* path. That is a deliberate cost position, not an accident.

## `vercel.json`, and three things that were found by running it

All three were found with `vercel dev` / `vercel build` against this config, not read in docs.

- **`outputDirectory` must not be the repository root.** Vercel's filesystem handler runs *before*
  rewrites, so with the root as the static directory `GET /api/index.ts` returns the function's own
  source over HTTP — and so does every other file. It points at an empty `public/` on purpose.
  There is no static content here; every path is rewritten onto the function.
- **The request path travels in a `__path` query parameter.** A rewrite replaces the path, so a
  function reached by rewrite cannot see what the caller asked for. Vercel's own catch-all
  (`api/[...route].ts`) does not help: outside a framework the `api/` directory compiles
  `[...route]` to a *single* path segment, so `/api/a/b` never reaches the function at all.
- **The function runs on the `edge` runtime.** `hono/vercel` returns a web-standard
  `(Request) => Response`, which is the edge signature; on the `nodejs` runtime Vercel expects
  `(req, res)` and the function simply *hangs* rather than erroring. If the backend ever needs a
  Node built-in, `api/index.ts` is the file that has to change.

The build command is a gate rather than a build: Vercel compiles the function itself, but a deploy
whose generated contract had drifted from the schema would ship a backend whose route list
disagrees with the clients generated from the same file.

## Environment

| Variable | What happens without it |
|---|---|
| `SAATHI_SUPABASE_URL` + `SAATHI_SUPABASE_SECRET_KEY` | no accounts database; posture falls back to `SAATHI_TOKENS`, or `closed` |
| `SAATHI_REALTIME_KEY` | `/realtime/session` answers 501 "this backend does not offer hosted voice" — a valid posture, not a broken one |
| `SAATHI_TOKENS` | ignored when an accounts database is configured; it wins when both are set |
| `SAATHI_ALLOW_ANONYMOUS` | only consulted when there is neither a token list nor a database |

**The secret key must be the secret (service-role) one.** A publishable key is the key that reaches
browsers, and the database functions are not granted to it, so every call would fail confusingly —
`supabaseFromEnv` rejects one at startup with a clear reason instead.

`/health` reports the resulting posture, so you can see what you actually deployed:

```bash
curl https://api.saathi.dev/health
{"ok":true,"version":"0.8.0","auth":"accounts","voice":"hosted","limits":"per-account daily limit, counted in Postgres (shared across every instance)","trial":"on"}
```

As deployed on 2026-09-16: accounts in Supabase project `qkrkijwdwsclpikjgvcb`, hosted voice on
`gpt-realtime` in the `cedar` voice. Five variables are set, **Production only** — matching how
`SAATHI_SUPABASE_URL` was already scoped, and keeping a live provider key off preview deployments:
`SAATHI_SUPABASE_URL`, `SAATHI_SUPABASE_SECRET_KEY`, `SAATHI_REALTIME_KEY`, `SAATHI_REALTIME_MODEL`,
`SAATHI_REALTIME_VOICE`.

`SAATHI_TOKENS` is deliberately unset. `authPosture` checks a static token list *before* the accounts
database, so setting it would silently bypass the Postgres ledger and every per-account limit with
it — the deploy would still look healthy while enforcing nothing.

What was verified against the live deployment, not assumed:

| Check | Result |
|---|---|
| `/health` posture | `auth: accounts`, `voice: hosted`, contract `0.6.0` |
| A real account token | `POST /realtime/session` → 200 |
| An unknown token | 401 |
| No token at all | 401 |
| The minted grant | `wss://api.openai.com/v1/realtime?model=gpt-realtime`, expires in 600 s |

The last row is the one that matters most: the grant sends the client to **OpenAI**, not back here, so
no audio crosses `api.saathi.dev` even in hosted mode. A grant naming a `saathi.dev` host would mean
every learner's voice was flowing through this backend, which is exactly what minting exists to avoid
— and the macOS client rejects any grant URL that is not `ws`/`wss` before it connects.

## The database

`backend/migrations/0001_accounts_and_voice_ledger.sql`, applied with psql:

```bash
psql "$SAATHI_DATABASE_URL" -f backend/migrations/0001_accounts_and_voice_ledger.sql
```

Two things worth knowing before connecting:

- Supabase's direct database host is **IPv6-only** now. If your network has no IPv6, psql does not
  fail — it hangs. Use the connection pooler host instead: for the hosted project that is
  `aws-0-ap-northeast-1.pooler.supabase.com`, port 5432, user `postgres.<project ref>` (not
  `postgres`). The region is not written anywhere obvious; a wrong one answers
  `tenant/user … not found` at once, so trying them is cheap.
- A password containing `#` breaks a connection *string* silently — `#` begins a URI fragment, so
  everything after it is discarded and you get an authentication failure that looks like a wrong
  password. Percent-encode it (`%23`, and `%21` for `!`), or sidestep the problem with `PGPASSWORD`.

Issuing an account and a token:

```sql
insert into saathi.accounts (email, label, plan, daily_voice_sessions)
values ('someone@example.com', 'invited', 'invited', 20) returning id;

-- Generate the token locally; store only its digest. The plaintext is shown once and never again.
insert into saathi.tokens (token_sha256, account_id, label)
values (encode(sha256('<the token>'::bytea), 'hex'), '<account id>', 'their laptop');
```

Revoking one is `update saathi.tokens set revoked_at = now() where token_sha256 = …`. The functions
treat unknown and revoked identically, on purpose: telling them apart tells an attacker which of
their guesses was once real.

## Trials

A trial is how a first-run Mac gets to talk to Saathi before anyone has an account: an ordinary
`saathi.accounts` row, flagged `trial`, allowed **3 voice sessions a day**, that stops working
**7 days** after it was made. `POST /trial` with `{"device": "<uuid v4>"}` hands back a token; the
client generates the device id once and keeps it in `shell.json`.

What bounds it, all of it in one Postgres function (`saathi_issue_trial`), because a counter in a
serverless process is one quota per warm isolate:

- **One account per device.** The same device asking again inside the seven days gets the same
  account and a fresh token (the old one is revoked). After the seven days it is refused, not
  re-enrolled — a reinstall does not mint a second allowance.
- **Five asks per network per UTC day**, counting every ask, answered 429. A refused ask creates
  nothing.
- **Nothing identifying is stored.** Tokens are SHA-256 digests, as everywhere else. The source
  address is hashed by the backend before it reaches the database; `saathi.trial_requests` holds a
  digest, a date and a count, and is prunable by date.

It needs the accounts database and nothing else — no new environment variable. Turning it on is
applying the migration:

```bash
psql -v ON_ERROR_STOP=1 -f backend/migrations/0002_trials.sql
psql -v ON_ERROR_STOP=1 -f backend/migrations/0002_verify.sql   # asserts, then rolls back
```

`0002_trials.sql` is re-runnable. `0002_verify.sql` changes nothing: it runs every rule above inside
a transaction it rolls back, and prints `0002: all assertions passed`.

`/health` gains `"trial": "on" | "off"`. It is a property of what was wired in, like `auth`: a
backend without the database answers `off`, and `501 this backend does not offer trials` on the
route — the same code, for the same reason, as hosted voice without a provider key.

An expired trial's token is refused with `your Saathi trial has ended` rather than the
`not authorised` an unknown token gets: the caller holds something that was real, and that sentence
is one they can act on.

Ending a trial early:

```sql
update saathi.accounts set suspended_at = now() where device_id = '<the device id>';
```

### Verification

| What | When | Result |
|---|---|---|
| `0002_trials.sql` + `0002_verify.sql` on a local Postgres 17 | 2026-09-21 | all assertions passed; applying twice is clean; 8 concurrent first asks from one device → 1 account, 1 live token |
| `0002_trials.sql` + `0002_verify.sql` on the hosted database | 2026-09-21 | all assertions passed; the existing account and its token untouched; 0 trial rows left behind |
| `/health` on api.saathi.dev after `vercel --prod` | 2026-09-21 | `version 0.8.0`, `auth accounts`, `voice hosted`, `trial on` |
| `POST /trial` with a bad device | 2026-09-21 | 400 `device must be a version 4 UUID`; spends nothing |
| One real trial, end to end | 2026-09-21 | token issued, 3 a day, expiry 7 days out; `/session` with it → 200; same device again → a fresh token, and the first one → 401. The test account and its rate-limit row were deleted afterwards |
| `POST /skills/create` with no token | 2026-09-21 | 401 — the route is live in production (before this deploy it did not exist there) |

Deploys are **not** triggered by pushing `main`: the Vercel project is not connected to the
repository. Production changes when someone runs `npx vercel --prod` from a clean checkout. For a
few seconds after a deploy an old instance can still answer; a route that is new in that deploy may
404 once before it is there.
