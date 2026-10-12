-- §5.4's standing rule, applied to the one table it had been missed on: "**Storage files cannot be
-- deleted with SQL.** Removing a `storage.objects` row leaves the file orphaned. An `after delete`
-- trigger on `media` queues an `ops` job, and the operations worker deletes the file through the
-- Storage API."
--
-- `media` was the only table in the schema with such a trigger. `account_exports` also names a
-- Storage object and is also reachable by a cascade — `user_id` is `not null references profiles
-- on delete cascade` — so an erasure destroyed the only row naming an export file and left the
-- object behind for ever. Reproduced: request an export, let the worker build it, erase the
-- account, and the object is still in the private `exports` bucket with no row, no job and no
-- archive naming it, while `expire_account_exports` reads `from public.account_exports` and can
-- only see rows that still exist.
--
-- What that orphan carries is why this is launch-blocking rather than untidy: the export is
-- `to_jsonb(pp)` of `profile_private`, so **a date of birth and `guardian_consent`** — §11.2's
-- children's data — outlive the erasure that was supposed to remove them, against `O7`'s "Account
-- exports | 7 days" and §11.2's own Retention row.
--
-- **It has to be a trigger, not a step in `delete_account`.** The deletion arrives by cascade from
-- `auth.users`, so the §5.5 function cannot suppress or anticipate it — the same sentence §5.4
-- already carries for `media`, and the same reason `queue_media_deletion` exists at all.
--
-- `security definer`, for the reason measured on that sibling: a cascade can arrive as
-- `supabase_auth_admin`, which holds nothing in `pgmq`, and an invoker trigger would raise and take
-- the erasure down with it. Owned by `postgres`, `search_path` pinned, schema-qualified throughout,
-- no dynamic SQL. Its first-line permission check is the one that already happened on the parent:
-- no client role holds `delete` on `profiles`.
--
-- **A `pgmq.send` that fails takes the delete down with it**, which is the right way round and the
-- same trade `queue_media_deletion` makes. §5.2.1 gives `account_deletions` an `attempts` column
-- and a `failed` status, so a blocked erasure is one the flow retries rather than one that half
-- happens and loses a file.
--
-- No retention check, unlike `media`'s. An export is the person's own copy of their own data, not a
-- record §11.6 keeps of a violation, so nothing is ever retaining it — and `delete_export_file` is
-- the kind `expire_account_exports` already sends for the ordinary 7-day case.
create function queue_export_deletion() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Nothing to delete if the file was never written: the row exists from the moment the export is
  -- requested, and `claim_ops_jobs` fills `file_path` when it hands the job out.
  if old.file_path is null then
    return null;
  end if;

  -- The path and nothing else. §9.8 allows an object path — it carries a user id and no coordinate
  -- — and `exports` is the only bucket this object can be in, so unlike a content file there is no
  -- bucket to resolve (§17.1's no-bucket-column decision applies to `media`, not here).
  perform pgmq.send('ops', jsonb_build_object(
    'kind', 'delete_export_file',
    'export_id', old.id,
    'file_path', old.file_path
  ));

  return null;
end;
$$;

revoke execute on function queue_export_deletion()
  from public, anon, authenticated, service_role;

-- No grant to anybody. A trigger function is executed by the trigger, under the table owner, and
-- nothing calls this directly — the same shape as `queue_media_deletion`.

create trigger account_exports_queue_deletion
  after delete on account_exports
  for each row execute function queue_export_deletion();
