begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into private.rate_limit_hits (bucket, window_start, hits)
values ('acts:11111111-1111-1111-1111-111111111111', date_trunc('minute', now()), 1);

select ok(
  not has_table_privilege('authenticated', 'private.rate_limit_hits',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'private.rate_limit_hits',
    'SELECT, INSERT, UPDATE, REFERENCES')
  and not has_table_privilege('anon', 'private.rate_limit_hits',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN'),
  'no client reaches the limiter counters, which gates 6 and 7 also assert'
);

select ok(
  has_table_privilege('service_role', 'private.rate_limit_hits', 'SELECT, INSERT, UPDATE')
  and not has_table_privilege('service_role', 'private.rate_limit_hits',
    'DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('service_role', 'private.rate_limit_hits', 'REFERENCES'),
  'the limiter counts and never deletes, because the cron job clears old windows as postgres'
);

select ok(
  has_schema_privilege('service_role', 'private', 'usage')
  and not has_schema_privilege('authenticated', 'private', 'usage')
  and not has_schema_privilege('anon', 'private', 'usage'),
  'the schema grant that makes those table grants usable reaches only the backend'
);

select is_empty(
  $$ select policyname from pg_policies
     where schemaname = 'private' and tablename = 'rate_limit_hits' $$,
  'the table carries no policy, because the only grantee bypasses row level security'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'private.rate_limit_hits'::regclass)
  and (select relpersistence = 'u' from pg_class
       where oid = 'private.rate_limit_hits'::regclass),
  'row level security is on regardless, and the table is unlogged as 12.2 requires'
);

set local role service_role;

select lives_ok(
  $$ insert into private.rate_limit_hits (bucket, window_start, hits)
     values ('acts:11111111-1111-1111-1111-111111111111', date_trunc('minute', now()), 1)
     on conflict (bucket, window_start) do update set hits = private.rate_limit_hits.hits + 1 $$,
  'the limiter upserts a counter in the same call as the action it guards'
);

reset role;
select * from finish();
rollback;
