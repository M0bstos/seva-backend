begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

-- One point, submitted by every author below, so the only variable is the author.
create temporary table submitted as
select extensions.st_setsrid(extensions.st_makepoint(73.856743, 18.520430), 4326)::extensions.geography as point;

-- The inserts below run as service_role to prove a trigger fires without any execute
-- privilege on its function; that role needs to read this fixture to do so.
grant select on submitted to service_role;

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222'),
  ('33333333-3333-3333-3333-333333333333');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'adult'),
  ('22222222-2222-2222-2222-222222222222', 'minor'),
  ('33333333-3333-3333-3333-333333333333', 'no private record');
insert into profile_private (user_id, date_of_birth, terms_version, privacy_version) values
  ('11111111-1111-1111-1111-111111111111', '1995-04-04', '2026-10-01', '2026-10-01'),
  ('22222222-2222-2222-2222-222222222222', '2010-04-04', '2026-10-01', '2026-10-01');

select ok(
  not has_function_privilege('anon', 'coarsen_act_location()', 'execute')
  and not has_function_privilege('authenticated', 'coarsen_act_location()', 'execute'),
  'the trigger function is not callable by a client, which gate 3 also asserts'
);

set local role service_role;

-- Firing a trigger checks no execute privilege, so the revoke above costs nothing.
insert into acts (author_id, title, story, category, occurred_on, location_coarse,
                  idempotency_key, request_hash)
select p.id, p.display_name || ' act',
       'A story long enough to pass the twenty character minimum the table checks.',
       'community', '2026-09-20', s.point,
       ('00000000-0000-0000-0000-00000000000' || right(p.id::text, 1))::uuid, repeat('a', 64)
from profiles p cross join submitted s;

reset role;

select is(
  (select extensions.st_astext(location_coarse) from acts where title = 'adult act'),
  'POINT(73.85000000000001 18.5)',
  'an act lands on the roughly 5 km grid §5.4 asks for'
);

-- §17 O29: two grids made this column a detector for who is 13-17, because the coarse
-- lattice was a subset of the fine one. One grid has no second resolution to detect.
select is(
  (select count(distinct extensions.st_astext(location_coarse))::int from acts),
  1,
  'and every author lands on the same point, whatever their age or records'
);

select is_empty(
  $$ select a.title from acts a, submitted s
     where extensions.st_equals(a.location_coarse::extensions.geometry,
                                s.point::extensions.geometry) $$,
  'no act keeps the point it was given: §5.4 never stores the raw location'
);

select ok(
  (select extensions.st_distance(a.location_coarse, s.point) from acts a, submitted s
   where a.title = 'adult act') between 100 and 7000,
  'the stored point sits within one cell of the real one, not somewhere else entirely'
);

-- The trigger fires before insert only, which is safe solely because no role can
-- write the column afterwards. That invariant lives in the acts migration, so assert
-- it here: adding location_coarse to an update grant would otherwise defeat §5.4's
-- "the raw location is never stored" with nothing in CI to notice.
select is_empty(
  $$ select r.rolname from (values ('anon'::name), ('authenticated'::name),
                                   ('service_role'::name)) as r (rolname)
     where has_column_privilege(r.rolname, 'public.acts', 'location_coarse', 'update') $$,
  'no role can update a stored location, so before-insert is the whole story'
);

-- §5.4: an Activity's meeting point is stored exactly, because it is a public event.
set local role service_role;
insert into activities (organiser_id, title, description, category, starts_at, ends_at,
                        location, location_label, capacity, idempotency_key, request_hash)
select '11111111-1111-1111-1111-111111111111', 'Lake shore cleanup',
       'Bring gloves and water. We meet at the east gate and finish before noon.',
       'environment', '2026-11-01T03:30:00Z', '2026-11-01T06:30:00Z',
       s.point, 'East gate, Pashan Lake', 40,
       '00000000-0000-0000-0000-0000000000b1', repeat('c', 64)
from submitted s;
reset role;

select is(
  (select extensions.st_astext(location) from activities where title = 'Lake shore cleanup'),
  (select extensions.st_astext(point) from submitted),
  'an activity meeting point is untouched, because §5.4 stores it exactly'
);

select * from finish();
rollback;
