-- §7.3 caps seven routes per day and §7.4 gives DAILY_LIMIT_REACHED its own code, so
-- the limiter needs a day-length window alongside the minute and hour ones §12.2
-- named. The scheduled purge landed with only those two in mind and deletes anything
-- older than an hour, which takes the day counter with it on the first run after
-- 01:00 IST and lifts every daily cap for the rest of the day.
--
-- A day counter's window opens at IST midnight (§5.1: day-based caps use the
-- Asia/Kolkata calendar day), so the purge measures against that instead. The extra
-- hour is not slack: hour windows are truncated in the database timezone, so the one
-- running 18:00-19:00 UTC is still open when the IST day begins at 18:30 UTC, and
-- deleting it would let an hourly cap be spent twice before 00:30 IST. Subtracting
-- the longest non-day window is what makes "no open window is deleted" true.
--
-- cron.schedule replaces a job of the same name in place, keeping its jobid and its
-- username — verified against pg_cron 1.6.4 — so the applied migration is left alone
-- rather than edited.
select cron.schedule(
  'purge-rate-limit-windows',
  '*/5 * * * *',
  $job$ delete from private.rate_limit_hits
        where window_start < (date_trunc('day', now() at time zone 'Asia/Kolkata')
                              at time zone 'Asia/Kolkata') - interval '1 hour' $job$
);
