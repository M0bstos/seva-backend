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
  $$ select c.oid::regclass::text
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind in ('r', 'p', 'v', 'm', 'f')
       and (has_any_column_privilege('anon', c.oid, 'SELECT, INSERT, UPDATE, REFERENCES')
         or has_table_privilege('anon', c.oid,
              'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')) $$,
  'anon has no table or column privilege in public'
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
     where n.nspname in ('private', 'pgmq', 'pgmq_public')
       and (has_function_privilege('anon', p.oid, 'execute')
         or has_function_privilege('authenticated', p.oid, 'execute')) $$,
  'clients cannot execute private or queue functions'
);

select is_empty(
  $$ select r.rolname || ' -> ' || c.oid::regclass::text
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     cross join (values ('anon'::name), ('authenticated'::name)) as r (rolname)
     where n.nspname in ('private', 'pgmq', 'pgmq_public')
       and c.relkind in ('r', 'p', 'v', 'm', 'f')
       and (has_any_column_privilege(r.rolname, c.oid, 'SELECT, INSERT, UPDATE, REFERENCES')
         or has_table_privilege(r.rolname, c.oid,
              'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')) $$,
  'clients have no table or column privilege in the private or queue schemas'
);

select * from finish();
rollback;
