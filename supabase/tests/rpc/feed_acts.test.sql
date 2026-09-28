begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

insert into auth.users (id, created_at)
select ('00000000-0000-0000-0000-00000000000' || n)::uuid, now() - interval '30 days'
from generate_series(1, 3) n;
insert into profiles (id, display_name)
select ('00000000-0000-0000-0000-00000000000' || n)::uuid, 'person ' || n
from generate_series(1, 3) n;

-- The trigger snaps every Act to the same 0.05° grid (§5.4, §17 O29), and the caller's
-- point below snaps to the same cell, 73.85 18.5. One grid step is about 5.3 km, so at
-- the 5 km rung a reader sees their own cell and nothing else — which is what §17 O30
-- accepted when it made the rung and the grid the same size.
insert into acts
  (id, author_id, title, story, category, occurred_on, location_coarse, status,
   published_at, idempotency_key, request_hash, created_at)
values
  ('dddd0000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001',
   'Cleared the bank', 'We filled eleven sacks along the bank before the rain came in.',
   'environment', current_date - 1,
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'visible', now() - interval '1 hour',
   '00000000-0000-0000-0000-0000000000f1', repeat('1', 64), now() - interval '1 hour'),
  ('dddd0000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001',
   'Fixed the gate', 'We repaired the shelter gate and painted it before the evening.',
   'community', current_date - 3,
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'visible', now() - interval '3 hours',
   '00000000-0000-0000-0000-0000000000f2', repeat('2', 64), now() - interval '3 hours'),
  -- about 16 km away: outside the 5 km rung, inside the 25 km one
  ('dddd0000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001',
   'Ward drive', 'A whole ward turned out to clear the drains before the monsoon came.',
   'environment', current_date - 2,
   extensions.st_setsrid(extensions.st_makepoint(74.0067, 18.5204), 4326)::extensions.geography,
   'visible', now() - interval '2 hours',
   '00000000-0000-0000-0000-0000000000f3', repeat('3', 64), now() - interval '2 hours'),
  ('dddd0000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001',
   'Not screened yet', 'This one is still waiting for the screening worker to reach it.',
   'environment', current_date - 1,
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'pending', null,
   '00000000-0000-0000-0000-0000000000f4', repeat('4', 64), now() - interval '10 minutes'),
  ('dddd0000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000001',
   'Taken down', 'Staff removed this one, and it is kept for its retention period.',
   'environment', current_date - 1,
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'removed', now() - interval '5 hours',
   '00000000-0000-0000-0000-0000000000f5', repeat('5', 64), now() - interval '20 minutes'),
  -- by person 2, for the block filter
  ('dddd0000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000002',
   'Fed the strays', 'We fed the street dogs behind the market and left water out.',
   'animals', current_date - 1,
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'visible', now() - interval '30 minutes',
   '00000000-0000-0000-0000-0000000000f6', repeat('6', 64), now() - interval '30 minutes');

insert into act_metrics (act_id, metric, value) values
  ('dddd0000-0000-0000-0000-000000000001', 'waste_kg', 42.5),
  ('dddd0000-0000-0000-0000-000000000001', 'volunteer_hours', 6);

insert into media
  (id, owner_id, purpose, act_id, position, upload_path, public_path, thumb_path,
   width, height, status)
values
  ('bbbb0000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001',
   'act', 'dddd0000-0000-0000-0000-000000000001', 1, 'uploads/p1/after.jpg',
   'media/p1/after.jpg', 'media/p1/after-480.jpg', 2048, 1536, 'ready'),
  ('bbbb0000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001',
   'act', 'dddd0000-0000-0000-0000-000000000001', 0, 'uploads/p1/before.jpg',
   'media/p1/before.jpg', 'media/p1/before-480.jpg', 2048, 1536, 'ready'),
  ('bbbb0000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001',
   'act', 'dddd0000-0000-0000-0000-000000000001', 2, 'uploads/p1/flagged.jpg',
   'media/p1/flagged.jpg', 'media/p1/flagged-480.jpg', 2048, 1536, 'held');

select ok(
  not has_function_privilege('anon',
    'feed_acts(uuid,double precision,double precision,int,category,text,int,text,int,int,int)',
    'execute')
  and not has_function_privilege('authenticated',
    'feed_acts(uuid,double precision,double precision,int,category,text,int,text,int,int,int)',
    'execute'),
  'no client reaches Feed past its rate limit (§9.1, §7.3)'
);

set local role service_role;

select is(
  (feed_acts(null, 73.8567, 18.5204, 5, null, null, 10, 'feed:a', 60, null, null)
   ->> 'error'),
  'UNAUTHENTICATED',
  'Feed is a signed-in route, so a call with no user is refused (§7.3, §7.4)'
);

select is(
  (select jsonb_agg(e->>'title')
   from jsonb_array_elements(
     feed_acts('00000000-0000-0000-0000-000000000001', 73.8567, 18.5204, 5, null, null,
       10, 'feed:b', 60, null, null) -> 'acts') e),
  '["Fed the strays", "Cleared the bank", "Fixed the gate"]'::jsonb,
  'recent visible Acts in the caller''s own cell, newest first (§7.3)'
);

