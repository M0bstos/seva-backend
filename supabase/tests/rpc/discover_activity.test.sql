begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

insert into auth.users (id, created_at)
select ('00000000-0000-0000-0000-00000000000' || n)::uuid, now() - interval '30 days'
from generate_series(1, 3) n;
insert into profiles (id, display_name)
select ('00000000-0000-0000-0000-00000000000' || n)::uuid, 'person ' || n
from generate_series(1, 3) n;

insert into activities
  (id, organiser_id, title, description, category, starts_at, ends_at, location,
   location_label, capacity, participant_count, what_to_bring, status, cancelled_at,
   idempotency_key, request_hash)
values
  ('aaaa0000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002',
   'Riverside cleanup', 'Bring gloves and water. We meet at the east gate at dawn.',
   'environment', now() + interval '10 days', now() + interval '10 days 3 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'East gate', 20, 3, 'Gloves', 'visible', null,
   '00000000-0000-0000-0000-0000000000f1', repeat('1', 64)),
  ('aaaa0000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000002',
   'Unscreened', 'Bring gloves and water. We meet at the east gate at dawn.',
   'environment', now() + interval '10 days', now() + interval '10 days 3 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'East gate', 20, 0, null, 'pending', null,
   '00000000-0000-0000-0000-0000000000f2', repeat('2', 64)),
  ('aaaa0000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000002',
   'Called off', 'Bring gloves and water. We meet at the east gate at dawn.',
   'environment', now() + interval '10 days', now() + interval '10 days 3 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'East gate', 20, 0, null, 'visible', now(),
   '00000000-0000-0000-0000-0000000000f3', repeat('3', 64));

insert into media
  (id, owner_id, purpose, activity_id, position, upload_path, public_path, thumb_path,
   width, height, status)
values
  ('bbbb0000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002',
   'activity', 'aaaa0000-0000-0000-0000-000000000001', 1, 'uploads/p2/second.jpg',
   'media/p2/second.jpg', 'media/p2/second-480.jpg', 2048, 1536, 'ready'),
  ('bbbb0000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000002',
   'activity', 'aaaa0000-0000-0000-0000-000000000001', 0, 'uploads/p2/first.jpg',
   'media/p2/first.jpg', 'media/p2/first-480.jpg', 2048, 1536, 'ready'),
  -- flagged: §8.2 keeps it out of a public answer until staff clear it
  ('bbbb0000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000002',
   'activity', 'aaaa0000-0000-0000-0000-000000000001', 2, 'uploads/p2/held.jpg',
   'media/p2/held.jpg', 'media/p2/held-480.jpg', 2048, 1536, 'held');

select ok(
  not has_function_privilege('anon',
    'discover_activity(uuid,uuid,text,int,int,int)', 'execute')
  and not has_function_privilege('authenticated',
    'discover_activity(uuid,uuid,text,int,int,int)', 'execute'),
  'no client reaches the shared-link route past its rate limit (§9.1, §7.3)'
);

set local role service_role;

select is(
  (discover_activity(null, 'aaaa0000-0000-0000-0000-000000000001',
     'discover.activity:a', 60, null, null) #>> '{activity,title}'),
  'Riverside cleanup',
  'a visible Activity is served to a logged-out caller (§7.3)'
);

-- §5.4 stores the meeting point exactly, because an Activity is a public event.
select ok(
  ((discover_activity(null, 'aaaa0000-0000-0000-0000-000000000001',
      'discover.activity:b', 60, null, null) #>> '{activity,lon}')::numeric = 73.8567
   and (discover_activity(null, 'aaaa0000-0000-0000-0000-000000000001',
      'discover.activity:c', 60, null, null) #>> '{activity,lat}')::numeric = 18.5204),
  'the meeting point is exact, not snapped (§5.4)'
);

select is(
  (discover_activity(null, 'aaaa0000-0000-0000-0000-000000000001',
     'discover.activity:d', 60, null, null) #>> '{activity,participant_count}'),
  '3',
  'the count is served, and §9.6 keeps every participant''s identity out of it'
);

select is(
  (select jsonb_agg(e->>'public_path')
   from jsonb_array_elements(
     discover_activity(null, 'aaaa0000-0000-0000-0000-000000000001',
       'discover.activity:e', 60, null, null) #> '{activity,photos}') e),
  '["media/p2/first.jpg", "media/p2/second.jpg"]'::jsonb,
  'ready photos come back in position order, and a held one does not (§5.2, §8.2)'
);

select is(
  (discover_activity(null, 'aaaa0000-0000-0000-0000-000000000003',
     'discover.activity:f', 60, null, null) #> '{activity,cancelled_at}' is not null),
  true,
  'a cancelled Activity is answered as cancelled rather than hidden (§7.3)'
);

select is(
  (discover_activity(null, 'aaaa0000-0000-0000-0000-000000000002',
     'discover.activity:g', 60, null, null) ->> 'error'),
  'NOT_FOUND',
  'an unscreened Activity is not visible to anyone here (§8.2, §7.4)'
);

select is(
  (discover_activity(null, '00000000-0000-0000-0000-0000000000ff',
     'discover.activity:h', 60, null, null) ->> 'error'),
  'NOT_FOUND',
  'and neither is one that does not exist (§7.4)'
);

-- §7.2: a block takes effect on Discover at the next request.
reset role;
insert into blocks (blocker_id, blocked_id)
values ('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000002');
set local role service_role;

select is(
  (discover_activity('00000000-0000-0000-0000-000000000003',
     'aaaa0000-0000-0000-0000-000000000001',
     'discover.activity:i', 60, null, null) ->> 'error'),
  'NOT_FOUND',
  'a blocked organiser''s Activity is missing as far as the blocker is concerned (§7.4)'
);

select is(
  (discover_activity('00000000-0000-0000-0000-000000000001',
     'aaaa0000-0000-0000-0000-000000000001',
     'discover.activity:j', 60, null, null) #>> '{activity,title}'),
  'Riverside cleanup',
  'and everyone else still sees it'
);

select is(
  (select count(*)::int from (
     select discover_activity(null, 'aaaa0000-0000-0000-0000-000000000001',
       'discover.activity:k', 1, null, null) as r
     from generate_series(1, 2)) s
   where s.r ->> 'error' = 'RATE_LIMITED'),
  1,
  'the limiter runs inside the same call (§12.2)'
);

select * from finish();
rollback;
