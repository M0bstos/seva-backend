-- A roll-forward of `claim_ops_jobs`, replacing one branch. §8.4: "A verdict is bound to **what it
-- is about** and to **when it was claimed**" — and the `export_account` branch was bound to
-- neither, because it wrote a path with an `update … where` that could match nothing and then
-- handed the job out regardless.
--
-- Found by the `seam-qa` agent on 13 October 2026 and reproduced: `POST /account/delete` then
-- `POST /account/export`, one worker pass, `{"claimed":2,"done":1,"failed":1}` and an object in the
-- `exports` bucket for a user with no `auth.users` row. The sibling defect — the file of a
-- *completed* export outliving its row — is fixed by the `account_exports` after-delete trigger in
-- the migration before this one. They share a cause and not a file.
--
-- Everything else in the function is unchanged; the whole body is restated because §13.3 forbids
-- editing an applied migration.

create or replace function claim_ops_jobs(p_count int) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_msg record;
  v_kind text;
  v_job jsonb;
  v_subject uuid;
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
        where id = (v_msg.message ->> 'export_id')::uuid and file_path is null
        returning id into v_subject;
      exception when invalid_text_representation or null_value_not_allowed then
        perform pgmq.archive('ops', v_msg.msg_id);
        continue;
      end;

      -- **The row has to still be there**, which is `publish_photo`'s rule below applied to this
      -- kind, and it was missing. The update's `where` found nothing and raised nothing, so the job
      -- went out anyway: the worker built an export for an account that no longer existed, wrote an
      -- unreachable object to the `exports` bucket, and `complete_account_export` then refused it
      -- on the `file_path` check — five retries and a §8.4 archive alarm for work that should have
      -- been dropped. Reachable with two ordinary calls in one order: `POST /account/delete` then
      -- `POST /account/export`, both answered, the erasure claimed first.
      --
      -- Dropped rather than archived, which is `claim_message_jobs`' distinction: §8.4 archives work
      -- that *failed*, and this is work that no longer exists. `request_account_export` already
      -- cited this very cascade as a gate on insert — "`account_exports.user_id` `not null
      -- references profiles cascade`, so a row cannot exist without a profile" — and nobody traced
      -- it to the delete side.
      --
      -- `file_path is not null` is not an alternative test here: a second claim of the same job
      -- legitimately finds the path already written, so the update matches nothing. Re-reading the
      -- row is what tells the two cases apart.
      if v_subject is null then
        select id into v_subject from public.account_exports
        where id = (v_msg.message ->> 'export_id')::uuid;
        if not found then
          perform pgmq.delete('ops', v_msg.msg_id);
          continue;
        end if;
      end if;
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
