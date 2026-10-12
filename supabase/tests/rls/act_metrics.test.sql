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
insert into acts (id, author_id, title, story, category, occurred_on, location_coarse,
                  status, idempotency_key, request_hash)
values
  ('bbbb0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
   'Cleared the lake shore', 'We filled twelve sacks with plastic from the east bank this morning.',
   'environment', '2026-10-12',
   extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
   'visible', '00000000-0000-0000-0000-0000000000b1', repeat('a', 64)),
  ('bbbb0000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222',
   'Planted saplings', 'Put in twenty saplings along the ridge path with help from neighbours.',
   'environment', '2026-10-14',
   extensions.st_setsrid(extensions.st_makepoint(73.87, 18.54), 4326)::extensions.geography,
   'pending', '00000000-0000-0000-0000-0000000000b2', repeat('b', 64));
insert into act_metrics (act_id, metric, value) values
  ('bbbb0000-0000-0000-0000-000000000001', 'waste_kg', 48.50),
  ('bbbb0000-0000-0000-0000-000000000002', 'trees_planted', 20);

-- Chandra blocks Bina, so `acts_select` hides Bina's visible Act from Chandra. `O19`'s widening has
-- to carry that across to the metrics, or the embed would survive the block that hid the Act.
-- A third person rather than Anand, so the assertions written against Anand's view keep theirs.
insert into blocks (blocker_id, blocked_id) values
  ('33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222');

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.act_metrics'::regclass and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'public.act_metrics', a.attname, 'insert')
       and a.attname not in ('act_id', 'metric', 'value') $$,
  'the create function supplies the metric and its value, and nothing else exists to supply'
);

select ok(
  has_table_privilege('authenticated', 'act_metrics', 'SELECT')
  and not has_table_privilege('authenticated', 'act_metrics',
    'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'act_metrics',
    'INSERT, UPDATE, REFERENCES'),
  'claimed impact is written by the create function and never by a client'
);

select ok(
  has_table_privilege('service_role', 'act_metrics', 'SELECT, INSERT')
  and not has_table_privilege('service_role', 'act_metrics',
    'UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('service_role', 'act_metrics', 'UPDATE, REFERENCES'),
  'metrics are inserted once and never updated, so no role holds update'
);

select throws_ok(
  $$ insert into act_metrics (act_id, metric, value)
     values ('bbbb0000-0000-0000-0000-000000000001', 'people_reached', 0) $$,
  '23514',
  null,
  'a claimed metric must be greater than zero'
);

select throws_ok(
  $$ insert into act_metrics (act_id, metric, value)
     values ('bbbb0000-0000-0000-0000-000000000001', 'trees_planted', 3.5) $$,
  '23514',
  null,
  'counted things are whole numbers'
);

select lives_ok(
  $$ insert into act_metrics (act_id, metric, value)
     values ('bbbb0000-0000-0000-0000-000000000001', 'volunteer_hours', 2.5) $$,
  'hours and kilograms are not'
);

select throws_ok(
  $$ insert into act_metrics (act_id, metric, value)
     values ('bbbb0000-0000-0000-0000-000000000001', 'waste_kg', 10) $$,
  '23505',
  null,
  'one row per metric per act'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select results_eq(
  $$ select metric::text from act_metrics order by metric::text $$,
  $$ values ('volunteer_hours'::text), ('waste_kg'::text) $$,
  'metrics are readable for a visible act and hidden for one still in screening'
);

-- §17 `O19`, decided 12 October 2026: §7.2's "plus your own" governs the embed as well as the Act,
-- so an author reads the metrics of their own Act in any status. Before this they could read the
-- Act and get an empty metrics array on it.
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select is(
  (select count(*)::int from act_metrics
   where act_id = 'bbbb0000-0000-0000-0000-000000000002'),
  1,
  'an author reads the metrics of their own pending Act (§7.2, O19)'
);

-- And the property the policy now gets for free rather than by restating it: a blocked author's
-- metrics are no more readable than their Act. This is enforced by `acts_select`, because a table
-- referenced inside an RLS `using` expression is itself subject to its own RLS — so the assertion
-- pins the behaviour a client sees, not a clause in this policy. Mutation testing is what showed
-- the restated clause was dead code (§17.1, 12 October 2026).
set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';
select is(
  (select count(*)::int from act_metrics
   where act_id = 'bbbb0000-0000-0000-0000-000000000001'),
  0,
  'and a blocked author''s metrics stay hidden, matching acts_select (§7.2, §5.2)'
);
reset role;

reset role;
set local role service_role;

select lives_ok(
  $$ insert into act_metrics (act_id, metric, value)
     values ('bbbb0000-0000-0000-0000-000000000002', 'people_reached', 30) $$,
  'the create function records a claimed metric'
);

reset role;

select lives_ok(
  $$ delete from acts where id = 'bbbb0000-0000-0000-0000-000000000001' $$,
  'an act can be deleted'
);

select is_empty(
  $$ select 1 from act_metrics
     where act_id = 'bbbb0000-0000-0000-0000-000000000001' $$,
  'and its metrics cascade away with it'
);

select * from finish();
rollback;
