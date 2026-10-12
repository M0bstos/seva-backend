-- Two indexes `private.preserved_content` has needed since the day it gained readers, found by
-- measuring plans rather than by reading: both lookups against it were sequential scans over a
-- table that holds 180 days of every takedown on the platform, and both sit inside paths with a
-- legal clock on them (§11.6).
--
-- A migration of its own rather than an edit to the table's, because that one is applied — the
-- same roll-forward rule §13.3 sets and `complete_photo_screening` already followed.
--
-- `(source_kind, source_id)`: `delete_account` asks three times per erasure whether a subject
-- already has a live snapshot, once per branch, and `set_content_status` will ask the same
-- question of anything it removes. Measured before: `Seq Scan on preserved_content` inside a
-- `Nested Loop Anti Join`, so once per subject row.
create index preserved_content_source
  on private.preserved_content (source_kind, source_id);

-- `file_paths`: `queue_media_deletion` runs `pc.file_paths && array[...]` from an `after delete`
-- trigger, so once per `media` row a cascade removes — the actual N+1, and the one that decides
-- whether a file §11.6 is retaining survives an erasure. GIN because the operator is array
-- overlap, which btree cannot serve.
--
-- **This one is not yet proved, and the first claim about it was an overclaim.** Measured with
-- costs: under default planner settings, and with the trigger's full predicate
-- (`purge_after > now() and file_paths && …`), the planner picks the `purge_after` btree and
-- applies the overlap as a heap filter — dropping this index changes that plan not at all. The
-- reason is in `pg_class`: `reltuples = -1, relpages = 0`, so the table has never been analysed
-- and `purge_after > now()` gets a 157-row default estimate. In production that predicate matches
-- nearly every row, because every live retention row satisfies it, and the overlap is the
-- selective half — which is when this index should win. So it stays, and §14.4 gains the honest
-- step: seed, `analyze private.preserved_content`, and re-measure the trigger's plan. What the
-- earlier `enable_seqscan = off` run established was only that the index is readable.
create index preserved_content_file_paths
  on private.preserved_content using gin (file_paths);
