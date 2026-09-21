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