-- §17 O30: one grid step is wider than the smallest rung, so 16 km needs the 25 km one.
select is(
  (select jsonb_agg(e->>'title')
   from jsonb_array_elements(
     feed_acts('00000000-0000-0000-0000-000000000001', 73.8567, 18.5204, 25, null, null,
       10, 'feed:c', 60, null, null) -> 'acts') e),
  '["Fed the strays", "Cleared the bank", "Ward drive", "Fixed the gate"]'::jsonb,
  'a wider rung reaches the next cells out (§17 O30)'
);

select is(
  (select jsonb_agg(e->>'title')
   from jsonb_array_elements(
     feed_acts('00000000-0000-0000-0000-000000000001', 73.8567, 18.5204, 5, 'animals',
       null, 10, 'feed:d', 60, null, null) -> 'acts') e),
  '["Fed the strays"]'::jsonb,
  'the category filter narrows the list'
);

select is(
  (feed_acts('00000000-0000-0000-0000-000000000001', 73.8567, 18.5204, 5, null, null,
     10, 'feed:e', 60, null, null) #> '{acts,1,metrics}'),
  '{"waste_kg": 42.50, "volunteer_hours": 6.00}'::jsonb,
  'an Act carries the impact it claimed (§5.2, §17 O19)'
);

select is(
  (select jsonb_agg(e->>'public_path')
   from jsonb_array_elements(
     feed_acts('00000000-0000-0000-0000-000000000001', 73.8567, 18.5204, 5, null, null,
       10, 'feed:f', 60, null, null) #> '{acts,1,photos}') e),
  '["media/p1/before.jpg", "media/p1/after.jpg"]'::jsonb,
  'and its ready photos in position order, never a held one (§5.2, §8.2)'
);

-- The cache. An Act inserted after the first call must not appear in the second.
reset role;
insert into acts
  (id, author_id, title, story, category, occurred_on, location_coarse, status,
   published_at, idempotency_key, request_hash, created_at)
values
  ('dddd0000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000001',
   'Added after the cache', 'An Act that landed after the cache entry was written out.',
   'environment', current_date,
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'visible', now(),
   '00000000-0000-0000-0000-0000000000f7', repeat('7', 64), now());
set local role service_role;

select is(
  jsonb_array_length(
    feed_acts('00000000-0000-0000-0000-000000000001', 73.8567, 18.5204, 5, null, null,
      10, 'feed:g', 60, null, null) -> 'acts'),
  3,
  'a second call inside 60 seconds is answered from the cache (§7.3)'
);

select is(
  (select count(*)::int from private.discover_cache
   where cache_key = 'feed:POINT(73.85 18.5):5:::10' and expires_at > now()),
  1,
  'one entry serves every caller in the cell at that radius (§7.3, §12.2)'
);

reset role;
insert into blocks (blocker_id, blocked_id)
values ('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000002');
set local role service_role;

select is(
  (select jsonb_agg(e->>'title')
   from jsonb_array_elements(
     feed_acts('00000000-0000-0000-0000-000000000003', 73.8567, 18.5204, 5, null, null,
       10, 'feed:h', 60, null, null) -> 'acts') e),
  '["Cleared the bank", "Fixed the gate"]'::jsonb,
  'a blocked author is filtered out for the person who blocked them (§1.1, §7.2)'
);

select is(
  (select jsonb_array_length(payload -> 'acts') from private.discover_cache
   where cache_key = 'feed:POINT(73.85 18.5):5:::10'),
  3,
  'and the shared entry still holds them, so the filter ran after the read (§7.3)'
);

select is(
  (select jsonb_agg(e->>'title')
   from jsonb_array_elements(
     feed_acts('00000000-0000-0000-0000-000000000001', 73.8567, 18.5204, 5, null,
       (feed_acts('00000000-0000-0000-0000-000000000001', 73.8567, 18.5204, 5, null,
         null, 2, 'feed:i', 60, null, null) ->> 'next_cursor'), 2,
       'feed:j', 60, null, null) -> 'acts') e),
  '["Cleared the bank", "Fixed the gate"]'::jsonb,
  'the cursor carries on from where the first page ended (§7.1)'
);

select is(
  (feed_acts('00000000-0000-0000-0000-000000000001', 73.8567, 18.5204, 5, null,
     'not a cursor', 10, 'feed:k', 60, null, null) ->> 'field'),
  'cursor',
  'a cursor that cannot be decoded is VALIDATION_FAILED, not INTERNAL (§7.4)'
);

select is(
  (select count(*)::int from (
     select feed_acts('00000000-0000-0000-0000-000000000001', 73.8567, 18.5204, 5, null,
       null, 10, 'feed:l', 1, null, null) as r
     from generate_series(1, 2)) s
   where s.r ->> 'error' = 'RATE_LIMITED'),
  1,
  'the limiter runs inside the same call (§12.2)'
);

-- The same int4 overflow. `O30` gave Feed one rung fewer, starting at 5 km, but both
-- ladders top out at 50, so the band is identical (§12.6).
select lives_ok(
  $$ select feed_acts('00000000-0000-0000-0000-000000000001', 73.8567, 18.5204,
       -2147483648, null, null, 10, 'feed:m', 60, null, null) $$,
  'int4''s floor snaps rather than raising (§12.2, §12.6)'
);

select * from finish();
rollback;
