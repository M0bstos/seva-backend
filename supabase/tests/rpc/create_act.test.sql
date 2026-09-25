begin;
create extension if not exists pgtap with schema extensions;
select plan(32);

insert into auth.users (id, created_at) values
  ('11111111-1111-1111-1111-111111111111', now() - interval '30 days'),
  ('22222222-2222-2222-2222-222222222222', now() - interval '30 days');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'anand'),
  ('22222222-2222-2222-2222-222222222222', 'bina');
insert into profile_private (user_id, date_of_birth, terms_version, privacy_version) values
  ('11111111-1111-1111-1111-111111111111', '1995-04-04', '2026-10-01', '2026-10-01'),
  ('22222222-2222-2222-2222-222222222222', '1990-01-01', '2026-10-01', '2026-10-01');

insert into activities
  (id, organiser_id, title, description, category, starts_at, ends_at, location,
   location_label, capacity, status, idempotency_key, request_hash)
values
  ('aaaa0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
   'Lake shore cleanup', 'Bring gloves and water. We meet at the east gate at dawn.',
   'environment', '2026-11-01T03:30:00Z', '2026-11-01T06:30:00Z',
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'East gate', 40, 'visible', '00000000-0000-0000-0000-0000000000f1', repeat('f', 64));

insert into media (id, owner_id, purpose, upload_path, status) values
  ('bbbb0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'act', 'uploads/anand/1.jpg', 'ready'),
  ('bbbb0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'act', 'uploads/anand/2.jpg', 'processing'),
  ('bbbb0000-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222',
   'act', 'uploads/bina/1.jpg', 'ready'),
  ('bbbb0000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111',
   'act', 'uploads/anand/3.jpg', 'ready');

select ok(
  not has_function_privilege('anon', 'create_act(uuid,text,text,category,date,double precision,double precision,uuid,jsonb,uuid[],uuid,text,text,int,int,int)', 'execute')
  and not has_function_privilege('authenticated', 'create_act(uuid,text,text,category,date,double precision,double precision,uuid,jsonb,uuid[],uuid,text,text,int,int,int)', 'execute'),
  'no client can call the create function directly and skip its rate limit (§9.1)'
);

select ok(
  has_function_privilege('service_role', 'create_act(uuid,text,text,category,date,double precision,double precision,uuid,jsonb,uuid[],uuid,text,text,int,int,int)', 'execute'),
  'the acts route reaches it on its secret key'
);

set local role service_role;

-- The happy path: §7.3 says a new Act arrives pending.
select is(
  create_act('11111111-1111-1111-1111-111111111111', 'Lake cleanup',
    'A story long enough to pass the twenty character minimum the table checks.',
    'environment', '2026-09-20', 73.856743, 18.520430, null,
    '{"waste_kg": 12.5}'::jsonb, array['bbbb0000-0000-0000-0000-000000000001']::uuid[],
    '00000000-0000-0000-0000-0000000000a1', repeat('a', 64), 'acts:u1', null, 10, 30
  ) #>> '{act,status}',
  'pending',
  'a new act arrives pending, whatever the caller asked for'
);

select is(
  (select count(*)::int from acts where author_id = '11111111-1111-1111-1111-111111111111'),
  1,
  'and exactly one row was written'
);

select is(
  (select value::text from act_metrics where metric = 'waste_kg'),
  '12.50',
  'its claimed metric is stored alongside it'
);

select is(
  (select position::int from media where id = 'bbbb0000-0000-0000-0000-000000000001'),
  0,
  'and the photo is attached in the order it was given (§17 O20)'
);

select isnt(
  (select extensions.st_astext(location_coarse) from acts limit 1),
  'POINT(73.856743 18.52043)',
  'the raw point never reaches the row: the trigger coarsened it (§5.4)'
);

-- §7.1.1: same key, same hash.
select is(
  create_act('11111111-1111-1111-1111-111111111111', 'Lake cleanup',
    'A story long enough to pass the twenty character minimum the table checks.',
    'environment', '2026-09-20', 73.856743, 18.520430, null,
    '{"waste_kg": 12.5}'::jsonb, array['bbbb0000-0000-0000-0000-000000000001']::uuid[],
    '00000000-0000-0000-0000-0000000000a1', repeat('a', 64), 'acts:u1', null, 10, 30
  ) ->> 'replayed',
  'true',
  'the same key and the same body returns the original rather than a second act'
);

select is(
  (select count(*)::int from acts where author_id = '11111111-1111-1111-1111-111111111111'),
  1,
  'and writes nothing'
);

-- A replay creates no Act, so §7.3's cap on creating one does not bill it.
select is(
  (select hits from private.rate_limit_hits where bucket = 'acts:u1:hour'),
  1,
  'a replay does not spend the caller''s hourly budget'
);

select is(
  create_act('11111111-1111-1111-1111-111111111111', 'A different story entirely',
    'Another story long enough to pass the twenty character minimum check.',
    'community', '2026-09-21', 73.856743, 18.520430, null,
    '{}'::jsonb, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000a1', repeat('b', 64), 'acts:u1', null, 10, 30
  ) ->> 'error',
  'IDEMPOTENCY_KEY_REUSED',
  'the same key with a different body is refused (§7.1.1)'
);

-- §5.4's onboarding gate: no profile row, no writing.
select is(
  create_act('33333333-3333-3333-3333-333333333333', 'No profile',
    'A story long enough to pass the twenty character minimum the table checks.',
    'community', '2026-09-20', 73.85, 18.52, null, '{}'::jsonb, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000a2', repeat('c', 64), 'acts:u3', null, 10, 30
  ) ->> 'error',
  'ONBOARDING_REQUIRED',
  'someone without a profile row cannot write (§5.4)'
);

select is(
  create_act('11111111-1111-1111-1111-111111111111', 'Claim with no proof',
    'A story long enough to pass the twenty character minimum the table checks.',
    'community', '2026-09-20', 73.85, 18.52, null,
    '{"trees_planted": 5}'::jsonb, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000a3', repeat('d', 64), 'acts:u1', null, 10, 30
  ) ->> 'error',
  'EVIDENCE_REQUIRED',
  'metrics claimed without a photo have nothing behind them (§7.4)'
);

-- §6.3: trees_planted maxes at 200 per act, and a value above it is refused.
select is(
  create_act('11111111-1111-1111-1111-111111111111', 'An absurd claim',
    'A story long enough to pass the twenty character minimum the table checks.',
    'community', '2026-09-20', 73.85, 18.52, null,
    '{"trees_planted": 5000}'::jsonb, array['bbbb0000-0000-0000-0000-000000000004']::uuid[],
    '00000000-0000-0000-0000-0000000000a4', repeat('e', 64), 'acts:u1', null, 10, 30
  ) ->> 'error',
  'METRIC_OUT_OF_RANGE',
  'a value over its per-act maximum is refused, not clipped (§6.3)'
);

select is(
  create_act('11111111-1111-1111-1111-111111111111', 'Borrowed photo',
    'A story long enough to pass the twenty character minimum the table checks.',
    'community', '2026-09-20', 73.85, 18.52, null, '{}'::jsonb,
    array['bbbb0000-0000-0000-0000-000000000003']::uuid[],
    '00000000-0000-0000-0000-0000000000a5', repeat('1', 64), 'acts:u1', null, 10, 30
  ) ->> 'error',
  'FORBIDDEN',
  'a photo belonging to someone else cannot be attached (§8.1)'
);

select is(
  create_act('11111111-1111-1111-1111-111111111111', 'Invisible activity',
    'A story long enough to pass the twenty character minimum the table checks.',
    'community', '2026-09-20', 73.85, 18.52,
    'aaaa0000-0000-0000-0000-00000000dead'::uuid, '{}'::jsonb, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000a6', repeat('2', 64), 'acts:u1', null, 10, 30
  ) ->> 'error',
  'NOT_FOUND',
  'an activity the caller cannot see is missing as far as they are concerned (§7.4)'
);

select is(
  create_act('11111111-1111-1111-1111-111111111111', 'Documented activity',
    'A story long enough to pass the twenty character minimum the table checks.',
    'environment', '2026-09-20', 73.85, 18.52,
    'aaaa0000-0000-0000-0000-000000000001'::uuid, '{}'::jsonb, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000a7', repeat('3', 64), 'acts:u1', null, 10, 30
  ) #>> '{act,activity_id}',
  'aaaa0000-0000-0000-0000-000000000001',
  'a visible activity can be documented by anyone who can see it'
);

-- §12.2, and §17.1's rule that content checks sit after the count.
select is(
  create_act('22222222-2222-2222-2222-222222222222', 'One too many',
    'A story long enough to pass the twenty character minimum the table checks.',
    'community', '2026-09-20', 73.85, 18.52, null, '{}'::jsonb, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000b1', repeat('4', 64), 'acts:u2', null, 0, 30
  ) ->> 'error',
  'RATE_LIMITED',
  'the limiter refuses before any of the act is written'
);

-- §5.2 gives app_flags one writer, an admin function, so the switch is thrown here
-- as the owner rather than on the secret key the route holds.
reset role;
update app_flags set engaged = true where key = 'create_acts';
set local role service_role;
select is(
  create_act('11111111-1111-1111-1111-111111111111', 'Switched off',
    'A story long enough to pass the twenty character minimum the table checks.',
    'community', '2026-09-20', 73.85, 18.52, null, '{}'::jsonb, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000a8', repeat('5', 64), 'acts:u1', null, 10, 30
  ) ->> 'error',
  'FEATURE_DISABLED',
  'the create_acts kill switch stops it (§10.2)'
);
reset role;
update app_flags set engaged = false where key = 'create_acts';
update app_flags set engaged = true where key = 'read_only';
set local role service_role;
select is(
  create_act('11111111-1111-1111-1111-111111111111', 'Read only',
    'A story long enough to pass the twenty character minimum the table checks.',
    'community', '2026-09-20', 73.85, 18.52, null, '{}'::jsonb, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000a9', repeat('6', 64), 'acts:u1', null, 10, 30
  ) ->> 'error',
  'FEATURE_DISABLED',
  'and so does read_only, which stops every write at once'
);
reset role;
update app_flags set engaged = false where key = 'read_only';
set local role service_role;

-- §7.1.1 calls a key reused with a different body a rejection, not a replay, so it is
-- metered. Without this an onboarded caller has an unbilled path at the database,
-- which is the one thing §12.2's D5 note does not accept.
select is(
  (select count(*)::int from (
     select create_act('11111111-1111-1111-1111-111111111111', 'Reused key',
       'A story long enough to pass the twenty character minimum the table checks.',
       'community', '2026-09-20', 73.85, 18.52, null, '{}'::jsonb, '{}'::uuid[],
       '00000000-0000-0000-0000-0000000000a1', repeat('z', 64), 'acts:meter', null, 50, 50
     ) ->> 'error' as e
     from generate_series(1, 3)) s
   where s.e = 'IDEMPOTENCY_KEY_REUSED'),
  3,
  'a key reused with a different body is refused every time'
);

select is(
  (select hits from private.rate_limit_hits where bucket = 'acts:meter:hour'),
  3,
  'and each refusal is counted: §7.1.1 calls it a rejection, not a replay'
);

-- §6.3 gives max_per_act the job of keeping absurd claims out of the ledger, which is
-- not points_per_unit's job of scoring them, so switching a rule off must not remove
-- its bound.
reset role;
update points_rules set active = false where rule = 'trees_planted';
set local role service_role;
select is(
  create_act('11111111-1111-1111-1111-111111111111', 'Inactive rule',
    'A story long enough to pass the twenty character minimum the table checks.',
    'community', '2026-09-20', 73.85, 18.52, null,
    '{"trees_planted": 99999}'::jsonb, array['bbbb0000-0000-0000-0000-000000000002']::uuid[],
    '00000000-0000-0000-0000-0000000000c1', repeat('7', 64), 'acts:bad', null, 50, 50
  ) ->> 'error',
  'METRIC_OUT_OF_RANGE',
  'a rule switched off still caps the claim: active governs scoring, not validity'
);
reset role;
update points_rules set active = true where rule = 'trees_planted';
set local role service_role;

select is(
  create_act('11111111-1111-1111-1111-111111111111', 'Already attached',
    'A story long enough to pass the twenty character minimum the table checks.',
    'community', '2026-09-20', 73.85, 18.52, null, '{}'::jsonb,
    array['bbbb0000-0000-0000-0000-000000000001']::uuid[],
    '00000000-0000-0000-0000-0000000000c2', repeat('8', 64), 'acts:bad', null, 50, 50
  ) ->> 'error',
  'FORBIDDEN',
  'a photo already on another act cannot be moved off it by naming it again'
);

select is(
  create_act('11111111-1111-1111-1111-111111111111', 'Too many photos',
    'A story long enough to pass the twenty character minimum the table checks.',
    'community', '2026-09-20', 73.85, 18.52, null, '{}'::jsonb,
    (select array_agg(gen_random_uuid()) from generate_series(1, 11)),
    '00000000-0000-0000-0000-0000000000c3', repeat('9', 64), 'acts:bad', null, 50, 50
  ) ->> 'error',
  'VALIDATION_FAILED',
  'eleven photos is more than §8.1 allows'
);

-- Each of these would otherwise reach a cast or a table check and raise, which the
-- route can only answer as INTERNAL — and §7.4 marks that retryable, so a
-- permanently malformed body would be retried for ever.
select is(
  create_act('11111111-1111-1111-1111-111111111111', 'Metric not a number',
    'A story long enough to pass the twenty character minimum the table checks.',
    'community', '2026-09-20', 73.85, 18.52, null,
    '{"waste_kg": "lots"}'::jsonb, array['bbbb0000-0000-0000-0000-000000000004']::uuid[],
    '00000000-0000-0000-0000-0000000000c4', repeat('a', 63) || 'b', 'acts:bad', null, 50, 50
  ) ->> 'error',
  'VALIDATION_FAILED',
  'a metric whose value is not a number is refused, not raised'
);

select is(
  create_act('11111111-1111-1111-1111-111111111111', 'Metric not a metric',
    'A story long enough to pass the twenty character minimum the table checks.',
    'community', '2026-09-20', 73.85, 18.52, null,
    '{"act_published": 5}'::jsonb, array['bbbb0000-0000-0000-0000-000000000004']::uuid[],
    '00000000-0000-0000-0000-0000000000c5', repeat('a', 62) || 'cd', 'acts:bad', null, 50, 50
  ) ->> 'error',
  'VALIDATION_FAILED',
  'a points rule that is not a metric is refused, not raised'
);

select is(
  create_act('11111111-1111-1111-1111-111111111111', 'Half a tree',
    'A story long enough to pass the twenty character minimum the table checks.',
    'community', '2026-09-20', 73.85, 18.52, null,
    '{"trees_planted": 0.5}'::jsonb, array['bbbb0000-0000-0000-0000-000000000004']::uuid[],
    '00000000-0000-0000-0000-0000000000c6', repeat('a', 62) || 'ef', 'acts:bad', null, 50, 50
  ) ->> 'error',
  'VALIDATION_FAILED',
  'a fractional count is refused here rather than by the table check (§5.2.1)'
);

select is(
  create_act('22222222-2222-2222-2222-222222222222', 'Daily cap',
    'A story long enough to pass the twenty character minimum the table checks.',
    'community', '2026-09-20', 73.85, 18.52, null, '{}'::jsonb, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000c7', repeat('b', 64), 'acts:daily', null, 10, 0
  ) ->> 'error',
  'DAILY_LIMIT_REACHED',
  'a daily cap answers with its own code, not the per-minute one (§7.4)'
);

-- §9.8 and §17.1: `field` is interpolated into the client-facing message, so it must
-- never carry caller text. Before the enum cast moved above the type check, a metrics
-- key was echoed back verbatim.
select is(
  create_act('11111111-1111-1111-1111-111111111111', 'Hostile metric key',
    'A story long enough to pass the twenty character minimum the table checks.',
    'community', '2026-09-20', 73.85, 18.52, null,
    '{"<img src=x onerror=alert(1)>": "x"}'::jsonb,
    array['bbbb0000-0000-0000-0000-000000000004']::uuid[],
    '00000000-0000-0000-0000-0000000000d1', repeat('d', 64), 'acts:bad', null, 50, 50
  ) ->> 'field',
  'metrics',
  'a metrics key the caller invented is never named back to them'
);

-- jsonb_each raises on a non-object, which the route could only answer as a retryable
-- INTERNAL, so a permanently malformed body would be retried for ever.
select is(
  create_act('11111111-1111-1111-1111-111111111111', 'Metrics not an object',
    'A story long enough to pass the twenty character minimum the table checks.',
    'community', '2026-09-20', 73.85, 18.52, null,
    '[1,2,3]'::jsonb, array['bbbb0000-0000-0000-0000-000000000004']::uuid[],
    '00000000-0000-0000-0000-0000000000d2', repeat('e', 64), 'acts:bad', null, 50, 50
  ) ->> 'error',
  'VALIDATION_FAILED',
  'a metrics payload that is not an object is refused, not raised'
);

-- §17 O33: this function bypasses the client policy, so suspension has to be checked
-- here or §10.2's suspension does nothing to writing until the token expires (§12.4).
reset role;
update profiles set status = 'suspended', suspended_until = now() + interval '7 days'
where id = '11111111-1111-1111-1111-111111111111';
set local role service_role;
select is(
  create_act('11111111-1111-1111-1111-111111111111', 'Suspended author',
    'A story long enough to pass the twenty character minimum the table checks.',
    'community', '2026-09-20', 73.85, 18.52, null, '{}'::jsonb, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000e1', repeat('c', 64), 'acts:bad', null, 50, 50
  ) ->> 'error',
  'FORBIDDEN',
  'a suspended account cannot write, even with an hour of token left'
);
reset role;
update profiles set status = 'active', suspended_until = null
where id = '11111111-1111-1111-1111-111111111111';

select * from finish();
rollback;
