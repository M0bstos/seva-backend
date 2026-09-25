begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

insert into auth.users (id, created_at)
select ('00000000-0000-0000-0000-00000000000' || n)::uuid, now() - interval '30 days'
from generate_series(1, 5) n;
insert into profiles (id, display_name)
select ('00000000-0000-0000-0000-00000000000' || n)::uuid, 'person ' || n
from generate_series(1, 5) n;

insert into activities
  (id, organiser_id, title, description, category, starts_at, ends_at, location,
   location_label, capacity, status, cancelled_at, idempotency_key, request_hash)
values
  -- room for two
  ('aaaa0000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001',
   'Small cleanup', 'Bring gloves and water. We meet at the east gate at dawn.',
   'environment', now() + interval '10 days', now() + interval '10 days 3 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'East gate', 2, 'visible', null, '00000000-0000-0000-0000-0000000000f1', repeat('f', 64)),
  ('aaaa0000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001',
   'Unscreened', 'Bring gloves and water. We meet at the east gate at dawn.',
   'environment', now() + interval '10 days', now() + interval '10 days 3 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'East gate', 40, 'pending', null, '00000000-0000-0000-0000-0000000000f2', repeat('e', 64)),
  ('aaaa0000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001',
   'Cancelled', 'Bring gloves and water. We meet at the east gate at dawn.',
   'environment', now() + interval '10 days', now() + interval '10 days 3 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'East gate', 40, 'visible', now(), '00000000-0000-0000-0000-0000000000f3', repeat('d', 64)),
  ('aaaa0000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001',
   'Already started', 'Bring gloves and water. We meet at the east gate at dawn.',
   'environment', now() - interval '1 hour', now() + interval '2 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'East gate', 40, 'visible', null, '00000000-0000-0000-0000-0000000000f4', repeat('c', 64));

select ok(
  not has_function_privilege('anon', 'join_activity(uuid,uuid,text,int,int,int)', 'execute')
  and not has_function_privilege('authenticated',
        'join_activity(uuid,uuid,text,int,int,int)', 'execute'),
  'no client can join directly and skip the capacity lock (§9.1)'
);

set local role service_role;

select is(
  (join_activity('00000000-0000-0000-0000-000000000002',
    'aaaa0000-0000-0000-0000-000000000001', 'join:u2', null, 30, null)
   ->> 'already_joined'),
  'false',
  'a first join takes a place'
);

select is(
  (select participant_count from activities where id = 'aaaa0000-0000-0000-0000-000000000001'),
  1,
  'and the trigger counts it in the same transaction (§5.4)'
);

-- §7.3: "Joining twice returns the existing row."
select is(
  (join_activity('00000000-0000-0000-0000-000000000002',
    'aaaa0000-0000-0000-0000-000000000001', 'join:u2', null, 30, null)
   ->> 'already_joined'),
  'true',
  'joining twice returns the existing row (§7.3)'
);

select is(
  (select participant_count from activities where id = 'aaaa0000-0000-0000-0000-000000000001'),
  1,
  'and does not take a second place'
);

select is(
  (join_activity('00000000-0000-0000-0000-000000000003',
    'aaaa0000-0000-0000-0000-000000000001', 'join:u3', null, 30, null)
   ->> 'participant_count'),
  '2',
  'the second person fills the activity, and reads the count after the trigger'
);

-- §7.4: ACTIVITY_FULL, "No places left".
select is(
  join_activity('00000000-0000-0000-0000-000000000004',
    'aaaa0000-0000-0000-0000-000000000001', 'join:u4', null, 30, null) ->> 'error',
  'ACTIVITY_FULL',
  'and the third is refused (§7.4)'
);

select is(
  (select participant_count from activities where id = 'aaaa0000-0000-0000-0000-000000000001'),
  2,
  'the count never goes past capacity, which §5.2.1 also checks'
);

-- §7.4: ACTIVITY_NOT_JOINABLE, "Started, cancelled, or not yet visible".
select is(
  join_activity('00000000-0000-0000-0000-000000000002',
    'aaaa0000-0000-0000-0000-000000000002', 'join:u2', null, 30, null) ->> 'error',
  'ACTIVITY_NOT_JOINABLE',
  'an activity still in screening cannot be joined (§7.4)'
);

select is(
  join_activity('00000000-0000-0000-0000-000000000002',
    'aaaa0000-0000-0000-0000-000000000003', 'join:u2', null, 30, null) ->> 'error',
  'ACTIVITY_NOT_JOINABLE',
  'nor a cancelled one'
);

select is(
  join_activity('00000000-0000-0000-0000-000000000002',
    'aaaa0000-0000-0000-0000-000000000004', 'join:u2', null, 30, null) ->> 'error',
  'ACTIVITY_NOT_JOINABLE',
  'nor one that has already started'
);

select is(
  join_activity('00000000-0000-0000-0000-000000000002',
    'aaaa0000-0000-0000-0000-00000000dead', 'join:u2', null, 30, null) ->> 'error',
  'NOT_FOUND',
  'nor one that does not exist'
);

select is(
  join_activity('99999999-9999-9999-9999-999999999999',
    'aaaa0000-0000-0000-0000-000000000001', 'join:u9', null, 30, null) ->> 'error',
  'ONBOARDING_REQUIRED',
  'someone without a profile row cannot join (§5.4)'
);

reset role;
update app_flags set engaged = true where key = 'joins';
set local role service_role;
select is(
  join_activity('00000000-0000-0000-0000-000000000005',
    'aaaa0000-0000-0000-0000-000000000001', 'join:u5', null, 30, null) ->> 'error',
  'FEATURE_DISABLED',
  'and the joins kill switch stops it (§10.2)'
);
reset role;
update app_flags set engaged = false where key = 'joins';
update app_flags set engaged = true where key = 'read_only';
set local role service_role;
select is(
  join_activity('00000000-0000-0000-0000-000000000005',
    'aaaa0000-0000-0000-0000-000000000001', 'join:u5', null, 30, null) ->> 'error',
  'FEATURE_DISABLED',
  'and so does read_only, which stops every write at once'
);
reset role;
update app_flags set engaged = false where key = 'read_only';

-- §17 O33: joining is content, so a suspended account is refused.
update profiles set status = 'suspended' where id = '00000000-0000-0000-0000-000000000005';
set local role service_role;
select is(
  join_activity('00000000-0000-0000-0000-000000000005',
    'aaaa0000-0000-0000-0000-000000000001', 'join:u5', null, 30, null) ->> 'error',
  'FORBIDDEN',
  'a suspended account cannot join (§17 O33)'
);
reset role;
update profiles set status = 'active' where id = '00000000-0000-0000-0000-000000000005';

select * from finish();
rollback;
