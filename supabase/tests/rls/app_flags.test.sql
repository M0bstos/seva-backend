begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

select ok(
  has_table_privilege('authenticated', 'app_flags', 'SELECT')
  and not has_table_privilege('authenticated', 'app_flags',
    'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'app_flags',
    'INSERT, UPDATE, REFERENCES'),
  'authenticated reads the kill switches and can write none of them'
);

select ok(
  has_table_privilege('service_role', 'app_flags', 'SELECT')
  and not has_table_privilege('service_role', 'app_flags',
    'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('service_role', 'app_flags',
    'INSERT, UPDATE, REFERENCES'),
  'every route reads the switches; only the admin function sets them'
);

select results_eq(
  $$ select key::text from app_flags where not engaged order by key::text $$,
  $$ values ('award_points'), ('create_activities'), ('create_acts'),
            ('joins'), ('read_only'), ('uploads') $$,
  'all six switches exist and start disengaged'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select results_eq(
  $$ select count(*)::int from app_flags $$,
  $$ values (6) $$,
  'a signed-in user reads every switch, so the app can hide a disabled feature'
);

select throws_ok(
  $$ update app_flags set engaged = true where key = 'read_only' $$,
  '42501',
  null,
  'a client cannot put the platform into read-only mode'
);

reset role;
set local role service_role;

select results_eq(
  $$ select engaged from app_flags where key = 'read_only' $$,
  $$ values (false) $$,
  'every route can read a kill switch before acting, which is what 10.2 requires'
);

reset role;
select * from finish();
rollback;
