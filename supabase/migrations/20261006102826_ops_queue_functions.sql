-- The `ops` queue's claim and completion, which §1.1 counts as the third worker: "Operations
-- (cleanup and health checks)". Eight kinds reach it, each from a producer already built:
--
--   `delete_media_files`  §5.4's `after delete` trigger on `media`
--   `quarantine_file`     §11.6's takedown, from `set_content_status`
--   `publish_photo`       §8.3's held → visible for a photo, from `set_content_status`
--   `sign_out`            §10.2's `admin_suspend_user`
--   `export_account`      §7.3's `POST /account/export`
--   `delete_account`      §7.3's `POST /account/delete`
--
-- The shape is `claim_moderation_jobs`', for the reasons §8.4 and §17.1 give it: the archive and
-- kind checks come before any cast, because one malformed message whose cast ran first starved
-- the whole moderation queue — the raise rolled back `pgmq.read`'s own visibility update and the
-- message was re-read for ever, with §12.5's dead-job alarm empty the whole time.
--
-- `security invoker`: §5.1's queues migration grants `service_role` everything pgmq needs, and
-- §5.2 grants it `select` on `media`.

create function claim_ops_jobs(p_count int) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_msg record;
  v_kind text;
  v_job jsonb;
  v_jobs jsonb := '[]'::jsonb;
