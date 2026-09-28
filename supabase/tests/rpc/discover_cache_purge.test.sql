begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

-- §12.2 as amended: the key space is not bounded by §7.3's snapping, because two of
-- its five components — the page and the date range — come straight from the caller.
-- The purge does that work instead, without giving any role a delete.

insert into private.discover_cache (cache_key, payload, expires_at) values
  ('discover:POINT(73.86 18.52):5:::::10', '{"activities": []}'::jsonb,
   now() + interval '60 seconds'),
  ('discover:POINT(73.86 18.52):5::::expired:10', '{"activities": []}'::jsonb,
   now() - interval '1 second'),
  ('feed:POINT(73.85 18.5):5::::10', '{"acts": []}'::jsonb,
   now() - interval '4 minutes');

select is(
  (select schedule from cron.job where jobname = 'purge-discover-cache'),
  '*/5 * * * *',
  'the purge is scheduled every five minutes, like the counter purge (§12.2)'
);

select is(
  (select username from cron.job where jobname = 'purge-discover-cache'),
  'postgres',
  'and runs as the role that owns private, so it needs no grant (§12.2)'
);

select ok(
  (select active from cron.job where jobname = 'purge-discover-cache'),
  'and is active, which a schedule and a command alone would not prove'
);

-- Run the scheduled command itself rather than a copy, so these assertions fail if
-- the job is ever repointed at a different predicate.
do $$
declare scheduled text;
begin
  select command into strict scheduled from cron.job where jobname = 'purge-discover-cache';
  execute scheduled;
end
$$;

-- Scoped to this test's own three fixtures. Reading the whole table made the
-- assertion depend on what every other session had left inside its 60 seconds — and
-- `deno task test:api` commits real cache rows, so CI running both suites against one
-- stack could fail this on ordering alone, with nothing to do with the change.
select results_eq(
  $$ select cache_key from private.discover_cache
     where cache_key in (
       'discover:POINT(73.86 18.52):5:::::10',
       'discover:POINT(73.86 18.52):5::::expired:10',
       'feed:POINT(73.85 18.5):5:::10'
     )
     order by cache_key $$,
  $$ values ('discover:POINT(73.86 18.52):5:::::10'::text) $$,
  'every entry past its 60 seconds is gone, and the live one stays (§7.3)'
);

select ok(
  not has_table_privilege('service_role', 'private.discover_cache', 'delete')
  and not has_table_privilege('authenticated', 'private.discover_cache', 'delete')
  and not has_table_privilege('anon', 'private.discover_cache', 'delete'),
  'no role an Edge Function runs as can delete a cache row (§12.2)'
);

select ok(
  has_table_privilege('service_role', 'private.discover_cache', 'select')
  and has_table_privilege('service_role', 'private.discover_cache', 'insert')
  and has_table_privilege('service_role', 'private.discover_cache', 'update'),
  'and the three the Discover and Feed functions need are untouched (§12.2)'
);

select * from finish();
rollback;
