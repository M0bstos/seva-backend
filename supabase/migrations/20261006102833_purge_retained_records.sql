-- §11.6's 180 days, released. "The operations worker purges rows past `purge_after`", for both
-- retention tables — and §11.6 spells out why this must be a definer function rather than a
-- grant: "`delete ... where purge_after < now()` needs `select` on the column it filters, so
-- granting the worker's role a direct delete would also give it a read privilege and make 'no
-- role may read it' false. The purge is therefore a definer function owned by the table's owner,
-- and `service_role` holds nothing on the table."
--
-- **One function for both tables**, which is the reading CLAUDE.md's own sentence takes — "what
-- it holds is `execute` on the two functions a worker calls — **the purge** and the
-- account-deletion function (§5.5)". They are one duty with one clock, one caller and one
-- privilege need; two functions would be two definer frames over the same `private` schema for
-- no gain.
--
-- §11.6's constraint on this frame is obeyed: "a definer frame can see every column of the row
-- it deletes, so neither function may return or log `phone` or `email`". What comes back is two
-- counts.
--
-- **The file deletions are queued here rather than returned**, which was a defect found in
-- review. §5.4 keeps file deletion out of SQL, so a worker has to do that part — but handing
-- the keys back in the reply made the delete of the rows and the delete of the files two
-- transactions, with the keys existing only in between. A worker that died after the commit,
-- or hit one Storage error in a loop over three buckets, left objects in `uploads`, `media` or
-- `quarantine` with nothing left anywhere that named them: unrecoverable orphans, where §11.6
-- and `O7` say the file is gone at 180 days. `queue_media_deletion` already solves the same
-- problem the other way round and says why — "a `pgmq.send` that fails takes the deletion down
-- with it, and that is the right way round". One job per released row, so a failure retries
-- that row's files and nothing else, and an unclaimed job is something §12.5's dead-and-waiting
-- arm over `pgmq.a_ops` can see — which is the other half of the finding: a purge that stopped
-- after launch had no monitor at all.
--
-- **The keys carry no bucket, which §17.1 records as a decision**: one key names the same object
-- in every bucket it could sit in, and a bucket written at snapshot time can be stale, because a
-- held photo's original moves to `quarantine` only if the content is later removed. So the worker
-- deletes each key from `uploads`, `media` and `quarantine` — measured safe, since `remove` on a
-- key that is not there is a no-op.
--
-- `security definer` in `public` so gate 4 sees the pinned `search_path`; every name
-- schema-qualified; no dynamic SQL; no arguments, so there is nothing for a caller to widen.
create function purge_retained_records() returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_content int;
  v_queued int;
  v_registrations int;
begin
  with released as (
    delete from private.preserved_content
    where purge_after <= now()
    returning id, file_paths
  ), still_named as (
    -- **A path another live retention row still names is not released**, which the third review
    -- round made load-bearing: `delete_account` now preserves a held or removed photo on its own
    -- merits as well as naming it in its parent Act's snapshot, because the two clocks are
    -- different and the parent's cannot stand in for the child's. So one object can legitimately
    -- be named by two rows, and the earlier row's purge must not take the later row's file. Same
    -- test `queue_media_deletion` applies at the other end of the same duty, for the same reason.
    select distinct pth.path
    from released
    cross join lateral unnest(coalesce(released.file_paths, array[]::text[])) as pth (path)
    -- `pc.purge_after > now()` is load-bearing and easy to weaken by accident: every CTE in this
    -- statement reads the pre-delete snapshot, so a row is still visible to this `exists` after the
    -- `delete` above has claimed it. A liveness test written as `pc.id <> released.id` would let a
    -- row pin its own path and make every shared object immortal. This predicate is the complement
    -- of the delete's `purge_after <= now()`, which is why it cannot.
    where exists (
      select 1 from private.preserved_content pc
      where pc.purge_after > now() and pc.file_paths @> array[pth.path]
    )
  ), queued as (
    select pgmq.send('ops', jsonb_build_object(
             'kind', 'delete_retained_files',
             'preserved_id', released.id,
             'paths', to_jsonb(
               array(
                 select pth.path
                 from unnest(released.file_paths) as pth (path)
                 where pth.path not in (select path from still_named)
               )
             )
           ))
    from released
    where released.file_paths is not null
      and cardinality(released.file_paths) > 0
      -- Nothing to send if every path it named is still claimed by a live row.
      and exists (
        select 1 from unnest(released.file_paths) as pth (path)
        where pth.path not in (select path from still_named)
      )
  )
  -- Both arms are counted, and the `queued` count is what makes it run: a data-modifying CTE
  -- always executes, but a plain `select` one executes only if something references it, so
  -- counting the rows is also what sends the jobs.
  select (select count(*) from released), (select count(*) from queued)
  into v_content, v_queued;

  with released as (
    delete from private.retained_registrations
    where purge_after <= now()
    returning 1
  )
  select count(*) into v_registrations from released;

  -- Counts only. Rule 3(1)(h)'s phone and email are read by the delete and go no further,
  -- which §11.6 requires of this frame, and the object keys now leave by the queue.
  return jsonb_build_object(
    'preserved_content', v_content,
    'registrations', v_registrations,
    'file_jobs', v_queued
  );
end;
$$;

revoke execute on function purge_retained_records()
  from public, anon, authenticated, service_role;
-- CLAUDE.md: "what it holds is `execute` on the two functions a worker calls — the purge and the
-- account-deletion function (§5.5)". This is the first of those two.
grant execute on function purge_retained_records() to service_role;
