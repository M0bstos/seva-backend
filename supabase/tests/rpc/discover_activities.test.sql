begin;
create extension if not exists pgtap with schema extensions;
select plan(18);

insert into auth.users (id, created_at)
select ('00000000-0000-0000-0000-00000000000' || n)::uuid, now() - interval '30 days'
from generate_series(1, 3) n;
insert into profiles (id, display_name)
select ('00000000-0000-0000-0000-00000000000' || n)::uuid, 'person ' || n
from generate_series(1, 3) n;

-- The caller's point is 73.8567, 18.5204 throughout; it snaps to 73.86, 18.52, and
-- every distance below is measured from there, not from the point as given.
insert into activities
  (id, organiser_id, title, description, category, starts_at, ends_at, location,
   location_label, capacity, status, cancelled_at, idempotency_key, request_hash)
values
  -- at the cell centre
  ('aaaa0000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001',
   'Riverside cleanup', 'Bring gloves and water. We meet at the east gate at dawn.',
   'environment', now() + interval '10 days', now() + interval '10 days 3 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.86, 18.52), 4326)::extensions.geography,
   'East gate', 20, 'visible', null, '00000000-0000-0000-0000-0000000000f1', repeat('1', 64)),
  -- about 3.2 km east: inside a 5 km radius, outside a 2 km one
  ('aaaa0000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001',
   'Ward tree planting', 'Bring gloves and water. We meet at the east gate at dawn.',
   'environment', now() + interval '11 days', now() + interval '11 days 3 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.89, 18.52), 4326)::extensions.geography,
   'Ward office', 20, 'visible', null, '00000000-0000-0000-0000-0000000000f2', repeat('2', 64)),
  -- about 36 km east: outside every rung this test asks for
  ('aaaa0000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001',
   'Far cleanup', 'Bring gloves and water. We meet at the east gate at dawn.',
   'environment', now() + interval '12 days', now() + interval '12 days 3 hours',
   extensions.st_setsrid(extensions.st_makepoint(74.20, 18.52), 4326)::extensions.geography,
   'Far gate', 20, 'visible', null, '00000000-0000-0000-0000-0000000000f3', repeat('3', 64)),
  -- unscreened, cancelled and already started, all at the cell centre
  ('aaaa0000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001',
   'Unscreened', 'Bring gloves and water. We meet at the east gate at dawn.',
   'environment', now() + interval '10 days', now() + interval '10 days 3 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.86, 18.52), 4326)::extensions.geography,
   'East gate', 20, 'pending', null, '00000000-0000-0000-0000-0000000000f4', repeat('4', 64)),
  ('aaaa0000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000001',
   'Cancelled', 'Bring gloves and water. We meet at the east gate at dawn.',
   'environment', now() + interval '10 days', now() + interval '10 days 3 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.86, 18.52), 4326)::extensions.geography,
   'East gate', 20, 'visible', now(), '00000000-0000-0000-0000-0000000000f5', repeat('5', 64)),
  ('aaaa0000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000001',
   'Already started', 'Bring gloves and water. We meet at the east gate at dawn.',
   'environment', now() - interval '1 hour', now() + interval '2 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.86, 18.52), 4326)::extensions.geography,
   'East gate', 20, 'visible', null, '00000000-0000-0000-0000-0000000000f6', repeat('6', 64)),
  -- organised by person 2, for the block filter
  ('aaaa0000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000002',
   'Shelter morning', 'Bring gloves and water. We meet at the east gate at dawn.',
   'animals', now() + interval '13 days', now() + interval '13 days 3 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.86, 18.52), 4326)::extensions.geography,
   'Shelter', 20, 'visible', null, '00000000-0000-0000-0000-0000000000f7', repeat('7', 64));

select ok(
  not has_function_privilege('anon',
    'discover_activities(uuid,double precision,double precision,int,category,date,date,'
    || 'text,int,text,int,int,int)', 'execute')
  and not has_function_privilege('authenticated',
    'discover_activities(uuid,double precision,double precision,int,category,date,date,'
    || 'text,int,text,int,int,int)', 'execute'),
  'no client reaches Discover past its rate limit (§9.1, §7.3)'
);

