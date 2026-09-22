begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'anand'),
  ('22222222-2222-2222-2222-222222222222', 'bina');
insert into impact_totals (user_id, points, trees_planted) values
  ('11111111-1111-1111-1111-111111111111', 120, 8),
  ('22222222-2222-2222-2222-222222222222', 40, 2);

select ok(
  has_table_privilege('authenticated', 'impact_totals', 'SELECT')
  and not has_table_privilege('authenticated', 'impact_totals',
    'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'impact_totals',
    'INSERT, UPDATE, REFERENCES'),
  'points are earned, so no client writes any total'
);

select ok(
  has_table_privilege('service_role', 'impact_totals', 'SELECT')
  and not has_table_privilege('service_role', 'impact_totals',
    'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('service_role', 'impact_totals',
    'INSERT, UPDATE, REFERENCES'),
  'only the ledger triggers write totals, so the backend holds no write either'
);

select throws_ok(
  $$ insert into impact_totals (user_id, points) values
     ('11111111-1111-1111-1111-111111111111', 5) $$,
  '23505',
  null,
  'totals are one row per person'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select is_empty(
  $$ select points from impact_totals
     where user_id = '22222222-2222-2222-2222-222222222222' $$,
  'another persons totals are not readable, because 7.2 scopes this table to the owner'
);

select results_eq(
  $$ select points from impact_totals $$,
  $$ values (120) $$,
  'a signed-in user reads their own totals'
);

select throws_ok(
  $$ update impact_totals set points = 9999
     where user_id = '11111111-1111-1111-1111-111111111111' $$,
  '42501',
  null,
  'nobody awards themselves points'
);

reset role;

select lives_ok(
  $$ delete from profiles where id = '22222222-2222-2222-2222-222222222222' $$,
  'a profile with totals can be deleted'
);

select is_empty(
  $$ select 1 from impact_totals
     where user_id = '22222222-2222-2222-2222-222222222222' $$,
  'and its totals cascade away with it'
);

select * from finish();
rollback;
