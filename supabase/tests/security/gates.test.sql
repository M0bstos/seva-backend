begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

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
       and c.relkind in ('r', 'p', 'v', 'm', 'f', 'S')
       and case when c.relkind = 'S'
             then has_sequence_privilege('anon', c.oid, 'USAGE, SELECT, UPDATE')
             else has_any_column_privilege('anon', c.oid, 'SELECT, INSERT, UPDATE, REFERENCES')
               or has_table_privilege('anon', c.oid,
                    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
           end $$,
  'anon has no table, column or sequence privilege in public'
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
       and c.relkind in ('r', 'p', 'v', 'm', 'f', 'S')
       and case when c.relkind = 'S'
             then has_sequence_privilege(r.rolname, c.oid, 'USAGE, SELECT, UPDATE')
             else has_any_column_privilege(r.rolname, c.oid, 'SELECT, INSERT, UPDATE, REFERENCES')
               or has_table_privilege(r.rolname, c.oid,
                    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
           end $$,
  'clients have no table, column or sequence privilege in the private or queue schemas'
);

-- The grants inside cron belong to supabase_admin and no migration can revoke them,
-- so this asks the question a migration can get wrong: who can enter the schema.
select is_empty(
  $$ select r.rolname || ' -> cron'
     from (values ('anon'::name), ('authenticated'::name)) as r (rolname)
     join pg_namespace n on n.nspname = 'cron'
     where has_schema_privilege(r.rolname, n.oid, 'usage') $$,
  'clients have no usage on the cron schema'
);

-- Gate 11. §17.1 already reserved 9 for the exposed-schemas gate and 10 for the
-- policy-initplan one, both still unwritten, so this takes the next free number.
-- O16 opened the first grant outside public, private, pgmq and cron, and
-- gates 2 and 7 are both blind to it: granting auth.users to authenticated leaves
-- them at zero rows while handing every client every email, phone and password hash.
-- anon and authenticated already hold usage on schema auth by Supabase default, so
-- the absence of a table grant is the only thing standing in the way.
select is_empty(
  $$ select r.rolname || ' -> ' || c.oid::regclass::text
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     cross join (values ('anon'::name), ('authenticated'::name)) as r (rolname)
     where n.nspname = 'auth'
       and c.relkind in ('r', 'p', 'v', 'm', 'f', 'S')
       and case when c.relkind = 'S'
             then has_sequence_privilege(r.rolname, c.oid, 'USAGE, SELECT, UPDATE')
             else has_any_column_privilege(r.rolname, c.oid,
                    'SELECT, INSERT, UPDATE, REFERENCES')
               or has_table_privilege(r.rolname, c.oid,
                    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
           end $$,
  'clients have no table, column or sequence privilege in the auth schema'
);

-- Gate 12. The one extension this project must never install, which is the opposite
-- shape from every other gate: it asserts an absence rather than a grant.
--
-- Reaching an Edge Function from inside Postgres needs `pg_net`, directly or through
-- `supabase_functions.http_request`. **Measured on the local stack, 1 October 2026,
-- `create extension pg_net` arrives with:**
--
--   * `usage on schema net` granted explicitly to `anon`, `authenticated` and
--     `service_role`;
--   * `execute` on `net.http_get` and `net.http_post` granted explicitly to the same
--     three;
--   * **every privilege on `net._http_response` and `net.http_request_queue` through
--     `PUBLIC`** — `arwdDxtm`, so insert, update, delete and select.
--
-- A caller holding only the publishable key could therefore make the database issue
-- arbitrary outbound HTTP from inside the project's network, and read the body of
-- every response the project has ever fetched. §9.1's first layer says `anon` gets
-- no privilege at all.
--
-- **None of it can be revoked.** Every object is owned by `supabase_admin`, so a
-- migration running as `postgres` gets `WARNING: no privileges could be revoked` on
-- the schema, the functions and both tables, and nothing changes — measured. This is
-- the pg_cron situation of gate 8, except that what it opens is arbitrary SSRF rather
-- than a schedule, so the answer is not to install it rather than to guard the door.
--
-- And no other gate would see it: gates 2 and 7 name `public`, `private`, `pgmq` and
-- `pgmq_public`, gate 8 names `cron`, and `net` is none of those. Enabling pg_net from
-- the dashboard would leave every other gate green.
--
-- What this costs is in §4.1: the three workers are invoked by the ops host's cron
-- rather than from the database. pg_cron stays for §12.2's two purges, which are SQL
-- and need no HTTP.
select is_empty(
  $$ select extname from pg_extension where extname = 'pg_net' $$,
  'pg_net is not installed, because its grants to anon cannot be revoked'
);

select * from finish();
rollback;
