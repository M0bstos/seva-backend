-- §5.4: "**Storage files cannot be deleted with SQL.** Removing a `storage.objects`
-- row leaves the file orphaned. An `after delete` trigger on `media` queues an `ops`
-- job, and the operations worker deletes the file through the Storage API."
--
-- It lands now rather than with that worker because this phase is what first writes a
-- file to the **public** `media` bucket. Before it, a deleted row orphaned one private
-- upload; after it, it orphans an object anyone can fetch — and §5.4's account
-- deletion and §11.2's erasure both go through this cascade. The same shape §8.2's
-- screening trigger took: the trigger ships ahead of its worker, and the jobs
-- accumulate until week 4-5 builds one.
--
-- **That backlog was not visible, and the earlier version of this comment claimed it
-- was.** §12.5's arm counts *archived* jobs, and pgmq archives on read count — so a
-- queue with no consumer never increments one, never archives, and shows nothing.
-- §8.2's analogy does not carry: a stuck Act is visible through the pending-15-minutes
-- arm, where an orphaned file has no symptom at all. `health_status` gains a
-- waiting-job arm over all three queues in the migration after this one.
--
-- `security definer`, and for a different reason than the counter triggers. Nobody
-- holds `delete` on `media` at all — the grants are `select`, `insert` and `update`
-- (§5.2) — so every deletion arrives by cascade: from `profiles` when §5.4 deletes an
-- account, from `acts` when it deletes their Acts. An invoker trigger would then run
-- as whichever role drove the cascade, which need not be one `pgmq` admits.
--
-- **Measured in both directions**, by opening a session as the role rather than
-- assuming it — non-membership blocks `set role`, not a connection:
--
--     docker exec -e PGPASSWORD=postgres supabase_db_seva-backend \
--       psql -h 127.0.0.1 -U supabase_auth_admin -d postgres
--
-- As `security invoker`, `delete from auth.users where id = ...` raises `permission
-- denied for schema pgmq` from inside this function and **the user row survives**. As
-- `security definer` the same delete succeeds and the job lands in `pgmq.q_ops`. Of
-- the roles that can drive this cascade, only `service_role` and `postgres` hold
-- `usage` on `pgmq` and `execute` on `pgmq.send`; `supabase_auth_admin`,
-- `authenticated` and `anon` hold none of it. Definer, owned by `postgres`, is what
-- makes the erasure path independent of who starts it.
--
-- §9.1's other three requirements hold: it lives in `public`, pins `search_path = ''`,
-- and builds no dynamic SQL. Its first-line permission check is the one that already
-- happened — but not on `media`: a cascade does **not** check `DELETE` on the child,
-- and `supabase_auth_admin` holds none on `media` while its cascade deletes the row
-- anyway (measured). What was checked is authority on the *parent*, and no client
-- role holds `delete` on `profiles`, `acts` or `activities` — asserted in
-- `tests/rls/profiles.test.sql` and `tests/rls/acts.test.sql` rather than here.
--
-- **A `pgmq.send` that fails takes the deletion down with it**, and that is the right
-- way round. §5.4's erasure carries a legal clock, so the temptation is to let the row
-- go and lose the job — but that orphans a file on a public bucket and §11.6's
-- retention duty has no record of it. §5.2.1 already gives `account_deletions` an
-- `attempts` column and a `failed` status, so a blocked deletion is one the flow
-- retries rather than one it half-performs.
create function queue_media_deletion() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- The paths and nothing else. §9.8 allows an object path, which carries a user id
  -- and no coordinate; what it must not carry is the row, so the labels, the bytes and
  -- the dimensions stay behind.
  --
  -- Which bucket each path is in is the operations worker's to apply, from §8.1's
  -- convention: `upload_path` in `uploads`, `public_path` and `thumb_path` in `media`.
  -- It has to try `quarantine` as well, because §11.6's takedown moves a removed
  -- file there and neither `media` nor `private.preserved_content.file_paths` records
  -- which bucket a path ended up in. Recorded in §17.1 for that worker.
  -- **Not a file §11.6 is retaining.** §5.4 keeps a removed or held row, its snapshot
  -- "and its files for 180 days", and §11.6 has account deletion copy that content
  -- into `private.preserved_content` *before* deleting anything else — precisely "so
  -- a user cannot erase the record of their own violation by deleting their account".
  -- Without this test the cascade did exactly that to the files half: reproduced, the
  -- job named the same object `file_paths` had recorded, and line 49 sends the worker
  -- to `quarantine` to find it. The retention row is the authority on what survives,
  -- and it is already there by the time this fires because of that ordering. When the
  -- 180 days are up, §11.6's purge of `preserved_content` is what releases the files.
  --
  -- It has to be here. The deletion arrives by cascade, so the §5.5 account function
  -- cannot suppress the job from outside, and `session_replication_role` is not
  -- available to `postgres` on Supabase.
  if exists (
    select 1 from private.preserved_content pc
    where pc.purge_after > now()
      and pc.file_paths && array_remove(
            array[old.upload_path, old.public_path, old.thumb_path], null)
  ) then
    return null;
  end if;

  perform pgmq.send('ops', jsonb_build_object(
    'kind', 'delete_media_files',
    'media_id', old.id,
    'upload_path', old.upload_path,
    'public_path', old.public_path,
    'thumb_path', old.thumb_path
  ));
  return null;
end;
$$;

revoke execute on function queue_media_deletion()
  from public, anon, authenticated, service_role;

create trigger media_queue_deletion
  after delete on media
  for each row execute function queue_media_deletion();
