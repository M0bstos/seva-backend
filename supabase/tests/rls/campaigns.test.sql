begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into campaigns (id, title, description, goal_metric, goal_value, starts_on, ends_on, status)
values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Clean the lake',
   'Volunteers clearing plastic from the lake shore every weekend.',
   'waste_kg', 5000, '2026-10-01', '2026-12-31', 'active'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'Plant for the monsoon',
   'A district-wide tree planting drive before the monsoon arrives.',
   'trees_planted', 20000, '2027-04-01', '2027-06-30', 'draft'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'Feed the strays',
   'Neighbourhood feeding rounds for street animals through winter.',
   'animals_helped', 800, '2026-01-01', '2026-03-31', 'ended');

select ok(
  has_table_privilege('authenticated', 'campaigns', 'SELECT')
  and not has_table_privilege('authenticated', 'campaigns',
    'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'campaigns',
    'INSERT, UPDATE, REFERENCES'),
  'authenticated reads campaigns and can write nothing, progress included'
);

select ok(
  has_table_privilege('service_role', 'campaigns', 'SELECT')
  and not has_table_privilege('service_role', 'campaigns',
    'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('service_role', 'campaigns',
    'INSERT, UPDATE, REFERENCES'),
  'the backend validates a campaign_id by reading; progress comes from a definer trigger'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select results_eq(
  $$ select title from campaigns $$,
  $$ values ('Clean the lake'::text) $$,
  'a signed-in user reads active campaigns only'
);

select is_empty(
  $$ select 1 from campaigns
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'an unreleased draft campaign is not readable'
);

select throws_ok(
  $$ update campaigns set progress_value = 5000
     where id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'campaign progress has no client write path'
);

reset role;
set local role service_role;

select results_eq(
  $$ select count(*)::int from campaigns $$,
  $$ values (3) $$,
  'the backend sees every campaign, whatever its status'
);

reset role;
select * from finish();
rollback;
