begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

select is_empty(
  $$ select format('%I.%I', schemaname, tablename)
     from pg_tables
     where schemaname = 'public' and not rowsecurity $$,
  'every public table has RLS enabled'
);

select is_empty(
  $$ select distinct table_name
     from information_schema.role_table_grants
     where grantee = 'anon' and table_schema = 'public' $$,
  'anon has no privileges on any table in public'
);

select is_empty(
  $$ select p.oid::regprocedure::text
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (has_function_privilege('anon', p.oid, 'execute')
         or has_function_privilege('authenticated', p.oid, 'execute'))
       and p.proname not like 'admin\_%' $$,
  'clients can only execute staff functions'
);

select is_empty(
  $$ select p.oid::regprocedure::text
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prosecdef
       and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c
                       where c like 'search_path=%') $$,
  'security definer functions pin search_path'
);

select is_empty(
  $$ select c.oid::regclass::text
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'v'
       and not coalesce(array_to_string(c.reloptions, ',')
                        ~ 'security_invoker=(true|on)', false) $$,
  'views use security_invoker'
);

select is_empty(
  $$ select n.nspname || '.' || p.proname
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('private', 'pgmq')
       and (has_function_privilege('anon', p.oid, 'execute')
         or has_function_privilege('authenticated', p.oid, 'execute')) $$,
  'clients cannot execute private or queue functions'
);

select is_empty(
  $$ select table_schema || '.' || table_name
     from information_schema.role_table_grants
     where table_schema in ('private', 'pgmq')
       and grantee in ('anon', 'authenticated') $$,
  'clients have no grants in the private or queue schemas'
);

select * from finish();
rollback;
