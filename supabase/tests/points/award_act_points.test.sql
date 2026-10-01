begin;
create extension if not exists pgtap with schema extensions;
select plan(22);

-- Two authors: one a month old, one three days old, because §6.3 caps them
-- differently. A third Act belongs to the older author and documents an Activity.
insert into auth.users (id, created_at) values
  ('e1000000-0000-4000-8000-000000000001', now() - interval '30 days'),
  ('e1000000-0000-4000-8000-000000000002', now() - interval '3 days'),
  ('e1000000-0000-4000-8000-000000000003', now() - interval '30 days');
insert into profiles (id, display_name) values
  ('e1000000-0000-4000-8000-000000000001', 'Older author'),
  ('e1000000-0000-4000-8000-000000000002', 'Newer author'),
  ('e1000000-0000-4000-8000-000000000003', 'Third author');

insert into campaigns (id, title, description, goal_metric, goal_value,
                       starts_on, ends_on, status)
values ('e1000000-0000-4000-8000-0000000000c1', 'Clean the Mula-Mutha',
        'Sacks of waste off the riverbank.', 'waste_kg', 5000,
        current_date - 10, current_date + 80, 'active');

insert into activities (id, organiser_id, title, description, category, starts_at,
                        ends_at, location, location_label, capacity, campaign_id,
                        status, idempotency_key, request_hash)
values ('e1000000-0000-4000-8000-0000000000a1',
        'e1000000-0000-4000-8000-000000000001', 'Riverbank clean-up',
        'Bring gloves. We meet by the bridge and work upstream until noon.',
        'environment', now() - interval '2 days', now() - interval '2 days' + interval '4 hours',
        extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
        'Under the Z bridge', 40, 'e1000000-0000-4000-8000-0000000000c1',
        'visible', gen_random_uuid(), repeat('a', 64));

create function pg_temp.new_act(p_id uuid, p_author uuid, p_activity uuid) returns void
language sql as $$
  insert into acts (id, author_id, activity_id, title, story, category, occurred_on,
                    location_coarse, status, text_checked, idempotency_key, request_hash)
  values (p_id, p_author, p_activity, 'A morning at the river',
          'We filled eleven sacks along the bank before the rain came in at noon.',
          'environment', current_date - 1,
          extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
          'pending', true, gen_random_uuid(), repeat('b', 64));
$$;

-- §9.2: points have no client write path, and not even the route functions have one.
-- Both dimensions, because §9.7's own lesson is that a column grant leaves
-- `has_table_privilege` false while the write succeeds.
select is_empty(
  $$ select r.rolname from (values ('anon'::name), ('authenticated'::name),
                                   ('service_role'::name)) as r (rolname)
     where has_table_privilege(r.rolname, 'impact_entries', 'insert, update, delete')
        or has_any_column_privilege(r.rolname, 'impact_entries', 'INSERT, UPDATE') $$,
  'no role may write the ledger, which is why the trigger is security definer'
);

-- The exploit this trigger had, kept closed: an author who joined nothing must not
-- reach a campaign. §2.1 — "an Act can link to an Activity the author joined".
select is_empty(
  $$ select e.id from impact_entries e
     join acts a on a.id = e.act_id
     where e.campaign_id is not null
       and not exists (
         select 1 from activity_participants p
         where p.activity_id = a.activity_id and p.user_id = a.author_id
           and p.status = 'joined') $$,
  'no ledger row carries a campaign its author never joined the Activity for'
);

select ok(
  not has_function_privilege('anon', 'award_act_points()', 'execute')
  and not has_function_privilege('authenticated', 'award_act_points()', 'execute')
  and not has_function_privilege('service_role', 'award_act_points()', 'execute'),
  'and nobody may call the award trigger directly'
);

-- §6.1: an Act earns nothing while it is pending.
select pg_temp.new_act('e1000000-0000-4000-8000-0000000000f1',
                       'e1000000-0000-4000-8000-000000000001', null);

select is(
  (select count(*)::int from impact_entries
   where act_id = 'e1000000-0000-4000-8000-0000000000f1'),
  0,
  'a pending Act has earned nothing'
);

update acts set status = 'visible', published_at = now()
where id = 'e1000000-0000-4000-8000-0000000000f1';

select is(
  (select points from impact_entries
   where act_id = 'e1000000-0000-4000-8000-0000000000f1' and kind = 'act_published'),
  10,
  '§6.3''s ten points for publishing land when it becomes visible'
);

select is(
  (select count(*)::int from impact_entries
   where act_id = 'e1000000-0000-4000-8000-0000000000f1'),
  1,
  'and an Act claiming nothing and documenting nothing writes exactly that one row'
);

