begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

insert into auth.users (id, created_at)
values ('e3000000-0000-4000-8000-000000000001', now() - interval '30 days');
insert into profiles (id, display_name)
values ('e3000000-0000-4000-8000-000000000001', 'Campaign author');

-- Two campaigns, because §6.1 gives `campaign_goal` two kinds of source: one counting
-- Acts and one summing a metric.
insert into campaigns (id, title, description, goal_metric, goal_value,
                       starts_on, ends_on, status)
values
  ('e3000000-0000-4000-8000-0000000000c1', 'Clean the Mula-Mutha',
   'Sacks of waste off the riverbank.', 'waste_kg', 5000,
   current_date - 10, current_date + 80, 'active'),
  ('e3000000-0000-4000-8000-0000000000c2', 'A thousand acts',
   'One act at a time.', 'acts', 1000,
   current_date - 10, current_date + 80, 'active');

insert into activities (id, organiser_id, title, description, category, starts_at,
                        ends_at, location, location_label, capacity, campaign_id,
                        status, idempotency_key, request_hash)
select ('e3000000-0000-4000-8000-0000000000a' || n)::uuid,
       'e3000000-0000-4000-8000-000000000001', 'Riverbank clean-up',
       'Bring gloves. We meet by the bridge and work upstream until noon.',
       'environment', now() - interval '2 days', now() - interval '2 days' + interval '4 hours',
       extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
       'Under the Z bridge', 40, ('e3000000-0000-4000-8000-0000000000c' || n)::uuid,
       'visible', gen_random_uuid(), repeat('a', 64)
from generate_series(1, 2) n;

insert into activity_participants (activity_id, user_id)
select ('e3000000-0000-4000-8000-0000000000a' || n)::uuid,
       'e3000000-0000-4000-8000-000000000001'
from generate_series(1, 2) n;

create function pg_temp.publish(p_id uuid, p_activity uuid) returns void
language sql as $$
  insert into acts (id, author_id, activity_id, title, story, category, occurred_on,
                    location_coarse, status, text_checked, idempotency_key, request_hash)
  values (p_id, 'e3000000-0000-4000-8000-000000000001', p_activity,
          'A morning at the river',
          'We filled eleven sacks along the bank before the rain came in at noon.',
          'environment', current_date - 1,
          extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
          'pending', true, gen_random_uuid(), repeat('d', 64));
$$;

-- Both dimensions, because §9.7's own lesson is that a column grant leaves
-- `has_table_privilege` false while the write succeeds — and a single
-- `grant update (progress_value) ... to authenticated` is all it would take.
select is_empty(
  $$ select r.rolname from (values ('anon'::name), ('authenticated'::name),
                                   ('service_role'::name)) as r (rolname)
     where has_table_privilege(r.rolname, 'campaigns', 'insert, update, delete')
        or has_any_column_privilege(r.rolname, 'campaigns', 'INSERT, UPDATE') $$,
  'no role may move campaign progress, which is why the trigger is definer (§9.2)'
);

select is(
  (select progress_value from campaigns where id = 'e3000000-0000-4000-8000-0000000000c1'),
  0::numeric(12,2),
  'a campaign starts at zero'
);

-- §6.1: "each metric value sums `metric` rows for that metric".
select pg_temp.publish('e3000000-0000-4000-8000-0000000000f1',
                       'e3000000-0000-4000-8000-0000000000a1');
insert into act_metrics (act_id, metric, value) values
  ('e3000000-0000-4000-8000-0000000000f1', 'waste_kg', 12.5),
  ('e3000000-0000-4000-8000-0000000000f1', 'trees_planted', 3);
update acts set status = 'visible', published_at = now()
where id = 'e3000000-0000-4000-8000-0000000000f1';

select is(
  (select progress_value from campaigns where id = 'e3000000-0000-4000-8000-0000000000c1'),
  12.5::numeric(12,2),
  'a waste_kg campaign advances by the kilograms claimed, not by the points earned'
);

