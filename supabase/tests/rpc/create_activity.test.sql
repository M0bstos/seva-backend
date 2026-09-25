begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

insert into auth.users (id, created_at) values
  ('11111111-1111-1111-1111-111111111111', now() - interval '30 days'),
  ('22222222-2222-2222-2222-222222222222', now() - interval '30 days'),
  ('33333333-3333-3333-3333-333333333333', now() - interval '30 days');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'adult'),
  ('22222222-2222-2222-2222-222222222222', 'minor'),
  ('33333333-3333-3333-3333-333333333333', 'eighteen today');
insert into profile_private (user_id, date_of_birth, terms_version, privacy_version) values
  ('11111111-1111-1111-1111-111111111111', '1995-04-04', '2026-10-01', '2026-10-01'),
  ('22222222-2222-2222-2222-222222222222', '2010-04-04', '2026-10-01', '2026-10-01'),
  ('33333333-3333-3333-3333-333333333333',
   ((now() at time zone 'Asia/Kolkata')::date - interval '18 years')::date,
   '2026-10-01', '2026-10-01');

insert into campaigns (id, title, description, goal_metric, goal_value, starts_on, ends_on, status)
values
  ('cccc0000-0000-0000-0000-000000000001', 'Clean the lake',
   'Volunteers clearing plastic from the lake shore every weekend.',
   'waste_kg', 5000, '2026-10-01', '2026-12-31', 'active'),
  ('cccc0000-0000-0000-0000-000000000002', 'Finished drive',
   'A campaign that has already ended and cannot take new activities.',
   'trees_planted', 100, '2026-01-01', '2026-02-01', 'ended');

select ok(
  not has_function_privilege('anon',
    'create_activity(uuid,text,text,category,timestamptz,timestamptz,double precision,double precision,text,int,text,uuid,uuid[],uuid,text,text,int,int,int)',
    'execute'),
  'no client can call the create function directly (§9.1)'
);

set local role service_role;

select is(
  create_activity('11111111-1111-1111-1111-111111111111', 'Lake shore cleanup',
    'Bring gloves and water. We meet at the east gate and finish before noon.',
    'environment', '2026-11-01T03:30:00Z', '2026-11-01T06:30:00Z',
    73.8567, 18.5204, 'East gate, Pashan Lake', 40, null,
    'cccc0000-0000-0000-0000-000000000001', '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000a1', repeat('a', 64), 'act:u1', null, null, 5
  ) #>> '{activity,status}',
  'pending',
  'a new activity arrives pending (§7.3)'
);

select is(
  (select participant_count from activities where organiser_id = '11111111-1111-1111-1111-111111111111'),
  0,
  'and uncounted'
);

-- §5.4: an Activity's meeting point is stored exactly, because it is a public event.
select is(
  (select extensions.st_astext(location) from activities
   where organiser_id = '11111111-1111-1111-1111-111111111111'),
  'POINT(73.8567 18.5204)',
  'the meeting point is stored exactly, unlike an act''s (§5.4)'
);

-- §9.6: "Can't create Activities (AGE_RESTRICTED). Every organiser is an adult."
select is(
  create_activity('22222222-2222-2222-2222-222222222222', 'Minor organiser',
    'Bring gloves and water. We meet at the east gate and finish before noon.',
    'environment', '2026-11-01T03:30:00Z', '2026-11-01T06:30:00Z',
    73.8567, 18.5204, 'East gate', 40, null, null, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000a2', repeat('b', 64), 'act:u2', null, null, 5
  ) ->> 'error',
  'AGE_RESTRICTED',
  'an author under 18 cannot organise (§9.6)'
);

select is(
  create_activity('33333333-3333-3333-3333-333333333333', 'Eighteen today',
    'Bring gloves and water. We meet at the east gate and finish before noon.',
    'environment', '2026-11-01T03:30:00Z', '2026-11-01T06:30:00Z',
    73.8567, 18.5204, 'East gate', 40, null, null, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000a3', repeat('c', 64), 'act:u3', null, null, 5
  ) #>> '{activity,status}',
  'pending',
  'and someone who turns 18 today can (§9.6 calculates age on every request)'
);

-- §17.1: a categorically barred request must not spend a cap.
select is(
  (select count(*)::int from private.rate_limit_hits where bucket like 'act:u2%'),
  0,
  'the barred attempt spent no cap, because age is checked before the count (§17.1)'
);

-- §17 O17: the restrict foreign key does not check status, so the function must.
select is(
  create_activity('11111111-1111-1111-1111-111111111111', 'Ended campaign',
    'Bring gloves and water. We meet at the east gate and finish before noon.',
    'environment', '2026-11-01T03:30:00Z', '2026-11-01T06:30:00Z',
    73.8567, 18.5204, 'East gate', 40, null,
    'cccc0000-0000-0000-0000-000000000002', '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000a4', repeat('d', 64), 'act:u1', null, null, 5
  ) ->> 'error',
  'NOT_FOUND',
  'an activity cannot be attached to a campaign that has ended (§17 O17)'
);