-- §8.3's visible → pending → visible, when the author edits the text.
update acts set status = 'pending', text_checked = false
where id = 'e1000000-0000-4000-8000-0000000000f1';
update acts set status = 'visible'
where id = 'e1000000-0000-4000-8000-0000000000f1';

select is(
  (select count(*)::int from impact_entries
   where act_id = 'e1000000-0000-4000-8000-0000000000f1'),
  1,
  'an edit re-screened and republished earns nothing a second time (§8.3)'
);

-- §6.1's metric rows and its bonus row, on an Act that documents a joined Activity.
insert into activity_participants (activity_id, user_id)
values ('e1000000-0000-4000-8000-0000000000a1', 'e1000000-0000-4000-8000-000000000001');

select pg_temp.new_act('e1000000-0000-4000-8000-0000000000f2',
                       'e1000000-0000-4000-8000-000000000001',
                       'e1000000-0000-4000-8000-0000000000a1');
insert into act_metrics (act_id, metric, value) values
  ('e1000000-0000-4000-8000-0000000000f2', 'waste_kg', 12),
  ('e1000000-0000-4000-8000-0000000000f2', 'trees_planted', 3);

update acts set status = 'visible', published_at = now()
where id = 'e1000000-0000-4000-8000-0000000000f2';

select is(
  (select array_agg(points order by kind, metric) from impact_entries
   where act_id = 'e1000000-0000-4000-8000-0000000000f2'),
  array[10, 10, 24, 15],
  'publishing, the documented-Activity bonus, waste at 2 a kg and trees at 5 each (§6.3)'
);

-- `O17`: an Act carries no campaign. It reaches one through the Activity it documents,
-- and the ledger row is where that lands (§6.1).
select is(
  (select count(distinct campaign_id)::int from impact_entries
   where act_id = 'e1000000-0000-4000-8000-0000000000f2'),
  1,
  'every row carries the campaign of the Activity the Act documents'
);

select is(
  (select count(*)::int from impact_entries
   where act_id = 'e1000000-0000-4000-8000-0000000000f2' and location_coarse is null),
  0,
  'and the coarse location §6.4 backfills district totals from'
);

-- §6.1: "Joining an Activity earns nothing. Otherwise, joining everything would be
-- the fastest way to farm points." An Act naming an Activity its author never joined
-- gets no bonus row.
select pg_temp.new_act('e1000000-0000-4000-8000-0000000000f3',
                       'e1000000-0000-4000-8000-000000000002',
                       'e1000000-0000-4000-8000-0000000000a1');
update acts set status = 'visible', published_at = now()
where id = 'e1000000-0000-4000-8000-0000000000f3';

select is(
  (select count(*)::int from impact_entries
   where act_id = 'e1000000-0000-4000-8000-0000000000f3'
     and kind = 'activity_documented'),
  0,
  'an author who never joined the Activity gets no bonus row'
);

-- §6.3's lower cap: 100 in the first 7 days. The newer author is three days old.
select pg_temp.new_act('e1000000-0000-4000-8000-0000000000f4',
                       'e1000000-0000-4000-8000-000000000002', null);
insert into act_metrics (act_id, metric, value)
values ('e1000000-0000-4000-8000-0000000000f4', 'people_reached', 500);

update acts set status = 'visible', published_at = now()
where id = 'e1000000-0000-4000-8000-0000000000f4';

select is(
  (select sum(points)::int from impact_entries
   where user_id = 'e1000000-0000-4000-8000-000000000002'),
  100,
  'an account three days old stops at §6.3''s 100, not its 300'
);

-- §6.1: "rows are still written with points = 0. Real-world impact still counts."
select is(
  (select value::int from impact_entries
   where act_id = 'e1000000-0000-4000-8000-0000000000f4' and metric = 'people_reached'),
  500,
  'and the claim is still on the ledger at its full value, earning what was left'
);

-- The Act is worth 10 for publishing and 500 for the people reached. This author's
-- earlier Act already spent 10 of the 100, so the publishing row takes its 10 and the
-- metric row takes the 80 that are left.
select is(
  (select array_agg(points order by kind) from impact_entries
   where act_id = 'e1000000-0000-4000-8000-0000000000f4'),
  array[10, 80],
  'the row that crosses the cap takes what is left of it, so the day lands on 100'
);

-- §6.1's sentence in full: "rows are still written with `points = 0`". A second Act
-- the same day, after the cap is spent, is where that happens.
select pg_temp.new_act('e1000000-0000-4000-8000-0000000000f6',
                       'e1000000-0000-4000-8000-000000000002', null);