set local role service_role;

select is(
  (select jsonb_agg(e->>'title')
   from jsonb_array_elements(
     discover_activities(null, 73.8567, 18.5204, 5, null, null, null, null, 10,
       'discover:a', 60, null, null) -> 'activities') e),
  '["Riverside cleanup", "Ward tree planting", "Shelter morning"]'::jsonb,
  'visible upcoming Activities in the radius, soonest first (§7.3)'
);

-- Asking for 3 km takes the 2 km rung, so the Activity 3.2 km out drops away.
select is(
  (select jsonb_agg(e->>'title')
   from jsonb_array_elements(
     discover_activities(null, 73.8567, 18.5204, 3, null, null, null, null, 10,
       'discover:b', 60, null, null) -> 'activities') e),
  '["Riverside cleanup", "Shelter morning"]'::jsonb,
  'the radius snaps to the nearest rung (§7.3)'
);

select is(
  (select jsonb_agg(e->>'title')
   from jsonb_array_elements(
     discover_activities(null, 73.8567, 18.5204, 5, 'animals', null, null, null, 10,
       'discover:c', 60, null, null) -> 'activities') e),
  '["Shelter morning"]'::jsonb,
  'the category filter narrows the list'
);

select is(
  (select jsonb_agg(e->>'title')
   from jsonb_array_elements(
     discover_activities(null, 73.8567, 18.5204, 5, null,
       ((now() at time zone 'Asia/Kolkata')::date + 11),
       ((now() at time zone 'Asia/Kolkata')::date + 12), null, 10,
       'discover:d', 60, null, null) -> 'activities') e),
  '["Ward tree planting"]'::jsonb,
  'the date range is read as IST calendar days (§5.1)'
);

