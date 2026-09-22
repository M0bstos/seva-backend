begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

select ok(
  has_table_privilege('authenticated', 'points_rules', 'SELECT')
  and not has_table_privilege('authenticated', 'points_rules',
    'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'points_rules',
    'INSERT, UPDATE, REFERENCES'),
  'authenticated reads the scoring rules and can write nothing'
);

select ok(
  has_table_privilege('service_role', 'points_rules', 'SELECT')
  and not has_table_privilege('service_role', 'points_rules',
    'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('service_role', 'points_rules',
    'INSERT, UPDATE, REFERENCES'),
  'the backend reads the rules to reject an out-of-range metric and writes none of them'
);

select results_eq(
  $$ select rule, points_per_unit, max_per_act from points_rules order by rule $$,
  $$ values ('act_published'::text, 10.00::numeric, null::numeric),
            ('activity_documented', 10.00, null),
            ('animals_helped', 5.00, 50.00),
            ('people_reached', 1.00, 500.00),
            ('trees_planted', 5.00, 200.00),
            ('volunteer_hours', 10.00, 12.00),
            ('waste_kg', 2.00, 200.00) $$,
  'the starting values are the ones in the spec'
);

select throws_ok(
  $$ insert into points_rules (rule, points_per_unit) values ('free_points', 1000) $$,
  '23514',
  null,
  'a rule outside the known set is rejected by the check, not stored'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select results_eq(
  $$ select count(*)::int from points_rules where active $$,
  $$ values (7) $$,
  'a signed-in user reads every active rule, so the app can show scoring'
);

select throws_ok(
  $$ update points_rules set points_per_unit = 1000 where rule = 'act_published' $$,
  '42501',
  null,
  'nobody raises their own points per unit'
);

reset role;
set local role service_role;

select results_eq(
  $$ select max_per_act from points_rules where rule = 'volunteer_hours' $$,
  $$ values (12.00::numeric) $$,
  'the backend can read a per-Act maximum'
);

reset role;
select * from finish();
rollback;
