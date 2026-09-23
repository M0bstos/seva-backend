begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

-- The purge belongs to its own migration, so its tests sit apart from the grants and
-- policies of the table's migration; reverting one leaves the other green.
--
-- §7.3 caps seven routes per day, so the counter table also holds a day-length window
-- opened at IST midnight (§5.1). Nothing tested the purge in phase 1, which is how it
-- shipped deleting everything older than an hour.

create temporary table boundary as
select date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata'
       as ist_midnight;

insert into private.rate_limit_hits (bucket, window_start, hits)
select * from (
  select 'day:today' as bucket, b.ist_midnight as window_start, 29 as hits from boundary b
  union all
  select 'day:yesterday', b.ist_midnight - interval '1 day', 30 from boundary b
  union all
  -- Hour windows truncate in the database timezone, so this one runs 18:00-19:00 UTC
  -- and is still open when the IST day begins at 18:30 UTC. Deleting it would let an
  -- hourly cap be spent twice before 00:30 IST.
  select 'hour:straddling', date_trunc('hour', b.ist_midnight - interval '10 minutes'), 9
  from boundary b
  union all
  select 'hour:closed', date_trunc('hour', b.ist_midnight - interval '3 hours'), 9
  from boundary b
  union all
  select 'minute:now', date_trunc('minute', now()), 4 from boundary b
) as fixtures;

-- Run the scheduled command itself rather than a copy, so these assertions fail if
-- the job is ever repointed at a different predicate.
do $$
declare scheduled text;
begin
  select command into strict scheduled from cron.job where jobname = 'purge-rate-limit-windows';
  execute scheduled;
end
$$;

select results_eq(
  $$ select bucket from private.rate_limit_hits
     where bucket like 'day:%' or bucket like 'hour:%' or bucket like 'minute:%'
     order by bucket $$,
  $$ values ('day:today'::text), ('hour:straddling'::text), ('minute:now'::text) $$,
  'the purge clears every window that has closed and keeps every window still open'
);

select is(
  (select hits from private.rate_limit_hits where bucket = 'day:today'),
  29,
  'today''s daily cap survives, which the shipped one-hour predicate did not allow'
);

select is_empty(
  $$ select bucket from private.rate_limit_hits where bucket = 'day:yesterday' $$,
  'and yesterday''s is gone, so the key space stays bounded (§12.2)'
);

select is(
  (select hits from private.rate_limit_hits where bucket = 'hour:straddling'),
  9,
  'an hour window open across IST midnight is kept: it still has a cap to enforce'
);

-- The fixtures above are wall-clock sensitive: against the shipped one-hour predicate
-- the straddling window is only deleted once the time is past 00:30 IST, so between
-- midnight and then they would pass against the bug. This one has no blind spot.
select ok(
  (select command from cron.job where jobname = 'purge-rate-limit-windows')
    like '%Asia/Kolkata%'
  and (select command from cron.job where jobname = 'purge-rate-limit-windows')
    like '%interval ''1 hour''%',
  'the purge measures against the IST day less the longest non-day window, at any hour'
);

select is(
  (select count(*)::int from cron.job where jobname = 'purge-rate-limit-windows'),
  1,
  'still one job, because cron.schedule replaced the applied one in place'
);

select is(
  (select username from cron.job where jobname = 'purge-rate-limit-windows'),
  'postgres',
  'still running as the owner of private, so the cleanup needs no grant (§12.2)'
);

select * from finish();
rollback;
