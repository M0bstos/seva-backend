begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'anand'),
  ('22222222-2222-2222-2222-222222222222', 'bina');
insert into activities
  (id, organiser_id, title, description, category, starts_at, ends_at, location,
   location_label, capacity, status, idempotency_key, request_hash)
values
  ('aaaa0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'Lake shore cleanup', 'Bring gloves and water. We meet at the east gate at dawn.',
   'environment', '2026-11-01T03:30:00Z', '2026-11-01T06:30:00Z',
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'East gate', 40, 'visible', '00000000-0000-0000-0000-0000000000f1', repeat('f', 64));

-- §9.2 gives participant_count no client write path, which is why the trigger is
-- definer at all (§17.1).
select is_empty(
  $$ select r.rolname from (values ('anon'::name), ('authenticated'::name),
                                   ('service_role'::name)) as r (rolname)
     where has_column_privilege(r.rolname, 'public.activities', 'participant_count',
                                'INSERT, UPDATE') $$,
  'no role can write the count directly, which is what makes a definer trigger right'
);

select ok(
  not has_function_privilege('anon', 'count_activity_participants()', 'execute')
  and not has_function_privilege('authenticated', 'count_activity_participants()', 'execute')
  and not has_function_privilege('service_role', 'count_activity_participants()', 'execute'),
  'and nobody can call the trigger function, which gate 3 also asserts'
);

select is(
  (select prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'count_activity_participants'),
  true,
  'it is security definer, per §17.1'
);

set local role service_role;

insert into activity_participants (activity_id, user_id) values
  ('aaaa0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111'),
  ('aaaa0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222');

select is(
  (select participant_count from activities where id = 'aaaa0000-0000-0000-0000-000000000001'),
  2,
  'joining counts up in the same transaction as the join (§5.4)'
);

update activity_participants set status = 'left', left_at = now()
where activity_id = 'aaaa0000-0000-0000-0000-000000000001'
  and user_id = '22222222-2222-2222-2222-222222222222';

select is(
  (select participant_count from activities where id = 'aaaa0000-0000-0000-0000-000000000001'),
  1,
  'and leaving counts down'
);

-- A second leave writes the same status, so the count must not drift.
update activity_participants set left_at = now() - interval '1 minute'
where activity_id = 'aaaa0000-0000-0000-0000-000000000001'
  and user_id = '22222222-2222-2222-2222-222222222222';

select is(
  (select participant_count from activities where id = 'aaaa0000-0000-0000-0000-000000000001'),
  1,
  'an update that does not cross the joined boundary moves nothing'
);

update activity_participants set status = 'joined', left_at = null
where activity_id = 'aaaa0000-0000-0000-0000-000000000001'
  and user_id = '22222222-2222-2222-2222-222222222222';

select is(
  (select participant_count from activities where id = 'aaaa0000-0000-0000-0000-000000000001'),
  2,
  'and re-joining counts up again'
);

reset role;

-- §5.4: account deletion removes participations, and the row goes by cascade rather
-- than through the leave function.
delete from profiles where id = '22222222-2222-2222-2222-222222222222';

select is(
  (select participant_count from activities where id = 'aaaa0000-0000-0000-0000-000000000001'),
  1,
  'a deleted account takes its place with it, so the count stays true (§5.4)'
);

-- §5.2.1 caps the count at capacity, and the trigger must not be able to breach it.
set local role service_role;
select throws_ok(
  $$ update activities set status = 'visible' where 1 = 0;
     update public.activities set participant_count = 41
     where id = 'aaaa0000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'and the backend cannot set the count by hand to get around the trigger'
);
reset role;

select is(
  (select count(*)::int from activities
   where id = 'aaaa0000-0000-0000-0000-000000000001'
     and participant_count between 0 and capacity),
  1,
  'the count stays inside the check §5.2.1 puts on it'
);

select * from finish();
rollback;
