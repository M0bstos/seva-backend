begin;
create extension if not exists pgtap with schema extensions;
select plan(18);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'anand'),
  ('22222222-2222-2222-2222-222222222222', 'bina');
insert into campaigns (id, title, description, goal_metric, goal_value, starts_on, ends_on, status)
values ('cccc0000-0000-0000-0000-000000000001', 'Clean the lake',
        'Volunteers clearing plastic from the lake shore every weekend.',
        'waste_kg', 5000, '2026-10-01', '2026-12-31', 'active');

insert into activities
  (id, organiser_id, title, description, category, starts_at, ends_at,
   location, location_label, capacity, campaign_id, status, idempotency_key, request_hash)
values
  ('aaaa0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'Lake shore cleanup', 'Bring gloves and water. We meet at the east gate and finish by noon.',
   'environment', '2026-11-01T03:30:00Z', '2026-11-01T06:30:00Z',
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'East gate, Pashan Lake', 40, 'cccc0000-0000-0000-0000-000000000001', 'visible',
   '00000000-0000-0000-0000-0000000000a1', repeat('a', 64)),
  ('aaaa0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'Tree planting drive', 'Saplings provided. Wear closed shoes and bring a hat for the sun.',
   'environment', '2026-12-01T03:30:00Z', '2026-12-01T05:30:00Z',
   extensions.st_setsrid(extensions.st_makepoint(73.8600, 18.5300), 4326)::extensions.geography,
   'Baner hill foot', 25, null, 'pending',
   '00000000-0000-0000-0000-0000000000a2', repeat('b', 64));

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.activities'::regclass and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'public.activities', a.attname, 'insert')
       and a.attname not in ('organiser_id', 'title', 'description', 'category', 'starts_at', 'ends_at',
                            'location', 'location_label', 'capacity', 'what_to_bring',
                            'campaign_id', 'idempotency_key', 'request_hash') $$,
  'the create function supplies only its own columns; screening state and counters take their defaults'
);

select ok(
  has_table_privilege('authenticated', 'activities', 'SELECT')
  and not has_table_privilege('authenticated', 'activities',
    'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'activities',
    'INSERT, UPDATE, REFERENCES'),
  'activities are created by functions, so no client writes one directly'
);

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.activities'::regclass and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'public.activities', a.attname, 'update')
       and a.attname not in ('status', 'text_checked', 'cancelled_at') $$,
  'the backend updates only screening status and cancellation, never capacity or the count'
);

select throws_ok(
  $$ update activities set ends_at = starts_at - interval '1 hour'
     where id = 'aaaa0000-0000-0000-0000-000000000001' $$,
  '23514',
  null,
  'an activity cannot end before it starts, even for the owner'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';

select results_eq(
  $$ select title from activities $$,
  $$ values ('Lake shore cleanup'::text) $$,
  'a signed-in user reads visible activities only'
);

select is_empty(
  $$ select 1 from activities where id = 'aaaa0000-0000-0000-0000-000000000002' $$,
  'an unscreened activity is not readable by others'
);

reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select results_eq(
  $$ select count(*)::int from activities $$,
  $$ values (2) $$,
  'the organiser sees their own activity in any status'
);

select throws_ok(
  $$ update activities set status = 'visible'
     where id = 'aaaa0000-0000-0000-0000-000000000002' $$,
  '42501',
  null,
  'an organiser cannot publish their own activity past screening'
);

select throws_ok(
  $$ delete from activities where id = 'aaaa0000-0000-0000-0000-000000000002' $$,
  '42501',
  null,
  'content is never hard-deleted by a client'
);

reset role;

select throws_ok(
  $$ insert into activities
       (organiser_id, title, description, category, starts_at, ends_at,
        location, location_label, capacity, idempotency_key, request_hash)
     values ('11111111-1111-1111-1111-111111111111', 'Too long a day',
       'This one runs for two days, which the spec does not allow for a single activity.',
       'community', '2026-11-05T03:30:00Z', '2026-11-07T03:30:00Z',
       extensions.st_setsrid(extensions.st_makepoint(73.86, 18.52), 4326)::extensions.geography,
       'Somewhere', 10, '00000000-0000-0000-0000-0000000000a3', repeat('c', 64)) $$,
  '23514',
  null,
  'an activity cannot run longer than 24 hours'
);

select throws_ok(
  $$ insert into activities
       (organiser_id, title, description, category, starts_at, ends_at,
        location, location_label, capacity, idempotency_key, request_hash)
     values ('11111111-1111-1111-1111-111111111111', 'Too many people',
       'Capacity above the thousand-person ceiling the spec sets for one activity.',
       'community', '2026-11-05T03:30:00Z', '2026-11-05T05:30:00Z',
       extensions.st_setsrid(extensions.st_makepoint(73.86, 18.52), 4326)::extensions.geography,
       'Somewhere', 1001, '00000000-0000-0000-0000-0000000000a4', repeat('d', 64)) $$,
  '23514',
  null,
  'capacity stops at a thousand'
);

select throws_ok(
  $$ insert into activities
       (organiser_id, title, description, category, starts_at, ends_at,
        location, location_label, capacity, idempotency_key, request_hash)
     values ('11111111-1111-1111-1111-111111111111', 'Duplicate key',
       'Same organiser, same idempotency key, which the unique constraint must refuse.',
       'community', '2026-11-05T03:30:00Z', '2026-11-05T05:30:00Z',
       extensions.st_setsrid(extensions.st_makepoint(73.86, 18.52), 4326)::extensions.geography,
       'Somewhere', 10, '00000000-0000-0000-0000-0000000000a1', repeat('e', 64)) $$,
  '23505',
  null,
  'the same idempotency key cannot create a second activity for one organiser'
);

select throws_ok(
  $$ delete from campaigns where id = 'cccc0000-0000-0000-0000-000000000001' $$,
  '23503',
  null,
  'a campaign with activities attached cannot be deleted'
);

set local role service_role;

select lives_ok(
  $$ insert into activities
       (organiser_id, title, description, category, starts_at, ends_at,
        location, location_label, capacity, idempotency_key, request_hash)
     values ('11111111-1111-1111-1111-111111111111', 'Morning litter walk',
       'A short walk along the canal path collecting litter before the day warms up.',
       'environment', '2026-11-20T03:30:00Z', '2026-11-20T05:00:00Z',
       extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
       'Canal path gate', 15, '00000000-0000-0000-0000-0000000000a9', repeat('f', 64)) $$,
  'the create function can create an activity, which arrives pending and uncounted'
);

select results_eq(
  $$ select status::text, participant_count from activities
     where idempotency_key = '00000000-0000-0000-0000-0000000000a9' $$,
  $$ values ('pending'::text, 0) $$,
  'and it cannot arrive published or pre-counted'
);

select lives_ok(
  $$ update activities set status = 'visible', text_checked = true
     where id = 'aaaa0000-0000-0000-0000-000000000002' $$,
  'the moderation worker publishes an activity once it passes screening'
);

reset role;

select lives_ok(
  $$ delete from profiles where id = '11111111-1111-1111-1111-111111111111' $$,
  'the organiser profile can be deleted'
);

select results_eq(
  $$ select count(*)::int from activities where organiser_id is null $$,
  $$ values (3) $$,
  'and past activities survive with a null organiser, per 5.4'
);

select * from finish();
rollback;