-- §7.1.1.
select is(
  create_activity('11111111-1111-1111-1111-111111111111', 'Lake shore cleanup',
    'Bring gloves and water. We meet at the east gate and finish before noon.',
    'environment', '2026-11-01T03:30:00Z', '2026-11-01T06:30:00Z',
    73.8567, 18.5204, 'East gate, Pashan Lake', 40, null,
    'cccc0000-0000-0000-0000-000000000001', '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000a1', repeat('a', 64), 'act:u1', null, null, 5
  ) ->> 'replayed',
  'true',
  'the same key and the same body returns the original (§7.1.1)'
);

select is(
  create_activity('11111111-1111-1111-1111-111111111111', 'A different activity',
    'Bring gloves and water. We meet at the east gate and finish before noon.',
    'community', '2026-11-02T03:30:00Z', '2026-11-02T06:30:00Z',
    73.8567, 18.5204, 'East gate', 40, null, null, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000a1', repeat('e', 64), 'act:u1', null, null, 5
  ) ->> 'error',
  'IDEMPOTENCY_KEY_REUSED',
  'and the same key with a different body is refused (§7.1.1)'
);

-- §5.2.1 bounds the times and capacity; a body past the route must not raise.
select is(
  create_activity('11111111-1111-1111-1111-111111111111', 'Two days long',
    'Bring gloves and water. We meet at the east gate and finish before noon.',
    'environment', '2026-11-05T03:30:00Z', '2026-11-07T03:30:00Z',
    73.8567, 18.5204, 'East gate', 40, null, null, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000a5', repeat('1', 64), 'act:u1', null, null, 5
  ) ->> 'error',
  'VALIDATION_FAILED',
  'an activity longer than 24 hours is refused, not raised (§5.2.1)'
);

select is(
  create_activity('11111111-1111-1111-1111-111111111111', 'Too many people',
    'Bring gloves and water. We meet at the east gate and finish before noon.',
    'environment', '2026-11-05T03:30:00Z', '2026-11-05T06:30:00Z',
    73.8567, 18.5204, 'East gate', 1001, null, null, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000a6', repeat('2', 64), 'act:u1', null, null, 5
  ) ->> 'error',
  'VALIDATION_FAILED',
  'and so is a capacity over the thousand §5.2.1 allows'
);

select is(
  create_activity('44444444-4444-4444-4444-444444444444', 'No profile',
    'Bring gloves and water. We meet at the east gate and finish before noon.',
    'environment', '2026-11-05T03:30:00Z', '2026-11-05T06:30:00Z',
    73.8567, 18.5204, 'East gate', 40, null, null, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000a7', repeat('3', 64), 'act:u4', null, null, 5
  ) ->> 'error',
  'ONBOARDING_REQUIRED',
  'someone without a profile row cannot organise (§5.4)'
);

select is(
  create_activity('11111111-1111-1111-1111-111111111111', 'Over the cap',
    'Bring gloves and water. We meet at the east gate and finish before noon.',
    'environment', '2026-11-05T03:30:00Z', '2026-11-05T06:30:00Z',
    73.8567, 18.5204, 'East gate', 40, null, null, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000a8', repeat('4', 64), 'act:capped', null, null, 0
  ) ->> 'error',
  'DAILY_LIMIT_REACHED',
  '§7.3 caps organising at five a day'
);

reset role;
update profiles set status = 'suspended' where id = '11111111-1111-1111-1111-111111111111';
set local role service_role;
select is(
  create_activity('11111111-1111-1111-1111-111111111111', 'Suspended organiser',
    'Bring gloves and water. We meet at the east gate and finish before noon.',
    'environment', '2026-11-05T03:30:00Z', '2026-11-05T06:30:00Z',
    73.8567, 18.5204, 'East gate', 40, null, null, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000a9', repeat('5', 64), 'act:susp', null, null, 5
  ) ->> 'error',
  'FORBIDDEN',
  'a suspended account cannot organise either (§17 O33)'
);
reset role;
update profiles set status = 'active' where id = '11111111-1111-1111-1111-111111111111';
update app_flags set engaged = true where key = 'create_activities';
set local role service_role;
select is(
  create_activity('11111111-1111-1111-1111-111111111111', 'Switched off',
    'Bring gloves and water. We meet at the east gate and finish before noon.',
    'environment', '2026-11-05T03:30:00Z', '2026-11-05T06:30:00Z',
    73.8567, 18.5204, 'East gate', 40, null, null, '{}'::uuid[],
    '00000000-0000-0000-0000-0000000000b1', repeat('6', 64), 'act:flag', null, null, 5
  ) ->> 'error',
  'FEATURE_DISABLED',
  'and the create_activities kill switch stops it (§10.2)'
);

reset role;
update app_flags set engaged = false where key = 'create_activities';

-- §17.1: onboarding and age sit above the limiter so a caller barred by a rule they
-- cannot see is not billed; suspension sits below it, because a suspended account has
-- already been judged abusive and must not get the unmetered path.
select is(
  (select hits from private.rate_limit_hits where bucket = 'act:susp:day'),
  1,
  'a suspended caller is billed for the attempt, unlike a barred minor'
);

select * from finish();
rollback;
