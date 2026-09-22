begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'anand');
insert into account_deletions (user_id) values ('11111111-1111-1111-1111-111111111111');

select ok(
  not has_table_privilege('authenticated', 'account_deletions',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'account_deletions',
    'SELECT, INSERT, UPDATE, REFERENCES'),
  'a deletion request is not readable by the client that asked for it'
);

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.account_deletions'::regclass
       and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'public.account_deletions', a.attname, 'insert')
       and a.attname <> 'user_id' $$,
  'the backend supplies only whose row it is; every other column takes its default'
);

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.account_deletions'::regclass
       and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'public.account_deletions', a.attname, 'update')
       and a.attname not in ('status', 'attempts', 'completed_at') $$,
  'the worker records progress and never rewrites whose deletion it is'
);

select is_empty(
  $$ select conname from pg_constraint
     where conrelid = 'public.account_deletions'::regclass and contype = 'f' $$,
  'the deletion record has no foreign key, so it survives the profile it refers to'
);

select is_empty(
  $$ select policyname from pg_policies
     where schemaname = 'public' and tablename = 'account_deletions' $$,
  'account_deletions carries no policy, because no client can reach it to be policed'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.account_deletions'::regclass),
  'row level security is on regardless, so a later grant cannot open the table by itself'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select throws_ok(
  $$ select status from account_deletions $$,
  '42501',
  null,
  'clients cannot read the deletion queue'
);

reset role;
set local role service_role;

select lives_ok(
  $$ update account_deletions set status = 'completed', completed_at = now()
     where user_id = '11111111-1111-1111-1111-111111111111' $$,
  'the operations worker marks a deletion done'
);

reset role;

select lives_ok(
  $$ delete from profiles where id = '11111111-1111-1111-1111-111111111111' $$,
  'the profile is deleted'
);

select results_eq(
  $$ select count(*)::int from account_deletions $$,
  $$ values (1) $$,
  'and the deletion record outlives it, which is what proves the deletion happened'
);

select * from finish();
rollback;
