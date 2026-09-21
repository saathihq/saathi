# Slice 3 — Trial Tokens and the Onboarding Config Fields: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A first-run Mac can ask the hosted backend for a seven-day, three-sessions-a-day trial token with no account, and `shell.json` can hold everything onboarding will learn about the learner.

**Architecture:** The contract schema gains a `bool` config type, eight optional config fields and one unauthenticated route, `POST /trial`. The backend route is a thin validator over a new optional `SessionLedger.issueTrial`; all the state — one account per device, the expiry, the per-network rate limit — lives in one `SECURITY DEFINER` Postgres function, so check-and-spend stay a single statement exactly as migration 0001 does it. The macOS side gets a `TrialClient` that owns the device id and persists the token through the existing `ConfigurationStore`.

**Tech Stack:** Node ≥ 22, TypeScript, Hono, Vitest (`backend/`); `contract/generate.mjs` (plain Node); Postgres via Supabase PostgREST RPC; Swift 6 / SwiftPM / XCTest (`macos/Saathi`).

**Spec:** `docs/superpowers/specs/2026-09-15-app-shell-and-onboarding-design.md` — sections "Trial tokens", "Contract additions", "Testing" (Backend bullet) and build-order item 3. Read `docs/HOSTING.md` and `backend/migrations/0001_accounts_and_voice_ledger.sql` before Task 2.

## Global Constraints

- Trial allowance is exactly `daily_voice_sessions = 3` and `expires_at = now() + 7 days` (spec, "Trial tokens").
- Rate limit is exactly five trial requests per source address per UTC day, counted in Postgres, answered with HTTP 429.
- The same device asking again inside the expiry gets the **same account** and a fresh token; a reinstall must not mint a second allowance. After expiry the device is refused, not re-enrolled.
- Tokens are stored as SHA-256 hex only. The plaintext exists in the HTTP response and nowhere else. Source addresses are stored hashed too.
- Nothing in the `saathi` schema is reachable over PostgREST; the only surface is `SECURITY DEFINER` functions in `public`, executable by `service_role` only (pattern of migration 0001).
- Config fields are all optional. `npm run check:contract` and `scripts/check-parity.sh` must keep passing; CLI output does not change.
- **Deviation from the spec, decided here:** the spec says a backend without an accounts ledger answers `404` on `/trial`. The test `routes match the contract` in `backend/test/app.test.ts` requires every declared route to answer non-404 on every posture, and `/realtime/session` already sets the precedent of `501` for "this deployment does not offer that". So `/trial` without a ledger answers **501**, and Task 3 amends the spec sentence.
- Commit messages in this repo are full sentences describing the change, no `feat:` prefixes. End every commit message with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Never run `swift test` with `SAATHI_AUDIO_TESTS=1`; the default run is silent and must stay so.
- `dotnet` is not installed on this Mac. The C# file is regenerated and committed, but Windows tests cannot be run here; say so in the hand-off rather than claiming them.

## File Structure

| File | Responsibility |
|---|---|
| `contract/schema/saathi.json` | Source of truth: new config fields, `/trial` route, version `0.8.0` |
| `contract/generate.mjs` | Learns the `bool` config type for Swift, C#, TypeScript |
| `contract/fixtures/config.json` | Shared fixture gains every new field |
| `backend/migrations/0002_trials.sql` | Columns, rate-limit table, `saathi_issue_trial`, expiry checks in the two existing functions |
| `backend/migrations/0002_verify.sql` | Assertions run inside a rolled-back transaction |
| `backend/src/trial.ts` | **New.** Device validation, token minting, source hashing, the route handler |
| `backend/src/realtime.ts` | `SessionLedger.issueTrial?`, Supabase implementation, exported `sha256Hex` |
| `backend/src/app.ts` | Mounts `/trial`, `/health` gains `trial` |
| `backend/test/trial.test.ts` | **New.** Route and ledger tests |
| `macos/Saathi/Sources/SaathiKit/TrialClient.swift` | **New.** Device id, the request, persisting the grant |
| `macos/Saathi/Sources/SaathiKit/BackendClient.swift` | `BackendHealth.trial` |
| `macos/Saathi/Tests/SaathiKitTests/TrialClientTests.swift` | **New.** |
| `docs/HOSTING.md` | How to apply 0002, what `/health` now says |

---

### Task 1: The contract learns `bool`, and `shell.json` learns the learner