-- The trees the same Act planted belong to no campaign here, and the publishing and
-- bonus rows are points rather than claims.
select is(
  (select progress_value from campaigns where id = 'e3000000-0000-4000-8000-0000000000c2'),
  0::numeric(12,2),
  'and a metric the campaign does not count leaves it alone'
);

-- §6.1: "`acts` counts `act_published` rows carrying a `campaign_id`".
select pg_temp.publish('e3000000-0000-4000-8000-0000000000f2',
                       'e3000000-0000-4000-8000-0000000000a2');
insert into act_metrics (act_id, metric, value)
values ('e3000000-0000-4000-8000-0000000000f2', 'waste_kg', 40);
update acts set status = 'visible', published_at = now()
where id = 'e3000000-0000-4000-8000-0000000000f2';

select is(
  (select progress_value from campaigns where id = 'e3000000-0000-4000-8000-0000000000c2'),
  1::numeric(12,2),
  'an acts campaign advances by one, not by the three rows the Act wrote'
);

select is(
  (select progress_value from campaigns where id = 'e3000000-0000-4000-8000-0000000000c1'),
  12.5::numeric(12,2),
  'and the waste claimed against the other campaign does not reach this one'
);

-- §6.2: staff removal deletes the ledger rows, and progress comes back down with them.
delete from impact_entries where act_id = 'e3000000-0000-4000-8000-0000000000f1';

select is(
  (select progress_value from campaigns where id = 'e3000000-0000-4000-8000-0000000000c1'),
  0::numeric(12,2),
  'removing an Act subtracts exactly the progress it contributed (§6.2)'
);

-- §5.4: account deletion nulls `user_id` and `act_id` but leaves `campaign_id`, "so
-- campaign totals stay correct with no extra code".
update impact_entries set user_id = null, act_id = null
where campaign_id = 'e3000000-0000-4000-8000-0000000000c2';

select is(
  (select progress_value from campaigns where id = 'e3000000-0000-4000-8000-0000000000c2'),
  1::numeric(12,2),
  'and a contributor deleting their account leaves the campaign where it was'
);

-- The hole this trigger had. `acts.activity_id` is caller-supplied, and an
-- unconditional campaign attribution let a signed-in stranger move any active
-- campaign's published progress. §2.1 is the rule: "an Act can link to an Activity
-- the author joined". Reproduced before the fix: 600 kg against a 5,000 kg goal from
-- one account in three Acts.
insert into auth.users (id, created_at)
values ('e3000000-0000-4000-8000-000000000009', now() - interval '30 days');
insert into profiles (id, display_name)
values ('e3000000-0000-4000-8000-000000000009', 'Joined nothing');

insert into acts (id, author_id, activity_id, title, story, category, occurred_on,
                  location_coarse, status, text_checked, idempotency_key, request_hash)
values ('e3000000-0000-4000-8000-0000000000f9',
        'e3000000-0000-4000-8000-000000000009',
        'e3000000-0000-4000-8000-0000000000a1', 'A morning at the river',
        'We filled eleven sacks along the bank before the rain came in at noon.',
        'environment', current_date - 1,
        extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
        'pending', true, gen_random_uuid(), repeat('9', 64));
insert into act_metrics (act_id, metric, value)
values ('e3000000-0000-4000-8000-0000000000f9', 'waste_kg', 200);
update acts set status = 'visible', published_at = now()
where id = 'e3000000-0000-4000-8000-0000000000f9';

select is(
  (select progress_value from campaigns where id = 'e3000000-0000-4000-8000-0000000000c1'),
  0::numeric(12,2),
  'an author who joined nothing cannot move a campaign they have no part in'
);

select is(
  (select count(*)::int from impact_entries
   where act_id = 'e3000000-0000-4000-8000-0000000000f9' and campaign_id is not null),
  0,
  'and their ledger rows carry no campaign at all'
);

select is(
  (select points from impact_entries
   where act_id = 'e3000000-0000-4000-8000-0000000000f9' and kind = 'act_published'),
  10,
  'while the Act still publishes and still earns, which is not what was at stake'
);

select * from finish();
rollback;
