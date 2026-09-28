-- §5.5 gives every alarm its access path: `media` has `(status, created_at)` for the
-- stuck-job alarm and `reports` has `(status, created_at)` for the 24-hour one. The
-- two conditions `health_status()` adds read `acts` and `activities` the same way and
-- had no index, so both were sequential scans — and in the healthy case, which is the
-- normal one, `exists` cannot stop early, so every check scanned both tables whole.
--
-- That matters more here than the row counts suggest: §12.5 points Route 53 at
-- `/discover/health` every 30 seconds from three checker regions, and the cost would
-- have grown with every Act ever written.
--
-- Partial, on the status the alarm asks about. `pending` is transient — §8.3 moves an
-- item out of it as soon as its text and photos pass — so both indexes stay small,
-- which a plain `(status, created_at)` index over every row would not.
-- Not `concurrently`: the CLI wraps each migration in a transaction and Postgres
-- refuses it there. Both tables are empty before launch, so the SHARE lock costs
-- milliseconds; applied later against a populated `acts` it would pause every write
-- for the length of the build, which is a quiet-hour job like §12.1's resizes.
create index acts_pending_created_at on acts (created_at) where status = 'pending';

create index activities_pending_created_at
  on activities (created_at) where status = 'pending';
