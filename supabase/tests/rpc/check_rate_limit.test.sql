begin;
create extension if not exists pgtap with schema extensions;
select plan(19);

insert into auth.users (id, created_at) values
  ('11111111-1111-1111-1111-111111111111', now() - interval '10 hours'),
  ('22222222-2222-2222-2222-222222222222', now() - interval '10 days');

select ok(
  not has_function_privilege('anon', 'private.check_rate_limit(text,uuid,int,int,int)', 'execute')
  and not has_function_privilege('authenticated',
        'private.check_rate_limit(text,uuid,int,int,int)', 'execute'),
  'no client can call the limiter directly and spend its own budget'
);

select ok(
  has_function_privilege('service_role',
    'private.check_rate_limit(text,uuid,int,int,int)', 'execute'),
  'the routes reach it on their secret key, which the mandatory revoke took away'
);

select is(
  (select prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'private' and p.proname = 'check_rate_limit'),
  false,
  'it is security invoker: service_role already holds what the counter table needs'
);

set local role service_role;

-- §12.2, one window at a time. now() is fixed for the transaction, so every call
-- below lands in the same minute, hour and IST day.
select is(
  private.check_rate_limit('t:under', null, 3),
  null,
  'null means proceed, so a route can test it without unpacking a payload'
);

select is(
  (select count(*)::int from (
     select private.check_rate_limit('t:minute', null, 3) as r
     from generate_series(1, 3)) s
   where s.r is not null),
  0,
  'three calls against a cap of three are all allowed'
);

select is(
  private.check_rate_limit('t:minute', null, 3) ->> 'error',
  'RATE_LIMITED',
  'the fourth is refused, and a minute window is a rate limit, not a daily cap'
);

select is(
  private.check_rate_limit('t:day', null, null, null, 1) ->> 'error',
  null,
  'a day cap of one allows the first call'
);

select is(
  private.check_rate_limit('t:day', null, null, null, 1) ->> 'error',
  'DAILY_LIMIT_REACHED',
  'and refuses the second with the code §7.4 keeps for a daily cap'
);

select ok(
  (private.check_rate_limit('t:day', null, null, null, 1) ->> 'retry_after')::int
    between 1 and 86400,
  'the wait it reports is the rest of the Asia/Kolkata day, never a negative'
);

-- §7.3: limits are halved for accounts less than 72 hours old.
select is(
  (select count(*)::int from (
     select private.check_rate_limit(
       't:young', '11111111-1111-1111-1111-111111111111', null, null, 4) as r
     from generate_series(1, 2)) s
   where s.r is not null),
  0,
  'an account ten hours old gets two of a cap of four'
);

select is(
  private.check_rate_limit('t:young', '11111111-1111-1111-1111-111111111111',
    null, null, 4) ->> 'error',
  'DAILY_LIMIT_REACHED',
  'and is refused the third, which a full cap of four would have allowed'
);

select is(
  (select count(*)::int from (
     select private.check_rate_limit(
       't:old', '22222222-2222-2222-2222-222222222222', null, null, 4) as r
     from generate_series(1, 4)) s
   where s.r is not null),
  0,
  'an account past 72 hours gets the whole cap'
);

-- §7.3 fixes the halving but not its rounding; rounding up is what keeps the
-- smallest caps usable. An odd cap of 5 gives a new account 3, not 2.
select is(
  (select count(*)::int from (
     select private.check_rate_limit(
       't:odd', '11111111-1111-1111-1111-111111111111', null, null, 5) as r
     from generate_series(1, 3)) s
   where s.r is not null),
  0,
  'an odd cap rounds the new account''s half up, so five a day becomes three'
);

-- A cap of 1 would floor to 0 and lock a new account out of the route altogether,
-- rather than slowing it down.
select is(
  private.check_rate_limit('t:floor', '11111111-1111-1111-1111-111111111111',
    null, null, 1) ->> 'error',
  null,
  'and a cap of one still allows one call'
);

-- §12.2 accepts that a refused request costs a write; that is also what keeps a
-- caller who ignores Retry-After refused for the rest of the window.
select is(
  (select hits from private.rate_limit_hits where bucket = 't:minute:minute'),
  4,
  'a refused call still counts, so hammering does not reset the window'
);

-- §7.3 caps six routes by the hour, and nothing above exercises that window.
select is(
  (select count(*)::int from (
     select private.check_rate_limit('t:hourly', null, null, 2, null) as r
     from generate_series(1, 2)) s
   where s.r is not null),
  0,
  'an hourly cap allows its two calls'
);

select is(
  private.check_rate_limit('t:hourly', null, null, 2, null) ->> 'error',
  'RATE_LIMITED',
  'and refuses the third as a rate, not as a daily cap'
);

-- §17.1: when more than one window is over, the longest is reported. A caller over
-- both has to come back tomorrow either way, so naming the minute would send them
-- back in sixty seconds to be refused again.
select is(
  private.check_rate_limit('t:both', null, 1, null, 1),
  null,
  'one a minute and one a day both allow the first call'
);

select is(
  private.check_rate_limit('t:both', null, 1, null, 1) ->> 'error',
  'DAILY_LIMIT_REACHED',
  'and over both at once, the day is what the caller is told'
);

reset role;
select * from finish();
rollback;
