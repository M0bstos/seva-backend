begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222'),
  ('33333333-3333-3333-3333-333333333333');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'anand'),
  ('22222222-2222-2222-2222-222222222222', 'bina'),
  ('33333333-3333-3333-3333-333333333333', 'chandra');
insert into activities
  (id, organiser_id, title, description, category, starts_at, ends_at,
   location, location_label, capacity, status, idempotency_key, request_hash)
values ('aaaa0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'Lake shore cleanup', 'Bring gloves and water. We meet at the east gate and finish by noon.',
   'environment', '2026-11-01T03:30:00Z', '2026-11-01T06:30:00Z',
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'East gate, Pashan Lake', 40, 'visible',
   '00000000-0000-0000-0000-0000000000a1', repeat('a', 64));
insert into activity_participants (activity_id, user_id) values
  ('aaaa0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111'),
  ('aaaa0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222');

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.activity_participants'::regclass and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'public.activity_participants', a.attname, 'insert')
       and a.attname not in ('activity_id', 'user_id') $$,
  'the join function supplies only the key; status and joined_at take their defaults'
);

select ok(
  has_table_privilege('authenticated', 'activity_participants', 'SELECT')
  and not has_table_privilege('authenticated', 'activity_participants',
    'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'activity_participants',
    'INSERT, UPDATE, REFERENCES'),
  'joining goes through the join function, never a direct insert'
);

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.activity_participants'::regclass
       and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'public.activity_participants', a.attname, 'update')
       and a.attname not in ('status', 'left_at') $$,
  'leaving updates only the status and the time, never whose place it was'
);

select throws_ok(
  $$ update activity_participants set status = 'left'
     where user_id = '11111111-1111-1111-1111-111111111111' $$,
  '23514',
  null,
  'a participant marked left must carry the time they left'
);

select throws_ok(
  $$ update activity_participants set left_at = now()
     where user_id = '11111111-1111-1111-1111-111111111111' $$,
  '23514',
  null,
  'and a left time cannot be set on someone who is still joined'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';

select results_eq(
  $$ select user_id from activity_participants $$,
  $$ values ('22222222-2222-2222-2222-222222222222'::uuid) $$,
  'a signed-in user sees only their own participation, never the attendee list'
);

select throws_ok(
  $$ insert into activity_participants (activity_id, user_id)
     values ('aaaa0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222') $$,
  '42501',
  null,
  'nobody joins by writing the table directly'
);

select throws_ok(
  $$ delete from activity_participants
     where user_id = '22222222-2222-2222-2222-222222222222' $$,
  '42501',
  null,
  'leaving is a status change, not a delete'
);

reset role;
set local role service_role;

select lives_ok(
  $$ insert into activity_participants (activity_id, user_id)
     values ('aaaa0000-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333') $$,
  'the join function takes a place'
);

select lives_ok(
  $$ update activity_participants set status = 'left', left_at = now()
     where user_id = '22222222-2222-2222-2222-222222222222' $$,
  'the leave function frees a place'
);

reset role;

select throws_ok(
  $$ insert into activity_participants (activity_id, user_id)
     values ('aaaa0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111') $$,
  '23505',
  null,
  'joining twice returns the existing row rather than creating a second'
);

select lives_ok(
  $$ delete from activities where id = 'aaaa0000-0000-0000-0000-000000000001' $$,
  'an activity can be deleted'
);

select is_empty(
  $$ select 1 from activity_participants $$,
  'and its participants cascade away with it'
);

select * from finish();
rollback;
