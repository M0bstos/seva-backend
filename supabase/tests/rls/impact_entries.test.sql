begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

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
insert into acts (id, author_id, title, story, category, occurred_on, location_coarse,
                  status, idempotency_key, request_hash)
values ('bbbb0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'Cleared the lake shore', 'We filled twelve sacks with plastic from the east bank this morning.',
   'environment', '2026-10-12',
   extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
   'visible', '00000000-0000-0000-0000-0000000000b1', repeat('a', 64));
insert into impact_entries (user_id, act_id, kind, points, campaign_id, location_coarse) values
  ('11111111-1111-1111-1111-111111111111', 'bbbb0000-0000-0000-0000-000000000001',
   'act_published', 10, 'cccc0000-0000-0000-0000-000000000001',
   extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography),
  ('22222222-2222-2222-2222-222222222222', null, 'act_published', 10, null,
   extensions.st_setsrid(extensions.st_makepoint(73.86, 18.53), 4326)::extensions.geography);
insert into impact_entries (user_id, act_id, kind, metric, value, points, location_coarse) values
  ('11111111-1111-1111-1111-111111111111', 'bbbb0000-0000-0000-0000-000000000001',
   'metric', 'waste_kg', 48.50, 97,
   extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography);

select ok(
  has_table_privilege('authenticated', 'impact_entries', 'SELECT')
  and not has_table_privilege('authenticated', 'impact_entries',
    'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'impact_entries',
    'INSERT, UPDATE, REFERENCES'),
  'the ledger is written by triggers, so no client touches it'
);

select ok(
  has_table_privilege('service_role', 'impact_entries', 'SELECT')
  and not has_table_privilege('service_role', 'impact_entries',
    'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('service_role', 'impact_entries',
    'INSERT, UPDATE, REFERENCES'),
  'and the backend only reads it, because the award triggers run as the owner'
);

select ok(
  not has_sequence_privilege('anon', 'impact_entries_id_seq', 'USAGE, SELECT, UPDATE')
  and not has_sequence_privilege('authenticated', 'impact_entries_id_seq',
    'USAGE, SELECT, UPDATE')
  and not has_sequence_privilege('service_role', 'impact_entries_id_seq',
    'USAGE, SELECT, UPDATE'),
  'nor can any of them reach the identity sequence'
);

select throws_ok(
  $$ insert into impact_entries (user_id, kind, points, location_coarse)
     values ('11111111-1111-1111-1111-111111111111', 'metric', 5,
       extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography) $$,
  '23514',
  null,
  'a metric row must carry its metric and value'
);

select throws_ok(
  $$ insert into impact_entries (user_id, kind, metric, value, points, location_coarse)
     values ('11111111-1111-1111-1111-111111111111', 'act_published', 'waste_kg', 5, 10,
       extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography) $$,
  '23514',
  null,
  'and a row that is not a metric must not'
);

select throws_ok(
  $$ insert into impact_entries (user_id, kind, metric, points, location_coarse)
     values ('11111111-1111-1111-1111-111111111111', 'act_published', 'waste_kg', 10,
       extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography) $$,
  '23514',
  null,
  'nor may it carry a metric with no value, which a looser check would have let through'
);

select throws_ok(
  $$ insert into impact_entries (user_id, kind, points, location_coarse)
     values ('11111111-1111-1111-1111-111111111111', 'act_published', -1,
       extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography) $$,
  '23514',
  null,
  'points are never negative'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select results_eq(
  $$ select count(*)::int from impact_entries $$,
  $$ values (2) $$,
  'a signed-in user reads their own ledger rows'
);

select is_empty(
  $$ select 1 from impact_entries
     where user_id = '22222222-2222-2222-2222-222222222222' $$,
  'and never anyone elses'
);

reset role;

set local role service_role;

select results_eq(
  $$ select count(*)::int from impact_entries $$,
  $$ values (3) $$,
  'the backend reads every ledger row, which export_account needs'
);

reset role;

select throws_ok(
  $$ delete from campaigns where id = 'cccc0000-0000-0000-0000-000000000001' $$,
  '23503',
  null,
  'a campaign with ledger rows cannot be deleted, so totals stay explainable'
);

select lives_ok(
  $$ delete from acts where id = 'bbbb0000-0000-0000-0000-000000000001' $$,
  'removing an act leaves its ledger rows behind'
);

select results_eq(
  $$ select count(*)::int from impact_entries where act_id is null $$,
  $$ values (3) $$,
  'with act_id nulled by the foreign key rather than deleted'
);

select lives_ok(
  $$ delete from profiles where id = '11111111-1111-1111-1111-111111111111';
     $$,
  'and deleting the person keeps the rows too, so campaign totals stay correct'
);

select * from finish();
rollback;
