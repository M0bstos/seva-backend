begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into private.discover_cache (cache_key, payload, expires_at)
values ('discover:cell:2km:environment:1', '{"activities":[]}'::jsonb, now() + interval '60 seconds');

select ok(
  not has_table_privilege('authenticated', 'private.discover_cache',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'private.discover_cache',
    'SELECT, INSERT, UPDATE, REFERENCES')
  and not has_table_privilege('anon', 'private.discover_cache',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN'),
  'no client reaches the discover cache, logged out or signed in'
);

select ok(
  has_table_privilege('service_role', 'private.discover_cache', 'SELECT, INSERT, UPDATE')
  and not has_table_privilege('service_role', 'private.discover_cache',
    'DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('service_role', 'private.discover_cache', 'REFERENCES'),
  'discover and feed fill and refill it, and nothing deletes from it'
);

select is_empty(
  $$ select policyname from pg_policies
     where schemaname = 'private' and tablename = 'discover_cache' $$,
  'the cache carries no policy, because the only grantee bypasses row level security'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'private.discover_cache'::regclass)
  and (select relpersistence = 'u' from pg_class
       where oid = 'private.discover_cache'::regclass),
  'row level security is on regardless, and the table is unlogged as 12.2 requires'
);

set local role service_role;

select lives_ok(
  $$ insert into private.discover_cache (cache_key, payload, expires_at)
     values ('discover:cell:2km:environment:1', '{"activities":[1]}'::jsonb,
             now() + interval '60 seconds')
     on conflict (cache_key) do update
       set payload = excluded.payload, expires_at = excluded.expires_at $$,
  'a stale entry is replaced by the upsert that refills it, never deleted'
);

reset role;
select * from finish();
rollback;
