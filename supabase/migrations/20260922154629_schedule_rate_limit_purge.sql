-- §12.2: scheduled from its own migration, so cron.job.username records postgres,
-- which owns private and needs no grant. Windows are one minute and one hour, so
-- anything older than an hour can no longer be counted against a limit.
select cron.schedule(
  'purge-rate-limit-windows',
  '*/5 * * * *',
  $job$ delete from private.rate_limit_hits where window_start < now() - interval '1 hour' $job$
);
