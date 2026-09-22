begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'anand');
insert into staff (user_id, role) values
  ('11111111-1111-1111-1111-111111111111', 'moderator');

select ok(
  not has_table_privilege('authenticated', 'staff',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'staff',
    'SELECT, INSERT, UPDATE, REFERENCES'),
  'authenticated holds no privilege of any kind on staff'
);

select ok(
  not has_table_privilege('service_role', 'staff',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('service_role', 'public.staff',
    'SELECT, INSERT, UPDATE, REFERENCES'),
  'the backend reads staff only inside definer functions, so service_role holds nothing either'
);

select is_empty(
  $$ select policyname from pg_policies where schemaname = 'public' and tablename = 'staff' $$,
  'staff carries no policy, because no role can reach it to be policed'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.staff'::regclass),
  'row level security is on regardless, so a later grant cannot open the table by itself'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select throws_ok(
  $$ select role from staff $$,
  '42501',
  null,
  'a signed-in user cannot read who the moderators are'
);

select throws_ok(
  $$ insert into staff (user_id, role)
     values ('11111111-1111-1111-1111-111111111111', 'admin') $$,
  '42501',
  null,
  'nobody grants themselves a staff role'
);

reset role;

select throws_ok(
  $$ delete from profiles where id = '11111111-1111-1111-1111-111111111111' $$,
  '23503',
  null,
  'a profile holding a staff role cannot be deleted, so staff are demoted and never deleted'
);

select * from finish();
rollback;