insert into act_metrics (act_id, metric, value)
values ('e1000000-0000-4000-8000-0000000000f6', 'trees_planted', 4);
update acts set status = 'visible', published_at = now()
where id = 'e1000000-0000-4000-8000-0000000000f6';

select is(
  (select array_agg(points order by kind) from impact_entries
   where act_id = 'e1000000-0000-4000-8000-0000000000f6'),
  array[0, 0],
  'every row of the next Act that day is written with zero points'
);

select is(
  (select value::int from impact_entries
   where act_id = 'e1000000-0000-4000-8000-0000000000f6' and metric = 'trees_planted'),
  4,
  'and the four trees still reach the ledger, because real-world impact counts'
);

-- §6.3's upper cap, which no fixture above reaches. 300 against an account a month
-- old: 10 for publishing plus 500 people at 1 each, clipped to 290.
select pg_temp.new_act('e1000000-0000-4000-8000-0000000000f7',
                       'e1000000-0000-4000-8000-000000000001', null);
insert into act_metrics (act_id, metric, value)
values ('e1000000-0000-4000-8000-0000000000f7', 'people_reached', 500);
update acts set status = 'visible', published_at = now()
where id = 'e1000000-0000-4000-8000-0000000000f7';

select is(
  (select sum(points)::int from impact_entries
   where user_id = 'e1000000-0000-4000-8000-000000000001'),
  300,
  'an account past seven days stops at §6.3''s 300'
);

-- §6.1's floor, with the worked example the spec now carries: 0.3 kg at 2 a kg.
select pg_temp.new_act('e1000000-0000-4000-8000-0000000000f8',
                       'e1000000-0000-4000-8000-000000000003', null);
insert into act_metrics (act_id, metric, value)
values ('e1000000-0000-4000-8000-0000000000f8', 'waste_kg', 0.3);
update acts set status = 'visible', published_at = now()
where id = 'e1000000-0000-4000-8000-0000000000f8';

select results_eq(
  $$ select points, value from impact_entries
     where act_id = 'e1000000-0000-4000-8000-0000000000f8' and kind = 'metric' $$,
  $$ values (0, 0.30::numeric(10,2)) $$,
  '0.3 kg of waste at 2 a kg earns nothing, and the 0.3 kg still reaches the ledger'
);

-- §6.3 and §17.1: `active` governs scoring, not validity. An inactive rule still
-- writes its row, so §6.4's rebuild has something to rebuild from.
update points_rules set active = false where rule = 'trees_planted';
select pg_temp.new_act('e1000000-0000-4000-8000-0000000000f9',
                       'e1000000-0000-4000-8000-000000000003', null);
insert into act_metrics (act_id, metric, value)
values ('e1000000-0000-4000-8000-0000000000f9', 'trees_planted', 3);
update acts set status = 'visible', published_at = now()
where id = 'e1000000-0000-4000-8000-0000000000f9';

select results_eq(
  $$ select points, value from impact_entries
     where act_id = 'e1000000-0000-4000-8000-0000000000f9' and kind = 'metric' $$,
  $$ values (0, 3.00::numeric(10,2)) $$,
  'an inactive rule scores zero and still writes its row (§6.3)'
);
update points_rules set active = true where rule = 'trees_planted';

-- §8.3's other way into `visible`: "held → visible | A moderator approves". §6.1 now
-- says "once, whichever transition gets it there".
select pg_temp.new_act('e1000000-0000-4000-8000-0000000000fa',
                       'e1000000-0000-4000-8000-000000000003', null);
update acts set status = 'held' where id = 'e1000000-0000-4000-8000-0000000000fa';
update acts set status = 'visible', published_at = now()
where id = 'e1000000-0000-4000-8000-0000000000fa';

select is(
  (select points from impact_entries
   where act_id = 'e1000000-0000-4000-8000-0000000000fa' and kind = 'act_published'),
  10,
  'a moderator approving held content awards its points too (§8.3)'
);

-- §10.2's kill switch, and §12.6's points-exploit step.
update app_flags set engaged = true where key = 'award_points';
select pg_temp.new_act('e1000000-0000-4000-8000-0000000000f5',
                       'e1000000-0000-4000-8000-000000000001', null);
update acts set status = 'visible', published_at = now()
where id = 'e1000000-0000-4000-8000-0000000000f5';

select is(
  (select count(*)::int from impact_entries
   where act_id = 'e1000000-0000-4000-8000-0000000000f5'),
  0,
  'with award_points engaged nothing is written, and §12.6 rebuilds from the ledger'
);

select is(
  (select status from acts where id = 'e1000000-0000-4000-8000-0000000000f5'),
  'visible',
  'while the Act still publishes: the switch stops points, not screening'
);

select * from finish();
rollback;
