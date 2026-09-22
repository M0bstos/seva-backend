begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'anand'),
  ('22222222-2222-2222-2222-222222222222', 'bina');
insert into account_exports (id, user_id, status) values
  ('eeee0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'pending'),
  ('eeee0000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'ready');

select ok(
  has_table_privilege('authenticated', 'account_exports', 'SELECT')
  and not has_table_privilege('authenticated', 'account_exports',
    'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'account_exports',
    'INSERT, UPDATE, REFERENCES'),
  'a person reads the status of their export and cannot forge one'
);

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.account_exports'::regclass
       and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'public.account_exports', a.attname, 'insert')
       and a.attname <> 'user_id' $$,
  'the backend supplies only whose row it is; every other column takes its default'
);

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.account_exports'::regclass
       and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'public.account_exports', a.attname, 'update')
       and a.attname not in ('status', 'file_path', 'ready_at', 'expires_at') $$,
  'the operations worker updates only what it produces, never whose export it is'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select results_eq(
  $$ select status::text from account_exports $$,
  $$ values ('pending'::text) $$,
  'a person sees only their own export requests'
);

select throws_ok(
  $$ insert into account_exports (user_id) values ('11111111-1111-1111-1111-111111111111') $$,
  '42501',
  null,
  'exports are queued by the account function, not by clients'
);

select throws_ok(
  $$ update account_exports set file_path = 'exports/theirs.json'
     where id = 'eeee0000-0000-0000-0000-000000000002' $$,
  '42501',
  null,
  'nobody points their export at another persons file'
);

reset role;
set local role service_role;

select lives_ok(
  $$ update account_exports
     set status = 'ready', file_path = 'exports/anand.json',
         ready_at = now(), expires_at = now() + interval '7 days'
     where id = 'eeee0000-0000-0000-0000-000000000001' $$,
  'the operations worker publishes a finished export'
);

reset role;

select lives_ok(
  $$ delete from profiles where id = '22222222-2222-2222-2222-222222222222' $$,
  'a profile with an export can be deleted'
);

select is_empty(
  $$ select 1 from account_exports
     where user_id = '22222222-2222-2222-2222-222222222222' $$,
  'and its export rows cascade away with it'
);

select * from finish();
rollback;