begin
  if p_count is null or p_count < 1 or p_count > 100 then
    raise exception 'claim_ops_jobs takes a count between 1 and 100';
  end if;

  for v_msg in
    select msg_id, read_ct, message from pgmq.read('ops', 60, p_count)
  loop
    v_kind := v_msg.message ->> 'kind';

    if v_msg.read_ct > 5 then
      -- §8.4: "After that they are archived and an alarm fires; nothing is silently dropped."
      -- A `delete_account` that keeps failing also marks its request `failed`, which §5.2.1
      -- gives the table a status and an `attempts` column for — so the person can ask again
      -- (`request_account_deletion` restarts a failed one) rather than waiting on a queue
      -- nobody is watching.
      --
      -- **Guarded, because the cast is inside the branch that exists to archive.** Review
      -- reproduced it: a `delete_account` message with a malformed `user_id` raised
      -- `invalid input syntax for type uuid` on the sixth read, which rolled back `pgmq.read`'s
      -- own visibility update — so the message could never be archived, no alarm could ever fire,
      -- and every later job in the batch went with it. That is §17.1's 2 October starvation in a
      -- new place: "the `id` cast ran before the archive checks … that message was re-read for
      -- ever and could never reach the archive." The archive is unconditional either way, so a
      -- message whose subject id is unusable is archived without the status write rather than
      -- taking the queue down: §8.4's "nothing is silently dropped" is about the message, and a
      -- row that cannot be identified has nothing to mark.
      begin
        if v_kind = 'delete_account' then
          update public.account_deletions
          set status = 'failed', attempts = coalesce(attempts, 0) + 1
          where user_id = (v_msg.message ->> 'user_id')::uuid and status = 'pending';
        elsif v_kind = 'export_account' then
          -- §5.2.1 gives `export_status` a `failed` value for the same reason, and §7.3's
          -- `GET /account/export/:id` is what shows it.
          update public.account_exports
          set status = 'failed'
          where id = (v_msg.message ->> 'export_id')::uuid and status = 'pending';
        end if;
      exception when invalid_text_representation or null_value_not_allowed then
        null;
      end;
      perform pgmq.archive('ops', v_msg.msg_id);
      continue;
    end if;

    if v_kind is null or v_kind not in (
      'delete_media_files', 'quarantine_file', 'publish_photo',
      'sign_out', 'export_account', 'delete_account',
      -- The two retention deletes. Both are sent by the function that released the record, in
      -- the same transaction, so that no object outlives the row naming it (§11.6, `O7`) — see
      -- `purge_retained_records` and `expire_account_exports` for why that had to change.
      'delete_retained_files', 'delete_export_file'
    ) then
      perform pgmq.archive('ops', v_msg.msg_id);
      continue;
    end if;

    -- `export_account` records the object's path before the object exists. Same reasoning as
    -- `publish_photo` below — §17.1: "an argument nothing checked against `upload_path` left that
    -- enforced nowhere in SQL" — and it is what lets `O7`'s expiry collect a file whose completion
    -- never landed. §7.3 fixes the name: "writes `exports/{user_id}/{export_id}.json`".
    --
    -- **Built from the row's own columns, not from the message**, which review corrected by the
    -- very line above: the `export_id` was checked against the row while the `user_id` was taken
    -- from the message and compared to nothing, so a message with a mismatched `user_id` wrote
    -- another person's prefix — and `complete_account_export` would then compare the worker's path
    -- to that same recorded path, agree, and have §7.3 sign it for an hour. Taking both from the
    -- row makes the invariant structural and removes the cast that starved the queue above.
    if v_kind = 'export_account' then
      begin
        update public.account_exports
        set file_path = user_id::text || '/' || id::text || '.json'
        where id = (v_msg.message ->> 'export_id')::uuid and file_path is null;
      exception when invalid_text_representation or null_value_not_allowed then
        perform pgmq.archive('ops', v_msg.msg_id);
        continue;
      end;
    end if;

    -- `publish_photo` is the one kind that needs a row read: §8.1 derives the published path
    -- from `upload_path` rather than taking it as an argument, and §17.1 records why — "an
    -- argument nothing checked against `upload_path` left that enforced nowhere in SQL".
    -- `processing` is the status `set_content_status` leaves an approved photo in, so a photo
    -- staff have since removed resolves to nothing and the job is dropped rather than
    -- republishing bytes a takedown took down.
    if v_kind = 'publish_photo' then
      begin
        select jsonb_build_object('media_id', m.id, 'upload_path', m.upload_path)
        into v_job
        from public.media m
        where m.id = (v_msg.message ->> 'media_id')::uuid and m.status = 'processing';
      exception when invalid_text_representation or null_value_not_allowed then
        perform pgmq.archive('ops', v_msg.msg_id);
        continue;
      end;
      if v_job is null then
        perform pgmq.delete('ops', v_msg.msg_id);
        continue;
      end if;
    else
      -- Every other kind carries what the worker needs. The message is passed through rather
      -- than re-read, because the paths in a `delete_media_files` job describe a row that is
      -- already gone (§5.4's trigger fires `after delete`).
      v_job := v_msg.message - 'kind';
    end if;

    v_jobs := v_jobs || jsonb_build_array(
      jsonb_build_object('msg_id', v_msg.msg_id, 'kind', v_kind) || v_job
    );
  end loop;

  return v_jobs;
end;
$$;

revoke execute on function claim_ops_jobs(int)
  from public, anon, authenticated, service_role;
grant execute on function claim_ops_jobs(int) to service_role;

-- A job the worker finished. §8.4's `vt > now()` window is what makes `msg_id` a time-bounded
-- capability rather than an integer any secret-key holder could guess, and what stops two
-- workers both completing one job after the 60 seconds lapsed.
--
-- **Bound to the kind as well as the window**, which review found missing: §8.4 says "a verdict
-- is bound to **what it is about** and to **when it was claimed**", and this had only the second
-- half. Measured before the fix — a live `delete_account` job passed here answered
-- `{"status":"done"}`, the message left `pgmq.q_ops`, `pgmq.a_ops` stayed empty and
-- `account_deletions.status` stayed `pending`. §8.4 says "nothing is silently dropped" and that
-- is exactly a DPDP erasure dropped with no record and no §12.5 arm able to see it: the job is
-- in no queue and no archive. `complete_photo_publication`, `complete_sign_out` and
-- `complete_account_export` were already bound both ways; these two were the outliers.
create function complete_ops_job(p_msg_id bigint, p_kind text) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform 1 from pgmq.q_ops q
  where q.msg_id = p_msg_id and q.vt > now()
    and q.message ->> 'kind' = p_kind;
  if not found then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  perform pgmq.delete('ops', p_msg_id);
  return jsonb_build_object('status', 'done');
end;
$$;

revoke execute on function complete_ops_job(bigint, text)
  from public, anon, authenticated, service_role;
grant execute on function complete_ops_job(bigint, text) to service_role;
