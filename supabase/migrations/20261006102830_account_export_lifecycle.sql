-- §7.3's export, after the worker has written the file, and §O7's seven days afterwards: "The
-- file is deleted after 7 days."

-- What the worker calls once `exports/{user_id}/{export_id}.json` is in the private bucket.
-- `security invoker`: §5.2 grants `service_role` `update (status, file_path, ready_at,
-- expires_at)` on `account_exports` — exactly these four columns — and names the operations
-- worker as a writer.
create function complete_account_export(
  p_msg_id bigint,
  p_export_id uuid,
  p_file_path text
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_message jsonb;
begin
  select q.message into v_message
  from pgmq.q_ops q
  where q.msg_id = p_msg_id and q.vt > now();
  if not found then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;
  -- The export id has to be the one the job named, not one the caller chose: without this a
  -- secret-key holder could point any person's export row at any object in the bucket, and
  -- §7.3 signs whatever `file_path` holds for an hour.
  if v_message ->> 'kind' <> 'export_account'
     or (v_message ->> 'export_id')::uuid is distinct from p_export_id then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'export_id');
  end if;

  -- `file_path` is already on the row: `claim_ops_jobs` wrote it when it handed the job out, so
  -- that `O7`'s expiry can reach an object whose completion never landed. The worker passes the
  -- path it actually wrote, so this is where the two are checked against each other — a mismatch
  -- means the worker and the queue disagree about which object exists, and signing either would be
  -- a guess (§7.3 signs whatever `file_path` holds).
  if p_file_path is distinct from
     (select file_path from public.account_exports where id = p_export_id) then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'file_path');
  end if;

  update public.account_exports
  set status = 'ready',
      ready_at = now(),
      -- `O7`'s "Account exports | 7 days | Product", which `read_account_export` reads before it
      -- hands a path back and `expire_account_exports` reads to collect them.
      expires_at = now() + interval '7 days'
  where id = p_export_id and status = 'pending';
  if not found then
    perform pgmq.delete('ops', p_msg_id);
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  perform pgmq.delete('ops', p_msg_id);
  return jsonb_build_object('status', 'ready');
end;
$$;

revoke execute on function complete_account_export(bigint, uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function complete_account_export(bigint, uuid, text) to service_role;

-- `O7`'s seven days. §5.4 is clear that "storage files cannot be deleted with SQL", so a worker
-- deletes the object — but the job is **queued here, in the same transaction as the mark**,
-- which was a defect found in review. Handing the paths back in the reply made the mark and the
-- delete two transactions: one Storage failure left an export marked `expired` with its file
-- still in the private `exports` bucket and nothing left that named it, and that object is
-- `to_jsonb(pp)`, so it carries the date of birth and `guardian_consent` (§9.2, §11.2). `O7`
-- says seven days. Same shape and same reasoning as §11.6's purge, and an unclaimed job is
-- something §12.5's dead-and-waiting arm can see where a lost key is not.
--
-- The row itself is kept. §5.2.1 gives `account_exports` no `purge_after` and §O7's table lists
-- the file rather than the record, so what expires is the file: a person asking
-- `GET /account/export/:id` afterwards is told `expired` rather than `NOT_FOUND`, which is the
-- truthful answer and the one §7.3's `{ status }` shape is for.
create function expire_account_exports() returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_expired int;
  v_queued int;
begin
  -- **Any row whose file was written, not only a `ready` one.** Review found the hole: the worker
  -- writes the object and then calls `complete_account_export`, so a completion that is refused
  -- five times leaves §8.4 marking the row `failed` with `expires_at` null — and the object, which
  -- is `to_jsonb(pp)` and so carries a date of birth and `guardian_consent`, sat in the private
  -- `exports` bucket uncollectable for ever, against `O7`'s seven days. `file_path` is now written
  -- at claim time by `claim_ops_jobs` rather than at completion, so a row always names its object
  -- before the object exists, and `created_at` is the clock for a row that never became `ready`.
  with gone as (
    select id, file_path from public.account_exports
    where file_path is not null
      and (
        (status = 'ready' and expires_at is not null and expires_at <= now())
        or (status = 'failed' and created_at <= now() - interval '7 days')
      )
    for update
  ),
  marked as (
    update public.account_exports e
    set status = 'expired'
    from gone where e.id = gone.id
    returning e.id, gone.file_path
  ),
  queued as (
    select pgmq.send('ops', jsonb_build_object(
             'kind', 'delete_export_file',
             'export_id', marked.id,
             'file_path', marked.file_path
           ))
    from marked
    where marked.file_path is not null
  )
  -- Counting `queued` is also what runs it: a plain `select` CTE nothing references does not
  -- execute, where the two data-modifying arms above always do.
  select (select count(*) from marked), (select count(*) from queued)
  into v_expired, v_queued;

  return jsonb_build_object('expired', v_expired, 'file_jobs', v_queued);
end;
$$;

revoke execute on function expire_account_exports()
  from public, anon, authenticated, service_role;
grant execute on function expire_account_exports() to service_role;