**Files:**
- Modify: `contract/generate.mjs:112-114` (Swift), `:367-371` (C#), `:506-508` (TypeScript)
- Modify: `contract/schema/saathi.json` (`version`, `config.fields`)
- Modify: `contract/fixtures/config.json`
- Regenerated (do not hand-edit): `macos/Saathi/Sources/SaathiContract/SaathiContract.swift`, `windows/src/Saathi.Contract/SaathiContract.cs`, `backend/src/contract.ts`
- Test: `macos/Saathi/Tests/SaathiKitTests/SaathiKitTests.swift` (`testTheSharedConfigFixtureParses`)
- Test: `windows/tests/Saathi.Core.Tests/SharedFixtureTests.cs`

**Interfaces:**
- Consumes: nothing.
- Produces: `SaathiConfiguration` (Swift) with new optional properties `name: String?`, `colour: String?`, `tone: Tone?`, `pace: Pace?`, `firstGoal: String?`, `onboarded: Bool?`, `deviceId: String?`, `startAtLogin: Bool?`. Task 4 reads and writes `deviceId` and `token`.

- [ ] **Step 1: Write the failing test.** In `SaathiKitTests.swift`, at the end of `testTheSharedConfigFixtureParses`, add:

```swift
        XCTAssertEqual(configuration.name, "Asha")
        XCTAssertEqual(configuration.colour, "teal")
        XCTAssertEqual(configuration.tone, .calm, "an enum config field must parse from its wire spelling")
        XCTAssertEqual(configuration.pace, .slow)
        XCTAssertEqual(configuration.firstGoal, "play the tabla")
        XCTAssertEqual(configuration.onboarded, true, "a bool config field must parse as a bool, not a string")
        XCTAssertEqual(configuration.deviceId, "3f2b8c1e-5a44-4c1b-9d0e-7a6b5c4d3e2f")
        XCTAssertEqual(configuration.startAtLogin, false)
```

- [ ] **Step 2: Run it to see it fail.**

Run: `cd macos/Saathi && swift build --build-tests 2>&1 | grep error | head -3`
Expected: `error: value of type 'SaathiConfiguration' has no member 'name'`

- [ ] **Step 3: Teach the generator `bool`.** In `contract/generate.mjs` replace `swiftConfigType`:

```js
/** Config fields are always optional; only their base type varies. */
function swiftConfigType(f) {
  const base = f.type === "string" ? "String" : f.type === "bool" ? "Bool" : f.type;
  return base + "?";
}
```

In the C# emitter, replace the property line inside `for (const f of schema.config.fields)`:

```js
    const csType = f.type === "string" ? "string" : f.type === "bool" ? "bool" : f.type;
    out.push(`    public ${csType}? ${pascal(f.name)} { get; set; }\n`);
```

In the TypeScript emitter, replace the field line:

```js
    const tsType = f.type === "string" ? "string" : f.type === "bool" ? "boolean" : f.type;
    out.push(`  /** ${f.doc} */\n  ${f.name}?: ${tsType};`);
```

- [ ] **Step 4: Add the fields to the schema.** In `contract/schema/saathi.json` set `"version": "0.8.0"` and append to `config.fields`, after `token`:

```json
      { "name": "name", "type": "string", "optional": true,
        "doc": "What the learner asked to be called. Asked once, in onboarding." },
      { "name": "colour", "type": "string", "optional": true,
        "doc": "The mascot's colour, as a palette name from mascot.json." },
      { "name": "tone", "type": "Tone", "optional": true,
        "doc": "How the learner asked Saathi to sound." },
      { "name": "pace", "type": "Pace", "optional": true,
        "doc": "How fast the learner asked Saathi to go." },
      { "name": "firstGoal", "type": "string", "optional": true,
        "doc": "What the learner said they want to learn or play with first." },
      { "name": "onboarded", "type": "bool", "optional": true,
        "doc": "True once first run has finished. Unset or false means show it." },
      { "name": "deviceId", "type": "string", "optional": true,
        "doc": "A UUID v4 generated once on this machine. Sent to the hosted backend only to ask for a trial, so a reinstall does not mint a second allowance." },
      { "name": "startAtLogin", "type": "bool", "optional": true,
        "doc": "Whether Saathi registered itself as a login item." }
```

- [ ] **Step 5: Extend the shared fixture.** In `contract/fixtures/config.json` add after `"token"`:

```json
  "name": "Asha",
  "colour": "teal",
  "tone": "calm",
  "pace": "slow",
  "firstGoal": "play the tabla",
  "onboarded": true,
  "deviceId": "3f2b8c1e-5a44-4c1b-9d0e-7a6b5c4d3e2f",
  "startAtLogin": false
```

- [ ] **Step 6: Mirror the assertions in the C# fixture test.** In `windows/tests/Saathi.Core.Tests/SharedFixtureTests.cs`, next to the existing `Token` assertion, add:

```csharp
        Assert.Equal("Asha", configuration.Name);
        Assert.Equal("teal", configuration.Colour);
        Assert.Equal(Tone.Calm, configuration.Tone);
        Assert.Equal(Pace.Slow, configuration.Pace);
        Assert.Equal("play the tabla", configuration.FirstGoal);
        Assert.True(configuration.Onboarded);
        Assert.Equal("3f2b8c1e-5a44-4c1b-9d0e-7a6b5c4d3e2f", configuration.DeviceId);
        Assert.False(configuration.StartAtLogin);
```

(Open the file first and match its assertion style and variable name; it cannot be run on this Mac.)

- [ ] **Step 7: Regenerate and verify.**

Run: `npm run generate && npm run check:contract && npm run typecheck && bash scripts/check-parity.sh`
Expected: `contract 0.8.0: generated files are up to date`, typecheck clean, parity passes.

Run: `cd macos/Saathi && swift test 2>&1 | grep -E "error:|failed|Executed 1[0-9]{2}"`
Expected: no `error:`/`failed` lines; the SaathiKit bundle reports 0 failures.

- [ ] **Step 8: Commit.**

```bash
git add contract backend/src/contract.ts macos/Saathi/Sources/SaathiContract macos/Saathi/Tests/SaathiKitTests/SaathiKitTests.swift windows
git commit -m "shell.json can hold what onboarding learns, and the contract can say bool"
```

---

### Task 2: Migration 0002 — one account per device, an expiry, and a rate limit

**Files:**
- Create: `backend/migrations/0002_trials.sql`
- Create: `backend/migrations/0002_verify.sql`

**Interfaces:**
- Consumes: tables and functions of `0001_accounts_and_voice_ledger.sql`.
- Produces: `public.saathi_issue_trial(p_device_id uuid, p_token_sha256 text, p_source_sha256 text) returns jsonb`. Returns `{"ok":true,"expires_at":"<timestamptz>","daily_voice_sessions":3}` or `{"ok":false,"reason":"rate_limited"}` or `{"ok":false,"reason":"expired"}`. Also: `saathi_claim_voice_session` and `saathi_resolve_token` now answer `{"ok":false,"reason":"your Saathi trial has ended"}` for an expired account. Task 3 depends on these exact keys and reason strings.

- [ ] **Step 1: Write the verification script first** (it is this task's failing test). Create `backend/migrations/0002_verify.sql`:

```sql
--
--  0002_verify.sql — assertions for 0002_trials.sql. Changes nothing: it runs in a transaction
--  that is rolled back. Any failed assertion aborts with a message naming what broke.
--
--    psql "$SAATHI_DATABASE_URL" -v ON_ERROR_STOP=1 -f backend/migrations/0002_verify.sql
--
begin;

do $$
declare
    d1 uuid := gen_random_uuid();
    r  jsonb;
    a1 uuid;
    a2 uuid;
    i  int;
begin
    -- A new device gets a trial: 3 a day, 7 days.
    r := public.saathi_issue_trial(d1, 'hash-one', 'net-a');
    assert (r->>'ok')::boolean, 'a new device must be given a trial: ' || r::text;
    assert (r->>'daily_voice_sessions')::int = 3, 'the trial allowance is 3 a day';
    assert (r->>'expires_at')::timestamptz between now() + interval '6 days 23 hours' and now() + interval '7 days 1 hour',
        'the trial lasts 7 days';
    select account_id into a1 from saathi.tokens where token_sha256 = 'hash-one';

    -- The same device again: the same account, a fresh token, the old one revoked.
    r := public.saathi_issue_trial(d1, 'hash-two', 'net-a');
    assert (r->>'ok')::boolean, 'the same device inside the expiry is served again';
    select account_id into a2 from saathi.tokens where token_sha256 = 'hash-two';
    assert a1 = a2, 'a reinstall must not mint a second account';
    assert (select revoked_at is not null from saathi.tokens where token_sha256 = 'hash-one'),
        'the superseded token is revoked';
    assert (public.saathi_resolve_token('hash-two')->>'ok')::boolean, 'the fresh token authenticates';
    assert not (public.saathi_resolve_token('hash-one')->>'ok')::boolean, 'the revoked token does not';

    -- Three claims a day, and the fourth is refused.
    for i in 1..3 loop
        assert (public.saathi_claim_voice_session('hash-two')->>'ok')::boolean, 'claim ' || i || ' of 3';
    end loop;
    assert not (public.saathi_claim_voice_session('hash-two')->>'ok')::boolean, 'the 4th claim is over the limit';

    -- An expired trial: refused everywhere, with a reason that says so, and not re-enrolled.
    update saathi.accounts set expires_at = now() - interval '1 minute' where id = a1;
    assert public.saathi_resolve_token('hash-two')->>'reason' = 'your Saathi trial has ended', 'resolve says the trial ended';
    assert public.saathi_claim_voice_session('hash-two')->>'reason' = 'your Saathi trial has ended', 'claim says the trial ended';
    r := public.saathi_issue_trial(d1, 'hash-three', 'net-b');
    assert r->>'reason' = 'expired', 'an expired device is not given a second trial: ' || r::text;

    -- Five requests per network per day; the sixth is refused before anything is created.
    for i in 1..5 loop
        r := public.saathi_issue_trial(gen_random_uuid(), 'rl-' || i, 'net-c');
        assert (r->>'ok')::boolean, 'request ' || i || ' of 5 from one network';
    end loop;
    r := public.saathi_issue_trial(gen_random_uuid(), 'rl-6', 'net-c');
    assert r->>'reason' = 'rate_limited', 'the 6th request from one network is rate limited: ' || r::text;
    assert not exists (select 1 from saathi.tokens where token_sha256 = 'rl-6'), 'a refused request creates nothing';

    -- An invited account has no expiry and is untouched by any of this.
    assert (select count(*) from saathi.accounts where trial = false and expires_at is not null) = 0,
        'only trials expire';

    raise notice '0002: all assertions passed';
end;
$$;

rollback;
```

- [ ] **Step 2: Run it to see it fail.** (Needs `SAATHI_DATABASE_URL`; see `../SUPABASE.md` and `.env.local`. If it is not available in this session, skip Steps 2 and 4, leave both boxes unchecked, and say so in the hand-off — do not claim the migration verified.)

Run: `set -a; source .env.local; set +a; psql "$SAATHI_DATABASE_URL" -v ON_ERROR_STOP=1 -f backend/migrations/0002_verify.sql`
Expected: `ERROR: function public.saathi_issue_trial(uuid, unknown, unknown) does not exist`

- [ ] **Step 3: Write the migration.** Create `backend/migrations/0002_trials.sql`:

```sql
--
--  0002_trials.sql
--  @saathi/backend
--
--  Trials: an account a first-run Mac can be given without anyone inviting it.
--
--  ── What a trial is ──────────────────────────────────────────────────────────
--  An ordinary `saathi.accounts` row, flagged `trial`, allowed 3 voice sessions a day, that stops
--  working 7 days after it was made. It is keyed by a device id the client generates once, so the
--  same Mac asking again gets the same account and a reinstall does not mint a second allowance.
--
--  ── Why the rate limit is here and not in the function that serves HTTP ──────
--  For the same reason the voice ledger is (see 0001): a serverless deployment has no shared
--  memory, so a counter in the process is one quota per warm isolate. The limit and the insert are
--  one function call, and a refused request creates nothing.
--
--  ── What is stored about where a request came from ───────────────────────────
--  A SHA-256 of the source address and a date. Never the address. The row is useless after its
--  day and can be pruned by date.
--
--  Apply with:
--    psql "$SAATHI_DATABASE_URL" -v ON_ERROR_STOP=1 -f backend/migrations/0002_trials.sql
--  Verify with:
--    psql "$SAATHI_DATABASE_URL" -v ON_ERROR_STOP=1 -f backend/migrations/0002_verify.sql
--

alter table saathi.accounts
    add column if not exists trial      boolean not null default false,
    add column if not exists expires_at timestamptz,
    add column if not exists device_id  uuid;

-- One account per device. Partial, because invited accounts have no device.
create unique index if not exists accounts_device_id_key
    on saathi.accounts (device_id) where device_id is not null;

create table if not exists saathi.trial_requests (
    source_sha256  text not null,
    day            date not null,
    requests       integer not null default 0,
    primary key (source_sha256, day)
);

create or replace function public.saathi_issue_trial(
    p_device_id      uuid,
    p_token_sha256   text,
    p_source_sha256  text
)
returns jsonb
language plpgsql
security definer
set search_path = saathi, public, pg_catalog
as $$
declare
    v_seen     integer;
    v_account  saathi.accounts%rowtype;
begin
    -- The limit first, as one statement: check and spend cannot disagree (see 0001). Every request
    -- counts, including a repeat from a known device — otherwise one address could mint tokens for
    -- a known device without end.
    insert into saathi.trial_requests (source_sha256, day, requests)
    values (p_source_sha256, (now() at time zone 'utc')::date, 1)
    on conflict (source_sha256, day) do update
        set requests = saathi.trial_requests.requests + 1
        where saathi.trial_requests.requests < 5
    returning requests into v_seen;

    if v_seen is null then
        return jsonb_build_object('ok', false, 'reason', 'rate_limited');
    end if;

    -- Make the account if this device has none. `do nothing` rather than catching a unique
    -- violation: two first requests from one device race here, and both must end up on one row.
    insert into saathi.accounts (label, plan, trial, daily_voice_sessions, expires_at, device_id)
    values ('trial', 'trial', true, 3, now() + interval '7 days', p_device_id)
    on conflict (device_id) where device_id is not null do nothing;

    select * into v_account from saathi.accounts where device_id = p_device_id;

    if v_account.suspended_at is not null
       or (v_account.expires_at is not null and v_account.expires_at <= now()) then
        -- Same answer for both: a suspended trial is not owed an explanation over an
        -- unauthenticated route, and "expired" is what the client can act on.
        return jsonb_build_object('ok', false, 'reason', 'expired');
    end if;

    -- A fresh token, and only one live at a time: the Mac that asked again has lost the old one.
    update saathi.tokens set revoked_at = now()
    where account_id = v_account.id and revoked_at is null;

    insert into saathi.tokens (token_sha256, account_id, label)
    values (p_token_sha256, v_account.id, 'trial');

    return jsonb_build_object(
        'ok', true,
        'expires_at', v_account.expires_at,
        'daily_voice_sessions', v_account.daily_voice_sessions);
end;
$$;

--
-- The two existing functions learn that an account can end. Bodies are 0001's, with one check
-- added after the suspension check; everything else is unchanged on purpose.
--
create or replace function public.saathi_claim_voice_session(p_token_sha256 text)
returns jsonb
language plpgsql
security definer
set search_path = saathi, public, pg_catalog
as $$
declare
    v_account   saathi.accounts%rowtype;
    v_used      integer;
begin
    select a.* into v_account
    from saathi.tokens t
    join saathi.accounts a on a.id = t.account_id
    where t.token_sha256 = p_token_sha256
      and t.revoked_at is null;

    if not found then
        return jsonb_build_object('ok', false, 'reason', 'not authorised');
    end if;

    if v_account.suspended_at is not null then
        return jsonb_build_object('ok', false, 'reason', 'this account is suspended');
    end if;

    if v_account.expires_at is not null and v_account.expires_at <= now() then
        return jsonb_build_object('ok', false, 'reason', 'your Saathi trial has ended');
    end if;

    if v_account.daily_voice_sessions <= 0 then
        return jsonb_build_object('ok', false, 'reason', 'this account has no voice sessions allowed');
    end if;

    insert into saathi.voice_usage (account_id, day, sessions)
    values (v_account.id, (now() at time zone 'utc')::date, 1)
    on conflict (account_id, day) do update
        set sessions = saathi.voice_usage.sessions + 1
        where saathi.voice_usage.sessions < v_account.daily_voice_sessions
    returning sessions into v_used;

    if v_used is null then
        return jsonb_build_object(
            'ok', false,
            'reason', format('that is %s voice sessions today, which is this account''s limit',
                             v_account.daily_voice_sessions));
    end if;

    update saathi.tokens set last_used_at = now() where token_sha256 = p_token_sha256;

    return jsonb_build_object(
        'ok', true,
        'account', v_account.id,
        'plan', v_account.plan,
        'used', v_used,
        'allowance', v_account.daily_voice_sessions);
end;
$$;

create or replace function public.saathi_resolve_token(p_token_sha256 text)
returns jsonb
language plpgsql
security definer
set search_path = saathi, public, pg_catalog
as $$
declare
    v_account saathi.accounts%rowtype;
begin
    select a.* into v_account
    from saathi.tokens t
    join saathi.accounts a on a.id = t.account_id
    where t.token_sha256 = p_token_sha256
      and t.revoked_at is null;

    if not found or v_account.suspended_at is not null then
        return jsonb_build_object('ok', false);
    end if;

    -- Unlike "unknown" and "revoked", which must read the same, this one is said out loud: the
    -- caller holds a token that was real, and "your trial ended" is something they can act on.
    if v_account.expires_at is not null and v_account.expires_at <= now() then
        return jsonb_build_object('ok', false, 'reason', 'your Saathi trial has ended');
    end if;

    return jsonb_build_object('ok', true, 'account', v_account.id, 'plan', v_account.plan);
end;
$$;

revoke all on function public.saathi_issue_trial(uuid, text, text) from public, anon, authenticated;
grant execute on function public.saathi_issue_trial(uuid, text, text) to service_role;

-- `create or replace` keeps existing grants, but say it again so this file stands alone.
revoke all on function public.saathi_claim_voice_session(text) from public, anon, authenticated;
revoke all on function public.saathi_resolve_token(text)       from public, anon, authenticated;
grant execute on function public.saathi_claim_voice_session(text) to service_role;
grant execute on function public.saathi_resolve_token(text)       to service_role;

revoke all on all tables in schema saathi from anon, authenticated;
```

- [ ] **Step 4: Apply and verify.** Applying a migration to the shared Supabase is outward-facing: **confirm with the user before running the first command** unless they have already said to apply it.

Run: `psql "$SAATHI_DATABASE_URL" -v ON_ERROR_STOP=1 -f backend/migrations/0002_trials.sql`
Then: `psql "$SAATHI_DATABASE_URL" -v ON_ERROR_STOP=1 -f backend/migrations/0002_verify.sql`
Expected: `NOTICE:  0002: all assertions passed` then `ROLLBACK`.

- [ ] **Step 5: Commit.**

```bash
git add backend/migrations/0002_trials.sql backend/migrations/0002_verify.sql
git commit -m "A trial is an account that ends, one per device, five asks per network per day"
```

---

### Task 3: `POST /trial`, and `/health` says whether trials are on

**Files:**
- Create: `backend/src/trial.ts`
- Create: `backend/test/trial.test.ts`
- Modify: `backend/src/realtime.ts` (export `sha256Hex`; `SessionLedger.issueTrial?`; `RpcResult`; `supabaseLedger`; `authorize` passes the reason through)
- Modify: `backend/src/app.ts` (`/health`, mount `/trial`)
- Modify: `contract/schema/saathi.json` (`backend.routes`), then regenerate
- Modify: `docs/superpowers/specs/2026-09-15-app-shell-and-onboarding-design.md` (the 404 sentence)

**Interfaces:**
- Consumes: `public.saathi_issue_trial` from Task 2 (keys `ok`, `reason`, `expires_at`, `daily_voice_sessions`; reasons `rate_limited`, `expired`).
- Produces: `POST /trial` with body `{"device":"<uuid v4>"}` → `200 {"token": string, "expiresAt": string (ISO 8601), "dailyVoiceSessions": number}`; `400 {"error"}` for a bad device; `403 {"error":"this Mac's Saathi trial has ended"}`; `429 {"error":"that is five trial requests from this network today; try again tomorrow"}`; `501 {"error":"this backend does not offer trials", "hint": …}` without a ledger; `503 {"error"}` when the database does not answer. `GET /health` gains `"trial": "on" | "off"`. Task 4 depends on these shapes and status codes exactly.

- [ ] **Step 1: Write the failing tests.** Create `backend/test/trial.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";
import { createApp } from "../src/app.js";
import { LedgerUnavailableError, supabaseLedger, type SessionLedger, type TrialResult } from "../src/realtime.js";

const DEVICE = "3f2b8c1e-5a44-4c1b-9d0e-7a6b5c4d3e2f";

/** A ledger that records what it was asked, and answers with `result`. */
function trialLedger(result: TrialResult | Error) {
  const calls: { device: string; tokenSha256: string; sourceSha256: string }[] = [];
  const ledger: SessionLedger = {
    description: "test",
    authorize: async () => null,
    check: async () => null,
    issueTrial: async (device, tokenSha256, sourceSha256) => {
      calls.push({ device, tokenSha256, sourceSha256 });
      if (result instanceof Error) throw result;
      return result;
    },
  };
  return { ledger, calls };
}

const post = (app: ReturnType<typeof createApp>, body: unknown, headers: Record<string, string> = {}) =>
  app.request("/trial", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

describe("POST /trial", () => {
  const granted: TrialResult = { ok: true, expiresAt: "2026-09-28T10:00:00+00:00", dailyVoiceSessions: 3 };

  it("mints a token without asking for one, and never stores or echoes it in the clear to the ledger", async () => {
    const { ledger, calls } = trialLedger(granted);
    const response = await post(createApp({}, { ledger }), { device: DEVICE }, { "x-forwarded-for": "203.0.113.7, 10.0.0.1" });

    expect(response.status).toBe(200);
    const body = (await response.json()) as { token: string; expiresAt: string; dailyVoiceSessions: number };
    expect(body.token).toMatch(/^saathi_trial_[A-Za-z0-9_-]{43}$/);
    expect(body.expiresAt).toBe("2026-09-28T10:00:00+00:00");
    expect(body.dailyVoiceSessions).toBe(3);

    expect(calls).toHaveLength(1);
    expect(calls[0]!.device).toBe(DEVICE);
    expect(calls[0]!.tokenSha256).toMatch(/^[0-9a-f]{64}$/);
    expect(calls[0]!.tokenSha256).not.toContain(body.token);
    expect(calls[0]!.sourceSha256).toMatch(/^[0-9a-f]{64}$/);
    expect(calls[0]!.sourceSha256).not.toContain("203.0.113.7");
  });

  it("gives two requests two different tokens", async () => {
    const { ledger } = trialLedger(granted);
    const app = createApp({}, { ledger });
    const first = (await (await post(app, { device: DEVICE })).json()) as { token: string };
    const second = (await (await post(app, { device: DEVICE })).json()) as { token: string };
    expect(first.token).not.toBe(second.token);
  });

  it("hashes the first forwarded address, so one network is one bucket whatever proxies follow", async () => {
    const { ledger, calls } = trialLedger(granted);
    const app = createApp({}, { ledger });
    await post(app, { device: DEVICE }, { "x-forwarded-for": "203.0.113.7, 10.0.0.1" });
    await post(app, { device: DEVICE }, { "x-forwarded-for": "203.0.113.7" });
    await post(app, { device: DEVICE }, { "x-forwarded-for": "198.51.100.2" });
    expect(calls[0]!.sourceSha256).toBe(calls[1]!.sourceSha256);
    expect(calls[0]!.sourceSha256).not.toBe(calls[2]!.sourceSha256);
  });

  it.each([
    ["no body", ""],
    ["not JSON", "{"],
    ["no device", {}],
    ["a device that is not a UUID", { device: "my-mac" }],
    ["a UUID that is not v4", { device: "3f2b8c1e-5a44-1c1b-9d0e-7a6b5c4d3e2f" }],
    ["a device that is not a string", { device: 7 }],
  ])("answers 400 for %s and asks the ledger nothing", async (_name, body) => {
    const { ledger, calls } = trialLedger(granted);
    const response = await post(createApp({}, { ledger }), body);
    expect(response.status).toBe(400);
    expect(calls).toHaveLength(0);
  });

  it("accepts an upper-case UUID and sends the ledger the lower-case one", async () => {
    const { ledger, calls } = trialLedger(granted);
    const response = await post(createApp({}, { ledger }), { device: DEVICE.toUpperCase() });
    expect(response.status).toBe(200);
    expect(calls[0]!.device).toBe(DEVICE);
  });

  it("answers 429 in words when the network has asked five times today", async () => {
    const { ledger } = trialLedger({ ok: false, reason: "rate_limited" });
    const response = await post(createApp({}, { ledger }), { device: DEVICE });
    expect(response.status).toBe(429);
    expect(((await response.json()) as { error: string }).error).toContain("five trial requests");
  });

  it("answers 403 in words when this device's trial has ended", async () => {
    const { ledger } = trialLedger({ ok: false, reason: "expired" });
    const response = await post(createApp({}, { ledger }), { device: DEVICE });
    expect(response.status).toBe(403);
    expect(((await response.json()) as { error: string }).error).toContain("trial has ended");
  });

  it("answers 503, not a token, when the database does not answer", async () => {
    const { ledger } = trialLedger(new LedgerUnavailableError("the accounts database did not answer (500)"));
    const response = await post(createApp({}, { ledger }), { device: DEVICE });
    expect(response.status).toBe(503);
  });

  it("answers 501 on a backend with no accounts ledger, whatever its auth posture", async () => {
    for (const env of [{ SAATHI_TOKENS: "good" }, { SAATHI_ALLOW_ANONYMOUS: "1" }, {}]) {
      const response = await post(createApp(env), { device: DEVICE });
      expect(response.status).toBe(501);
    }
  });
});

describe("/health and trials", () => {
  it("says on with a ledger that can issue them, off otherwise", async () => {
    const { ledger } = trialLedger({ ok: false, reason: "expired" });
    const on = (await (await createApp({}, { ledger }).request("/health")).json()) as { trial: string };
    const off = (await (await createApp({ SAATHI_TOKENS: "good" }).request("/health")).json()) as { trial: string };
    expect(on.trial).toBe("on");
    expect(off.trial).toBe("off");
  });
});

describe("the Supabase ledger and trials", () => {
  const supabase = { url: "https://project.supabase.co", secretKey: "sb_secret_test" };

  it("calls saathi_issue_trial with exactly the three parameters and maps the answer", async () => {
    const fetchImpl = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) =>
      new Response(JSON.stringify({ ok: true, expires_at: "2026-09-28T10:00:00+00:00", daily_voice_sessions: 3 })),
    ) as unknown as typeof fetch;
    const result = await supabaseLedger(supabase, fetchImpl).issueTrial!(DEVICE, "a".repeat(64), "b".repeat(64));

    expect(result).toEqual({ ok: true, expiresAt: "2026-09-28T10:00:00+00:00", dailyVoiceSessions: 3 });
    const [url, init] = (fetchImpl as unknown as ReturnType<typeof vi.fn>).mock.calls[0]!;
    expect(String(url)).toBe("https://project.supabase.co/rest/v1/rpc/saathi_issue_trial");
    expect(JSON.parse((init as RequestInit).body as string)).toEqual({
      p_device_id: DEVICE, p_token_sha256: "a".repeat(64), p_source_sha256: "b".repeat(64),
    });
  });

  it("maps a refusal, and treats an unknown reason as expired rather than as a grant", async () => {
    const answering = (body: unknown) =>
      (async () => new Response(JSON.stringify(body))) as unknown as typeof fetch;
    expect(await supabaseLedger(supabase, answering({ ok: false, reason: "rate_limited" })).issueTrial!(DEVICE, "a", "b"))
      .toEqual({ ok: false, reason: "rate_limited" });
    expect(await supabaseLedger(supabase, answering({ ok: false, reason: "something new" })).issueTrial!(DEVICE, "a", "b"))
      .toEqual({ ok: false, reason: "expired" });
    expect(await supabaseLedger(supabase, answering({ ok: true })).issueTrial!(DEVICE, "a", "b"))
      .toEqual({ ok: false, reason: "expired" });
  });

  it("throws LedgerUnavailableError when the database does not answer", async () => {
    const down = (async () => new Response("nope", { status: 500 })) as unknown as typeof fetch;
    await expect(supabaseLedger(supabase, down).issueTrial!(DEVICE, "a", "b")).rejects.toBeInstanceOf(LedgerUnavailableError);
  });

  it("passes the reason an expired trial is refused through to the caller", async () => {
    const fetchImpl = (async () =>
      new Response(JSON.stringify({ ok: false, reason: "your Saathi trial has ended" }))) as unknown as typeof fetch;
    const response = await createApp({}, { ledger: supabaseLedger(supabase, fetchImpl) }).request("/session", {
      method: "POST",
      headers: { authorization: "Bearer was-real" },
    });
    expect(response.status).toBe(401);
    expect(((await response.json()) as { error: string }).error).toBe("your Saathi trial has ended");
  });
});
```

- [ ] **Step 2: Run them to see them fail.**

Run: `cd backend && npx vitest run test/trial.test.ts 2>&1 | tail -15`
Expected: failures — `TrialResult` is not exported, `/trial` answers 404, `/health` has no `trial`.

- [ ] **Step 3: Extend the ledger.** In `backend/src/realtime.ts`:

Add above `SessionLedger`:

```ts
/** What asking for a trial comes to. The two refusals are the only two the database gives. */
export type TrialResult =
  | { ok: true; expiresAt: string; dailyVoiceSessions: number }
  | { ok: false; reason: "rate_limited" | "expired" };
```

Add to the `SessionLedger` interface, after `check`:

```ts
  /**
   * Gives `device` a trial account and registers `tokenSha256` as its one live token. Optional: a
   * ledger that has no accounts to make omits it, and the backend then does not offer trials.
   *
   * Takes hashes, not the token or the address: what reaches the database is what is stored there.
   * Must be atomic — the rate limit, the one-account-per-device rule and the insert are one call.
   */
  issueTrial?(device: string, tokenSha256: string, sourceSha256: string): Promise<TrialResult>;
```

Change `async function sha256Hex` to `export async function sha256Hex`.

Replace the `RpcResult` type:

```ts
type RpcResult = {
  ok?: boolean; reason?: string; account?: string; used?: number; allowance?: number;
  expires_at?: string; daily_voice_sessions?: number;
};
```

In `supabaseLedger`, generalise `rpc` to take the parameter object, and add `issueTrial`:

```ts
  const rpc = async (name: string, params: Record<string, string>): Promise<RpcResult> => {
    const response = await fetchImpl(`${base}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: {
        apikey: config.secretKey,
        authorization: `Bearer ${config.secretKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(params),
    });
    if (!response.ok) {
      // A database that cannot be reached must not read as "allowed". Refusing is the safe
      // direction: the worst case is a learner told to try again, not an unmetered account.
      throw new LedgerUnavailableError(`the accounts database did not answer (${response.status})`);
    }
    return (await response.json()) as RpcResult;
  };

  return {
    description: "per-account daily limit, counted in Postgres (shared across every instance)",

    authorize: async (token: string) => {
      const result = await rpc("saathi_resolve_token", { p_token_sha256: await sha256Hex(token) });
      // The one reason the database states for a token that was real: a trial that has ended.
      return result.ok ? null : (result.reason ?? "not authorised");
    },

    check: async (token: string) => {
      const result = await rpc("saathi_claim_voice_session", { p_token_sha256: await sha256Hex(token) });
      return result.ok ? null : (result.reason ?? "not authorised");
    },

    issueTrial: async (device, tokenSha256, sourceSha256) => {
      const result = await rpc("saathi_issue_trial", {
        p_device_id: device, p_token_sha256: tokenSha256, p_source_sha256: sourceSha256,
      });
      if (result.ok && typeof result.expires_at === "string" && typeof result.daily_voice_sessions === "number") {
        return { ok: true, expiresAt: result.expires_at, dailyVoiceSessions: result.daily_voice_sessions };
      }
      // Anything that is not a well-formed grant is a refusal. An answer this code does not
      // understand must never become a token in someone's hands.
      return { ok: false, reason: result.reason === "rate_limited" ? "rate_limited" : "expired" };
    },
  };
```

- [ ] **Step 4: Write the route.** Create `backend/src/trial.ts`:

```ts
//
//  trial.ts
//  @saathi/backend
//
//  A first-run Mac asks for a trial and is handed a token, with no account and no sign-in.
//
//  This is the one route that gives something away to a caller who has proved nothing, so what it
//  can give is small and the limits are not here: three sessions a day for seven days, one account
//  per device, five asks per network per day — all of it enforced in one Postgres function (see
//  migrations/0002_trials.sql), because a counter in this process is one quota per warm isolate.
//
//  What this file does is refuse malformed requests before they reach the database, mint the
//  token, and make sure neither the token nor the caller's address travels any further than it
//  has to: the ledger is handed hashes.
//

import type { Context } from "hono";
import { LedgerUnavailableError, sha256Hex, type SessionLedger } from "./realtime.js";

/** UUID version 4, variant 1 — what `UUID()` on macOS and `Guid.NewGuid()` on Windows produce. */
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

/** The device id as the database will key it, or null when it is not a v4 UUID. */
export function normalisedDevice(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const lower = raw.trim().toLowerCase();
  return UUID_V4.test(lower) ? lower : null;
}

/** 32 random bytes, base64url: 43 characters, prefixed so a leaked one is recognisable in a log. */
export function mintTrialToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  const encoded = btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return `saathi_trial_${encoded}`;
}

/**
 * Who is asking, for the rate limit. The first entry of `x-forwarded-for` is the client as the
 * platform's edge saw it; later entries are proxies. With no header at all — a self-hosted backend
 * with nothing in front of it — every caller shares one bucket, which is the conservative side.
 */
export function sourceAddress(forwardedFor: string | undefined): string {
  const first = (forwardedFor ?? "").split(",")[0]?.trim() ?? "";
  return first.length > 0 ? first : "unknown";
}

export async function issueTrial(c: Context, ledger: SessionLedger): Promise<Response> {
  if (typeof ledger.issueTrial !== "function") {
    // A backend without an accounts database is a normal, supported posture — same answer, and
    // the same reasoning, as hosted voice without a provider key.
    return c.json(
      {
        error: "this backend does not offer trials",
        hint: "trials need the accounts database (SAATHI_SUPABASE_URL and SAATHI_SUPABASE_SECRET_KEY).",
      },
      501,
    );
  }

  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "the body must be JSON: {\"device\": \"<uuid v4>\"}" }, 400);
  }
  const device = normalisedDevice((body as { device?: unknown } | null)?.device);
  if (!device) return c.json({ error: "device must be a version 4 UUID" }, 400);

  const token = mintTrialToken();
  try {
    const result = await ledger.issueTrial(
      device,
      await sha256Hex(token),
      await sha256Hex(sourceAddress(c.req.header("x-forwarded-for"))),
    );
    if (result.ok) {
      return c.json({ token, expiresAt: result.expiresAt, dailyVoiceSessions: result.dailyVoiceSessions });
    }
    if (result.reason === "rate_limited") {
      return c.json({ error: "that is five trial requests from this network today; try again tomorrow" }, 429);
    }
    return c.json({ error: "this Mac's Saathi trial has ended" }, 403);
  } catch (error) {
    const message = error instanceof LedgerUnavailableError ? error.message : "could not set up a trial";
    return c.json({ error: message }, 503);
  }
}
```

- [ ] **Step 5: Mount it and report it.** In `backend/src/app.ts`: add `import { issueTrial } from "./trial.js";`. In the `/health` handler add, after `limits`:

```ts
      // Whether a first-run client can be given a trial here. Only a ledger that can make accounts
      // can, so this is a property of what was wired in, like `auth`.
      trial: typeof ledger.issueTrial === "function" ? "on" : "off",
```

Before `app.notFound`, add:

```ts
  /**
   * Hands a first-run client a trial token. The one unauthenticated route that gives anything
   * away — see trial.ts for what bounds it.
   */
  app.post("/trial", (c) => issueTrial(c, ledger));
```

- [ ] **Step 6: Declare the route in the contract.** In `contract/schema/saathi.json`, append to `backend.routes`:

```json
      {
        "method": "POST",
        "path": "/trial",
        "auth": false,
        "summary": "Gives a first-run client a trial token: three voice sessions a day for seven days, one account per device. Body {\"device\": \"<uuid v4>\"}. 501 on a backend with no accounts database."
      }
```

Run: `npm run generate && npm run check:contract`

- [ ] **Step 7: Amend the spec.** In `docs/superpowers/specs/2026-09-15-app-shell-and-onboarding-design.md`, replace the bullet beginning "Route only exists when the accounts ledger is configured" with:

```markdown
- The route is always mounted, because `routes match the contract` requires every declared route
  to answer on every posture. A self-hosted anonymous or tokens backend answers 501 "this backend
  does not offer trials" — the same code, for the same reason, as hosted voice without a provider
  key — and `/health` gains `"trial": "on" | "off"`. *(Amended 2026-09-21: was 404.)*
```

- [ ] **Step 8: Run everything.**

Run: `npm test && npm run typecheck`
Expected: all backend tests pass (45 existing + the new file), typecheck clean. `routes match the contract` passes with `/trial` answering 501 on the tokens posture.

- [ ] **Step 9: Commit.**

```bash
git add backend/src backend/test contract macos/Saathi/Sources/SaathiContract windows/src docs/superpowers/specs
git commit -m "A first-run Mac can ask for a trial, and the backend hands the ledger only hashes"
```

---

### Task 4: `TrialClient` — the device id, the ask, and keeping the answer

**Files:**
- Create: `macos/Saathi/Sources/SaathiKit/TrialClient.swift`
- Create: `macos/Saathi/Tests/SaathiKitTests/TrialClientTests.swift`
- Modify: `macos/Saathi/Sources/SaathiKit/BackendClient.swift:11-14` (`BackendHealth`)

**Interfaces:**
- Consumes: `SaathiConfiguration.deviceId`, `.token`, `.resolvedBaseURL` (Task 1); `ConfigurationStore.load(from:)` / `.save(_:to:)`; the `/trial` shapes and status codes from Task 3.
- Produces (slice 4's onboarding step 6.4 calls these):
  - `public struct TrialGrant: Codable, Sendable, Equatable { token: String; expiresAt: String; dailyVoiceSessions: Int }`
  - `public enum TrialError: Error, CustomStringConvertible, Equatable { case badBaseUrl(String), refused(String), notOffered(String), transport(String) }`
  - `public struct TrialClient: Sendable { init(configuration: SaathiConfiguration, session: URLSession = .shared) throws; func requestTrial(device: String) async throws -> TrialGrant }`
  - `public enum TrialEnrollment { static func deviceId(in configuration: inout SaathiConfiguration) -> String; static func enroll(at path: URL, session: URLSession = .shared) async throws -> TrialGrant }`
  - `BackendHealth.trial: String?`

- [ ] **Step 1: Write the failing tests.** Create `TrialClientTests.swift`:

```swift
//
//  TrialClientTests.swift
//  SaathiKitTests
//
//  Asking for a trial, against a stub URL session: what is sent, what each refusal becomes in
//  words, and that the device id is made once and kept — because a second id is a second trial.
//

import XCTest
import SaathiContract
@testable import SaathiKit

final class TrialStubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = "{}"
    nonisolated(unsafe) static var shouldFail = false
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func reset(status: Int, body: String, shouldFail: Bool = false) {
        self.status = status; self.body = body; self.shouldFail = shouldFail
        lastRequest = nil; lastBody = nil
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrialStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastRequest = request
        // URLProtocol hands the body over as a stream, never as `httpBody`.
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            Self.lastBody = data
        }
        if Self.shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class TrialClientTests: XCTestCase {

    private let device = "3f2b8c1e-5a44-4c1b-9d0e-7a6b5c4d3e2f"
    private let granted = #"{"token":"saathi_trial_abc","expiresAt":"2026-09-28T10:00:00+00:00","dailyVoiceSessions":3}"#

    private func client() throws -> TrialClient {
        try TrialClient(
            configuration: SaathiConfiguration(backendUrl: "https://backend.example.test"),
            session: TrialStubProtocol.session)
    }

    func testItPostsTheDeviceWithNoAuthorizationAndReadsTheGrant() async throws {
        TrialStubProtocol.reset(status: 200, body: granted)
        let grant = try await client().requestTrial(device: device)

        XCTAssertEqual(grant, TrialGrant(token: "saathi_trial_abc", expiresAt: "2026-09-28T10:00:00+00:00", dailyVoiceSessions: 3))
        let request = try XCTUnwrap(TrialStubProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://backend.example.test/trial")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "a trial is asked for by someone who has no token yet")
        let sent = try JSONSerialization.jsonObject(with: try XCTUnwrap(TrialStubProtocol.lastBody)) as? [String: String]
        XCTAssertEqual(sent, ["device": device])
    }

    /// Onboarding says "the exact reason in words", so the backend's sentence is what is kept.
    func testARefusalCarriesTheBackendsOwnSentence() async throws {
        for status in [429, 403] {
            TrialStubProtocol.reset(status: status, body: #"{"error":"that is five trial requests from this network today; try again tomorrow"}"#)
            do {
                _ = try await client().requestTrial(device: device)
                XCTFail("a \(status) must throw")
            } catch let error as TrialError {
                XCTAssertEqual(error, .refused("that is five trial requests from this network today; try again tomorrow"))
            }
        }
    }

    func testABackendThatDoesNotOfferTrialsSaysSo() async throws {
        for status in [501, 404] {
            TrialStubProtocol.reset(status: status, body: #"{"error":"this backend does not offer trials"}"#)
            do {
                _ = try await client().requestTrial(device: device)
                XCTFail("a \(status) must throw")
            } catch let error as TrialError {
                XCTAssertEqual(error, .notOffered("this backend does not offer trials"))
            }
        }
    }

    func testAnUnreachableBackendIsATransportError() async throws {
        TrialStubProtocol.reset(status: 200, body: "", shouldFail: true)
        do {
            _ = try await client().requestTrial(device: device)
            XCTFail("must throw")
        } catch let error as TrialError {
            guard case .transport = error else { return XCTFail("\(error)") }
        }
    }

    func testA5xxAndAnUnreadableGrantAreTransportErrorsNotGrants() async throws {
        TrialStubProtocol.reset(status: 503, body: #"{"error":"the accounts database did not answer (500)"}"#)
        do { _ = try await client().requestTrial(device: device); XCTFail("must throw") }
        catch let error as TrialError { XCTAssertEqual(error, .transport("the accounts database did not answer (500)")) }

        TrialStubProtocol.reset(status: 200, body: #"{"token":7}"#)
        do { _ = try await client().requestTrial(device: device); XCTFail("must throw") }
        catch let error as TrialError { guard case .transport = error else { return XCTFail("\(error)") } }
    }

    func testEveryTrialErrorReadsAsASentence() {
        let errors: [TrialError] = [.badBaseUrl("x"), .refused("r"), .notOffered("n"), .transport("t")]
        for error in errors { XCTAssertFalse(error.description.isEmpty) }
        XCTAssertEqual(TrialError.refused("your trial ended").description, "your trial ended")
    }

    // MARK: the device id

    func testTheDeviceIdIsMadeOnceAndIsALowercaseV4UUID() {
        var configuration = SaathiConfiguration()
        let first = TrialEnrollment.deviceId(in: &configuration)
        let second = TrialEnrollment.deviceId(in: &configuration)
        XCTAssertEqual(first, second, "a second id is a second trial")
        XCTAssertEqual(configuration.deviceId, first)
        XCTAssertNotNil(first.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression))
    }

    func testABlankStoredDeviceIdIsReplaced() {
        var configuration = SaathiConfiguration(deviceId: "  ")
        XCTAssertFalse(TrialEnrollment.deviceId(in: &configuration).trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: enrolling

    private func temporaryConfigPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("saathi-trial-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("shell.json")
    }

    func testEnrollingSavesTheTokenAndTheDeviceIdAndNothingElseChanges() async throws {
        let path = temporaryConfigPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try ConfigurationStore.save(
            SaathiConfiguration(openaiKey: "sk-kept", backendUrl: "https://backend.example.test"), to: path)
        TrialStubProtocol.reset(status: 200, body: granted)

        let grant = try await TrialEnrollment.enroll(at: path, session: TrialStubProtocol.session)

        let saved = try ConfigurationStore.load(from: path)
        XCTAssertEqual(saved.token, grant.token)
        XCTAssertNotNil(saved.deviceId)
        XCTAssertEqual(saved.openaiKey, "sk-kept")
        XCTAssertNil(saved.provider, "choosing where Saathi thinks is onboarding's last step, not this one")
    }

    /// The id is written before the network is touched: a refused or failed ask must not mean a
    /// new id — and so a new trial — on the next attempt.
    func testTheDeviceIdSurvivesARefusal() async throws {
        let path = temporaryConfigPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try ConfigurationStore.save(SaathiConfiguration(backendUrl: "https://backend.example.test"), to: path)

        TrialStubProtocol.reset(status: 429, body: #"{"error":"try again tomorrow"}"#)
        do { _ = try await TrialEnrollment.enroll(at: path, session: TrialStubProtocol.session); XCTFail("must throw") } catch {}
        let afterRefusal = try XCTUnwrap(try ConfigurationStore.load(from: path).deviceId)
        XCTAssertNil(try ConfigurationStore.load(from: path).token)

        TrialStubProtocol.reset(status: 200, body: granted)
        _ = try await TrialEnrollment.enroll(at: path, session: TrialStubProtocol.session)
        let sent = try JSONSerialization.jsonObject(with: try XCTUnwrap(TrialStubProtocol.lastBody)) as? [String: String]
        XCTAssertEqual(sent?["device"], afterRefusal)
    }

    func testHealthReadsWhetherTrialsAreOn() throws {
        let health = try JSONDecoder().decode(BackendHealth.self, from: Data(#"{"ok":true,"version":"0.8.0","trial":"on"}"#.utf8))
        XCTAssertEqual(health.trial, "on")
        let older = try JSONDecoder().decode(BackendHealth.self, from: Data(#"{"ok":true}"#.utf8))
        XCTAssertNil(older.trial, "a backend from before trials still parses")
    }
}
```

- [ ] **Step 2: Run to see it fail.**

Run: `cd macos/Saathi && swift build --build-tests 2>&1 | grep error | head -3`
Expected: `error: cannot find 'TrialClient' in scope`

- [ ] **Step 3: Implement.** In `BackendClient.swift`, add to `BackendHealth` after `version`:

```swift
    /// "on" when this backend can hand a first-run client a trial; nil from a backend that
    /// predates trials.
    public let trial: String?
```

(If anything constructs `BackendHealth` memberwise — `grep -rn "BackendHealth(" macos/Saathi` — add `trial: nil` there.)

Create `TrialClient.swift`:

```swift
//
//  TrialClient.swift
//  SaathiKit
//
//  Asking the hosted backend for a trial, on first run, before there is an account or a key.
//
//  The one request Saathi makes with no token, because it is the request that gets one. What is
//  sent is a device id and nothing else — no name, no address, nothing about the machine — and the
//  id exists only so that the same Mac asking again gets the same seven days rather than seven
//  more. It is made once, kept in `shell.json`, and written to disk *before* the network is
//  touched: a refused ask that left no id behind would mint a new one next time, and a new id is
//  a new trial.
//
//  Refusals keep the backend's own sentence. Onboarding promises "the exact reason in words", and
//  the backend is the one that knows whether it was the network's fifth ask or the trial's eighth
//  day.
//

import Foundation
import SaathiContract

public struct TrialGrant: Codable, Sendable, Equatable {
    public let token: String
    /// ISO 8601, as the backend sent it.
    public let expiresAt: String
    public let dailyVoiceSessions: Int

    public init(token: String, expiresAt: String, dailyVoiceSessions: Int) {
        self.token = token
        self.expiresAt = expiresAt
        self.dailyVoiceSessions = dailyVoiceSessions
    }
}

public enum TrialError: Error, CustomStringConvertible, Equatable {
    case badBaseUrl(String)
    /// The backend answered and said no: rate limited, or this Mac's trial has ended. Its words.
    case refused(String)
    /// This backend does not do trials at all — a self-hosted one, or one older than they are.
    case notOffered(String)
    case transport(String)

    public var description: String {
        switch self {
        case let .badBaseUrl(raw): return "\(raw) is not a usable backend URL"
        case let .refused(reason): return reason
        case let .notOffered(reason): return reason
        case let .transport(reason): return "could not set up a trial: \(reason)"
        }
    }
}

public struct TrialClient: Sendable {
    private let baseUrl: URL
    private let session: URLSession

    public init(configuration: SaathiConfiguration, session: URLSession = .shared) throws {
        guard let url = URL(string: configuration.resolvedBaseURL), url.scheme != nil else {
            throw TrialError.badBaseUrl(configuration.resolvedBaseURL)
        }
        self.baseUrl = url
        self.session = session
    }

    public func requestTrial(device: String) async throws -> TrialGrant {
        var request = URLRequest(url: baseUrl.appendingPathComponent("/trial"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["device": device])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TrialError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let stated = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        switch status {
        case 200..<300:
            do {
                return try JSONDecoder().decode(TrialGrant.self, from: data)
            } catch {
                throw TrialError.transport("unexpected response shape: \(error.localizedDescription)")
            }
        case 403, 429:
            throw TrialError.refused(stated ?? "the trial was refused (\(status))")
        case 404, 501:
            throw TrialError.notOffered(stated ?? "this backend does not offer trials")
        default:
            throw TrialError.transport(stated ?? "the backend returned \(status)")
        }
    }
}

public enum TrialEnrollment {

    /// This machine's device id: the stored one, or a new lowercase v4 UUID written into
    /// `configuration`. The caller saves it.
    public static func deviceId(in configuration: inout SaathiConfiguration) -> String {
        let stored = (configuration.deviceId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        let made = UUID().uuidString.lowercased()
        configuration.deviceId = made
        return made
    }

    /// Asks for a trial and keeps the answer: the device id is saved before the request, the token
    /// after it. Nothing else in the file changes — in particular not `provider`; where Saathi
    /// thinks afterwards is the learner's choice, made at the end of onboarding.
    public static func enroll(at path: URL, session: URLSession = .shared) async throws -> TrialGrant {
        var configuration = try ConfigurationStore.load(from: path)
        let hadDevice = !(configuration.deviceId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let device = deviceId(in: &configuration)
        if !hadDevice { try ConfigurationStore.save(configuration, to: path) }

        let grant = try await TrialClient(configuration: configuration, session: session).requestTrial(device: device)

        configuration.token = grant.token
        try ConfigurationStore.save(configuration, to: path)
        return grant
    }
}
```

- [ ] **Step 4: Run the tests.**

Run: `cd macos/Saathi && swift test --filter TrialClientTests 2>&1 | grep -E "error:|failed|Executed"`
Expected: `Executed 11 tests, with 0 failures`.

Run: `swift test 2>&1 | grep -E "error:|failed"`
Expected: no output.

- [ ] **Step 5: Commit.**

```bash
git add macos/Saathi/Sources/SaathiKit/TrialClient.swift macos/Saathi/Sources/SaathiKit/BackendClient.swift macos/Saathi/Tests/SaathiKitTests/TrialClientTests.swift
git commit -m "Saathi can ask for a trial, and the device id is on disk before the network is touched"
```

---

### Task 5: Say it in HOSTING.md, and check the live service

**Files:**
- Modify: `docs/HOSTING.md`

**Interfaces:**
- Consumes: everything above. Produces: documentation and a verification record only.

- [ ] **Step 1: Document.** Add a section "Trials" to `docs/HOSTING.md` (read the file first and match its voice) covering, in this order: what a trial is (3/day, 7 days, one account per device, 5 asks per network per day); that it needs the accounts database and nothing else new — no new environment variable; the two commands to apply and verify `0002_trials.sql`; that `/health` now reports `"trial": "on" | "off"` and a self-hosted backend without the database answers 501 on `/trial`; that source addresses and tokens are stored hashed; and how to end a trial early (`update saathi.accounts set suspended_at = now() where device_id = '…'`).

- [ ] **Step 2: Verify the deployed service** — only after the branch is merged and deployed, and the migration applied. Do not run the second command more than once: each run spends one of the five daily asks for this network and creates a real trial account.

Run: `curl -s https://api.saathi.dev/health`
Expected: JSON containing `"trial":"on"` and `"version":"0.8.0"`.

Run: `curl -s -X POST https://api.saathi.dev/trial -H 'content-type: application/json' -d '{"device":"not-a-uuid"}'`
Expected: `{"error":"device must be a version 4 UUID"}` (a 400 spends nothing).

Record both outputs in the "verification" table of `docs/HOSTING.md`. If the service is not yet deployed from this branch, write "not yet verified against production" in that table rather than leaving it blank.

- [ ] **Step 3: Commit.**

```bash
git add docs/HOSTING.md
git commit -m "HOSTING says what a trial is, how to turn it on, and how to end one"
```

---

## Self-Review

- **Spec coverage.** Trial route, body and response shape → Task 3. Same device → same account, fresh token → Task 2 (`saathi_issue_trial`, verified in `0002_verify.sql`). `trial`, `expires_at`, `device_id` + unique index → Task 2. `saathi_claim_voice_session` refuses expired accounts with a message that says the trial ended → Task 2. Five per source per day in Postgres, 429 → Tasks 2 and 3. Route absent without a ledger → Task 3, as 501 with the spec amended (see Global Constraints). `/health` `trial` → Task 3. `TrialClient`, token saved 0600 through `ConfigurationStore`, `deviceId` generated once → Task 4. Config fields `name`, `colour`, `tone`, `pace`, `language` (already present), `firstGoal`, `onboarded`, `deviceId`, `startAtLogin` → Task 1. Deploy configuration recorded in `docs/HOSTING.md` → Task 5. Backend tests the spec lists (mints, repeats for the same device, rate-limits, absent without a ledger, health, `routesMatchContract`) → Task 3; "repeats for the same device" is a database property and is asserted in `0002_verify.sql`, with the route test covering that two asks get two tokens.
- **Not in this slice, on purpose:** `OnboardingModel`, the cards, the trial conversation itself and the provider choice are slice 4. The Windows client gets the regenerated contract and nothing else.
- **Types.** `TrialResult` (TS) keys `expiresAt` / `dailyVoiceSessions` match the HTTP response and `TrialGrant` (Swift). SQL keys `expires_at` / `daily_voice_sessions` are mapped in exactly one place, `supabaseLedger.issueTrial`. Reasons `rate_limited` / `expired` are identical in SQL, `TrialResult` and the route.
