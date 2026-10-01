begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, created_at) values
  ('e4000000-0000-4000-8000-000000000001', now() - interval '30 days'),
  ('e4000000-0000-4000-8000-000000000002', now() - interval '30 days');
insert into profiles (id, display_name) values
  ('e4000000-0000-4000-8000-000000000001', 'Organiser'),
  ('e4000000-0000-4000-8000-000000000002', 'Joiner');

insert into activities (id, organiser_id, title, description, category, starts_at,
                        ends_at, location, location_label, capacity, status,
                        idempotency_key, request_hash)
select ('e4000000-0000-4000-8000-0000000000a' || n)::uuid,
       'e4000000-0000-4000-8000-000000000001', 'Riverbank clean-up',
       'Bring gloves. We meet by the bridge and work upstream until noon.',
       'environment', now() + interval '2 days', now() + interval '2 days' + interval '4 hours',
       extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
       'Under the Z bridge', 40, 'visible', gen_random_uuid(), repeat('e', 64)
from generate_series(1, 2) n;

select ok(
  not has_function_privilege('anon', 'count_activities_joined()', 'execute')
  and not has_function_privilege('authenticated', 'count_activities_joined()', 'execute')
  and not has_function_privilege('service_role', 'count_activities_joined()', 'execute'),
  'nobody may call the counter directly (§9.2)'
);

-- §6.1: joining earns no points, so the only thing a join moves is this one column.
insert into activity_participants (activity_id, user_id)
values ('e4000000-0000-4000-8000-0000000000a1', 'e4000000-0000-4000-8000-000000000002');

select results_eq(
  $$ select activities_joined, points from impact_totals
     where user_id = 'e4000000-0000-4000-8000-000000000002' $$,
  $$ values (1, 0) $$,
  'a join creates the totals row and counts one, earning nothing (§6.1)'
);

insert into activity_participants (activity_id, user_id)
values ('e4000000-0000-4000-8000-0000000000a2', 'e4000000-0000-4000-8000-000000000002');

select is(
  (select activities_joined from impact_totals
   where user_id = 'e4000000-0000-4000-8000-000000000002'),
  2,
  'and a second join counts again'
);

-- §7.3's leave route frees the place, and the count follows it.
update activity_participants set status = 'left', left_at = now()
where activity_id = 'e4000000-0000-4000-8000-0000000000a2'
  and user_id = 'e4000000-0000-4000-8000-000000000002';

select is(
  (select activities_joined from impact_totals
   where user_id = 'e4000000-0000-4000-8000-000000000002'),
  1,
  'leaving takes it back down'
);

-- §7.3: "Joining twice returns the existing row", and the join function sets the
-- status back rather than inserting again.
update activity_participants set status = 'joined', left_at = null
where activity_id = 'e4000000-0000-4000-8000-0000000000a2'
  and user_id = 'e4000000-0000-4000-8000-000000000002';

select is(
  (select activities_joined from impact_totals
   where user_id = 'e4000000-0000-4000-8000-000000000002'),
  2,
  'and rejoining counts once more, not twice'
);

-- A write that leaves the status alone must not move the count, or a `left_at` fix
-- would inflate it.
update activity_participants set joined_at = joined_at - interval '1 hour'
where user_id = 'e4000000-0000-4000-8000-000000000002';

select is(
  (select activities_joined from impact_totals
   where user_id = 'e4000000-0000-4000-8000-000000000002'),
  2,
  'a write that does not cross the joined boundary moves nothing'
);

-- §5.4 deletes participations when an account goes, but an Activity can be deleted
-- while the person is still here, and then the count has to come down.
delete from activities where id = 'e4000000-0000-4000-8000-0000000000a2';

select is(
  (select activities_joined from impact_totals
   where user_id = 'e4000000-0000-4000-8000-000000000002'),
  1,
  'and a deleted Activity takes its participation out of the count'
);

-- §6.2's rebuild property holds for this column too, just from a different source:
-- `activity_participants` rather than the ledger (§17.1).
select is(
  (select activities_joined from impact_totals
   where user_id = 'e4000000-0000-4000-8000-000000000002'),
  (select count(*)::int from activity_participants
   where user_id = 'e4000000-0000-4000-8000-000000000002' and status = 'joined'),
  'the column equals a count over the table it is maintained from'
);

select * from finish();
rollback;