select ok(
  ((discover_activities(null, 73.8567, 18.5204, 5, null, null, null, null, 10,
      'discover:f', 60, null, null) #>> '{activities,1,distance_m}')::int
   between 3000 and 3400),
  'distance is measured from the snapped cell, not the caller''s own point'
);

-- The cache. The first call above wrote an entry under these arguments; an Activity
-- inserted now must not appear in a second call that reads it. §5.2 gives
-- service_role no insert on these columns, so the fixture is written as the owner.
reset role;
insert into activities
  (id, organiser_id, title, description, category, starts_at, ends_at, location,
   location_label, capacity, status, cancelled_at, idempotency_key, request_hash)
values
  ('aaaa0000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-000000000001',
   'Added after the cache', 'Bring gloves and water. We meet at the east gate at dawn.',
   'environment', now() + interval '9 days', now() + interval '9 days 3 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.86, 18.52), 4326)::extensions.geography,
   'East gate', 20, 'visible', null, '00000000-0000-0000-0000-0000000000f8', repeat('8', 64));
set local role service_role;

select is(
  jsonb_array_length(
    discover_activities(null, 73.8567, 18.5204, 5, null, null, null, null, 10,
      'discover:h', 60, null, null) -> 'activities'),
  3,
  'a second call inside 60 seconds is answered from the cache (§7.3)'
);

select is(
  (select count(*)::int from private.discover_cache
   where cache_key = 'discover:POINT(73.86 18.52):5:::::10' and expires_at > now()),
  1,
  'one entry serves every caller in the cell at that radius (§7.3, §12.2)'
);

-- Blocks are applied to what the cache holds, not to what it stores.
reset role;
insert into blocks (blocker_id, blocked_id)
values ('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000002');
set local role service_role;

select is(
  (select jsonb_agg(e->>'title')
   from jsonb_array_elements(
     discover_activities('00000000-0000-0000-0000-000000000003',
       73.8567, 18.5204, 5, null, null, null, null, 10,
       'discover:i', 60, null, null) -> 'activities') e),
  '["Riverside cleanup", "Ward tree planting"]'::jsonb,
  'a blocked organiser is filtered out for the person who blocked them (§7.2)'
);

select is(
  (select jsonb_array_length(payload -> 'activities') from private.discover_cache
   where cache_key = 'discover:POINT(73.86 18.52):5:::::10'),
  3,
  'and the shared entry still holds them, so the filter ran after the read (§7.3)'
);

-- Paging. The second page continues the first and ends with a null cursor.
select is(
  (select jsonb_agg(e->>'title')
   from jsonb_array_elements(
     discover_activities(null, 73.8567, 18.5204, 5, null, null, null, null, 2,
       'discover:j', 60, null, null) -> 'activities') e),
  '["Added after the cache", "Riverside cleanup"]'::jsonb,
  'a page is as long as the limit asks (§7.1)'
);

select is(
  (select jsonb_agg(e->>'title')
   from jsonb_array_elements(
     discover_activities(null, 73.8567, 18.5204, 5, null, null, null,
       (discover_activities(null, 73.8567, 18.5204, 5, null, null, null, null, 2,
         'discover:k', 60, null, null) ->> 'next_cursor'), 2,
       'discover:l', 60, null, null) -> 'activities') e),
  '["Ward tree planting", "Shelter morning"]'::jsonb,
  'and the cursor carries on from where it ended (§7.1)'
);

select is(
  (discover_activities(null, 73.8567, 18.5204, 5, null, null, null, null, 50,
     'discover:m', 60, null, null) ->> 'next_cursor'),
  null::text,
  'a short page ends the walk'
);

select is(
  (discover_activities(null, 73.8567, 18.5204, 5, null, null, null, 'not a cursor', 10,
     'discover:n', 60, null, null) ->> 'field'),
  'cursor',
  'a cursor that cannot be decoded is VALIDATION_FAILED, not INTERNAL (§7.4)'
);

-- §7.1 caps a page at 50. The route names the field to a caller who asks for more;
-- what this proves is the clamp behind it, which is what keeps the query bounded.
select is(
  (select count(*)::int from (
     select discover_activities(null, 73.8567, 18.5204, 5, null, null, null, null, 51,
       'discover:o', 60, null, null)) called,
   lateral (select 1 from private.discover_cache
            where cache_key = 'discover:POINT(73.86 18.52):5:::::50') found),
  1,
  'a page longer than 50 is clamped to 50 (§7.1)'
);

select is(
  (select count(*)::int from (
     select discover_activities(null, 73.8567, 18.5204, 5, null, null, null, null, 10,
       'discover:p', 1, null, null) as r
     from generate_series(1, 2)) s
   where s.r ->> 'error' = 'RATE_LIMITED'),
  1,
  'the limiter runs inside the same call, and a read is metered like any other (§12.2)'
);

-- The snap has to answer every value the `int` parameter accepts. It did not: both
-- sides of `abs(rung - p_radius_km)` were int4, so the 51 values from -2147483648 to
-- -2147483598 raised `integer out of range` inside the body — and the raise rolled
-- back the limiter's own upsert with it, leaving an unbilled retryable 500 on a route
-- §7.3 gives to "Anyone" (§12.2's D5 note). Fixed by widening the arithmetic.
select lives_ok(
  $$ select discover_activities(null, 73.8567, 18.5204, -2147483648, null, null, null,
       null, 10, 'discover:q', 60, null, null) $$,
  'int4''s floor snaps rather than raising (§12.2, §12.6)'
);

select is(
  (select jsonb_agg(e->>'title')
   from jsonb_array_elements(
     discover_activities(null, 73.8567, 18.5204, -2147483648, null, null, null, null, 10,
       'discover:r', 60, null, null) -> 'activities') e),
  '["Riverside cleanup", "Shelter morning"]'::jsonb,
  'and lands on the narrowest rung: this is the entry the 3 km call wrote (§7.3)'
);

select * from finish();
rollback;
