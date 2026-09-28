-- §12.2 withholds `delete` on `private.discover_cache` from `service_role`, and its
-- first draft rested that on a premise it no longer carries: "its key space is
-- bounded by the snapping in §7.3, and nothing deletes from it". The snapping bounds
-- two of the key's components and not the other three: §7.3's own key carries a page
-- and a date range, so `GET /discover` takes a cursor and two dates straight from the
-- caller, and the cell is snapped from coordinates the caller also chooses. Measured on a local stack: 40 requests at one
-- cell and radius left 40 permanent rows, 20 from distinct cursors and 20 from
-- distinct date ranges, and `expires_at` gates reads rather than row lifetime.
--
-- So something has to delete them, and §12.2 already has the pattern: like the
-- rate-limit purge, this is scheduled from a migration of its own, so
-- `cron.job.username` records `postgres`, which owns `private` and needs no grant.
-- `service_role` still holds exactly `select, insert, update` — the grant §12.2 names
-- is unchanged, and no Edge Function or worker can delete a cache row.
--
-- Every 5 minutes, matching the counter purge. An entry is dead 60 seconds after it
-- is written (§7.3), so the table holds at most five minutes of distinct keys rather
-- than every key ever asked for.
select cron.schedule(
  'purge-discover-cache',
  '*/5 * * * *',
  $job$ delete from private.discover_cache where expires_at < now() $job$
);
