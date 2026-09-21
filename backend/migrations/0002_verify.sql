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
