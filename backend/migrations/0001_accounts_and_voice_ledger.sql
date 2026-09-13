--
--  0001_accounts_and_voice_ledger.sql
--  @saathi/backend
--
--  Accounts, the tokens that authenticate them, and the grant-time voice ledger.
--
--  ── Why this exists at all ───────────────────────────────────────────────────
--  Hosted voice mints a short-lived provider credential rather than proxying the audio (see
--  src/realtime.ts). That means the backend never sees what a session spends, so a session can only
--  be metered by what it is ALLOWED TO START. This is that allowance, and the reason it is in
--  Postgres rather than in memory is that a serverless deployment has no shared memory — an
--  in-process counter there is one quota per warm isolate, which is not a limit.
--
--  ── Why the tables are NOT reachable over the REST API ───────────────────────
--  Everything lives in the `saathi` schema, which is deliberately left out of PostgREST's exposed
--  schemas. Nothing here can be selected, inserted or updated through the API by anybody, with any
--  key. The only thing reachable is one SECURITY DEFINER function in `public`, which takes a token
--  hash and returns an allow/deny — it cannot be used to read an account, enumerate tokens, or
--  change an allowance. That is a much smaller surface than "tables plus the right RLS policies",
--  and it does not depend on getting a policy right.
--
--  ── Why tokens are stored hashed ─────────────────────────────────────────────
--  A database dump of plaintext bearer tokens is a set of working credentials. Hashed, it is not.
--  The backend hashes what a caller presented and looks up the hash; the plaintext exists only in
--  the moment it is issued.
--
--  Apply with:
--    psql "$SAATHI_DATABASE_URL" -f backend/migrations/0001_accounts_and_voice_ledger.sql
--

create schema if not exists saathi;

-- Not tied to Supabase's auth.users on purpose. Saathi is invite-only and token-based today; who a
-- learner is to the product, and whether they ever sign in with an email at all, is an open
-- question that should not be pre-decided by a foreign key.
create table if not exists saathi.accounts (
    id                    uuid primary key default gen_random_uuid(),
    email                 text unique,
    label                 text,
    created_at            timestamptz not null default now(),

    -- A label, not a price. Billing is not built: India is the first market, UPI is how India pays,
    -- and the payment rail is an open decision rather than a Stripe integration waiting to be
    -- switched on. When it is decided, it attaches here.
    plan                  text not null default 'invited',

    -- The grant-time allowance. Per UTC day, per account.
    daily_voice_sessions  integer not null default 20 check (daily_voice_sessions >= 0),

    suspended_at          timestamptz
);

comment on column saathi.accounts.daily_voice_sessions is
    'Realtime voice sessions this account may START per UTC day. Not a token budget — the backend '
    'never sees a session''s token usage, because the audio does not pass through it.';

-- The bearer token a client presents, as a SHA-256 hex digest. Never the token itself.
create table if not exists saathi.tokens (
    token_sha256  text primary key,
    account_id    uuid not null references saathi.accounts(id) on delete cascade,
    label         text,
    created_at    timestamptz not null default now(),
    last_used_at  timestamptz,
    revoked_at    timestamptz
);

create index if not exists tokens_account_id_idx on saathi.tokens (account_id);

-- One row per account per UTC day. Small, and prunable by date whenever that matters.
create table if not exists saathi.voice_usage (
    account_id  uuid not null references saathi.accounts(id) on delete cascade,
    day         date not null,
    sessions    integer not null default 0,
    primary key (account_id, day)
);

--
-- The ledger claim, as ONE statement.
--
-- This is the part that has to be right. The predecessor's credit checks were read-then-spend with
-- no reservation: two requests in flight both saw the same balance and both proceeded. That bug is
-- rail-independent — it would bite just as hard under UPI as under Stripe — so the fix is not "be
-- careful in the application", it is to make the check and the spend the same statement.
--
-- `on conflict do update ... where` is that statement. If the WHERE is false the row is not
-- updated, nothing is returned, and `v_used` stays null — so "over the limit" and "did not spend"
-- are the same fact rather than two facts that could disagree.
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
        -- Deliberately the same wording whether the token is unknown or revoked. Distinguishing
        -- them tells an attacker which of their guesses was once real.
        return jsonb_build_object('ok', false, 'reason', 'not authorised');
    end if;

    if v_account.suspended_at is not null then
        return jsonb_build_object('ok', false, 'reason', 'this account is suspended');
    end if;

    -- An allowance of zero must refuse, not let the first insert through: the conditional update
    -- below only guards the SECOND and later claims of a day.
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

--
-- Authentication without spending anything, for routes that are not voice.
--
-- Separate from the claim because /session must not consume an allowance just by asking what
-- actions exist.
--
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

    return jsonb_build_object('ok', true, 'account', v_account.id, 'plan', v_account.plan);
end;
$$;

-- Only the server may call these. `anon` and `authenticated` are the keys that reach browsers; a
-- publishable key must never be able to burn an account's allowance or probe which tokens are real.
revoke all on function public.saathi_claim_voice_session(text) from public, anon, authenticated;
revoke all on function public.saathi_resolve_token(text)       from public, anon, authenticated;
grant execute on function public.saathi_claim_voice_session(text) to service_role;
grant execute on function public.saathi_resolve_token(text)       to service_role;

-- Belt and braces: the schema is not exposed to PostgREST, and the API roles have no rights in it
-- either, so neither a configuration change nor a missing RLS policy alone can open these tables.
revoke all on all tables in schema saathi from anon, authenticated;
revoke usage on schema saathi from anon, authenticated;
