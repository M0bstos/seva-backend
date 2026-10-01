begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

select ok(
  not has_function_privilege('anon', 'count_sms_send(text,uuid,int,int,int)', 'execute')
  and not has_function_privilege('authenticated',
        'count_sms_send(text,uuid,int,int,int)', 'execute'),
  'no client can spend the project''s daily SMS budget'
);

select ok(
  has_function_privilege('service_role', 'count_sms_send(text,uuid,int,int,int)', 'execute'),
  'the hook reaches it on its own secret key (§9.5)'
);

select is(
  (select prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'count_sms_send'),
  false,
  'security invoker: service_role already holds what the counter table needs'
);

set local role service_role;

-- §12.5 alarms at "80% of the daily SMS cap", and nothing outside this function can
-- read the counter to know that. The count comes back with the permission so the hook
-- can log it; a permission that said only "yes" would leave that alarm unbuildable.
select is(
  count_sms_send('sms.send:all', null, null, null, 2) ->> 'sent_today',
  '1',
  'the first send is allowed and reports the day''s running count'
);

-- §7.3 halves a cap for an account under 72 hours old. The hook passes no account, so
-- a cap of two has to yield two sends; halving would stop this at one.
select is(
  count_sms_send('sms.send:all', null, null, null, 2) ->> 'sent_today',
  '2',
  'and the second, at the cap, still sends, so nothing halved a project-wide budget'
);

-- §9.3 makes this the real cost stop, so the refusal has to be the daily one and not
-- a rate: §17.1 sends DAILY_LIMIT_REACHED back with the seconds to the next IST
-- midnight, which is when the SMS budget actually refills.
select is(
  count_sms_send('sms.send:all', null, null, null, 2) ->> 'error',
  'DAILY_LIMIT_REACHED',
  'and the third is refused as a daily cap, not a rate'
);

select is(
  count_sms_send('sms.send:all', null, null, null, 2) ->> 'sent_today',
  null,
  'a refusal carries no count, so the hook cannot read one out of a refusal'
);

-- The function reads a counter back out, and any secret key can call it (§9.5). These
-- three are what stop it becoming a reader of another route's counters, what stop a
-- phone number reaching `rate_limit_hits.bucket` under this route's name, and what
-- stop §12.5's alarm going quietly blind on a `null` count.
select throws_ok(
  $$select count_sms_send('acts.create:9d1f7c60-0000-4000-8000-000000000001',
      null, null, null, 30)$$,
  'count_sms_send takes the sms.send:all bucket and a daily cap',
  'another route''s bucket is refused rather than counted and reported'
);

select throws_ok(
  $$select count_sms_send('sms.send:919812345678', null, null, null, 15000)$$,
  'count_sms_send takes the sms.send:all bucket and a daily cap',
  'and so is this route under any other subject, which §12.2 defines only one of'
);

select throws_ok(
  $$select count_sms_send('sms.send:all', null, 60, null, null)$$,
  'count_sms_send takes the sms.send:all bucket and a daily cap',
  'and a call with no daily cap, which would report no count at all'
);

reset role;
select * from finish();
rollback;
