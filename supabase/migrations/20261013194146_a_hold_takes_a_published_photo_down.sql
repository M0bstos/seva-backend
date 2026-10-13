-- A roll-forward of `set_content_status`, replacing the held branch for a photo. §13.3 forbids
-- editing an applied migration, so the whole body is restated; nothing else in it changes.
--
-- The allowlist change for the new `unpublish_file` job rides along in this migration, because the
-- two are one behavioural change and neither is coherent alone: a hold that queues a job no claim
-- function admits would have it archived in silence, and a kind nothing sends is dead surface.

create or replace function set_content_status(
  p_actor audit_actor,
  p_staff_id uuid,
  p_act_id uuid,
  p_activity_id uuid,
  p_media_id uuid,
  p_status content_status,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_act public.acts%rowtype;
  v_activity public.activities%rowtype;
  v_media public.media%rowtype;
  v_subject text;
  v_subject_id uuid;
  v_before text;
  v_from public.content_status;
  v_snapshot jsonb;
  v_path text;
  -- What the media row is actually set to, which is not always what was asked for: §8.3's
  -- held → visible for a photo lands in `processing` until the file is copied. The audit
  -- row and the answer both report this rather than the request, because §10.3 renders
  -- that log on screen and §11.6 makes it the evidentiary record of a takedown — a row
  -- claiming a photo became visible while §12.5 alarms on it being stuck is worse than no
  -- row. For an Act or an Activity it is simply the status asked for.
  v_written text;
begin
  -- A fault in the calling function rather than in a request, which is why it raises
  -- where everything below returns a §7.4 code — and it is not dead weight even though
  -- both callers pass one subject: with two set, the read below would take the Act while
  -- every predicate in the removal block matched the Activity's photos too, so the guard
  -- stops a wrong write rather than only an ugly error. `pending` needs no guard of its
  -- own: the transition rule refuses it as `VALIDATION_FAILED`, which is the better
  -- answer.
  if num_nonnulls(p_act_id, p_activity_id, p_media_id) <> 1 then
    raise exception 'set_content_status takes exactly one subject';
  end if;
  -- §10: "the audit log records who acted, not 'the admin tool'", and §11.6 makes this row
  -- the evidentiary record of a takedown, so the attribution is checked where it is written
  -- rather than trusted to the callers. Both of today's callers get it right — which is the
  -- point: the third one is the one nobody reviewed, and §5.2.1's own check pairs the two
  -- columns without being able to ask whether the id belongs to anybody. It raises rather
  -- than returning a code because that check would fire only after every write, so a
  -- takedown would roll back on an opaque 23514 instead of refusing before it began.
  if (p_actor = 'staff') <> (p_staff_id is not null) then
    raise exception 'set_content_status takes a staff id exactly when the actor is staff';
  end if;
  if p_actor = 'staff' and not exists (
    select 1 from public.staff where user_id = p_staff_id
  ) then
    raise exception 'set_content_status attributes a staff action to a staff member';
  end if;

  -- Locked, because every branch below reads a status and then writes against it, and
  -- §17.1's phase-3 lesson is that a decision has to be bound to what it was made
  -- about: two moderators acting on one item, or a report crossing §8.5's threshold
  -- while a moderator removes the same Act, would otherwise both pass their own checks.
  --
  -- The snapshot is built here too, while the row is in hand and before anything has
  -- moved — §11.6's copy-first ordering. `to_jsonb` of the whole row rather than a field
  -- list, so a column §5.2.1 gains later is preserved without this function being
  -- edited to know about it.
  if p_act_id is not null then
    select * into v_act from public.acts where id = p_act_id for update;
    if not found then
      return jsonb_build_object('error', 'NOT_FOUND');
    end if;
    v_subject := 'act';
    v_subject_id := p_act_id;
    v_before := v_act.status::text;
    v_from := v_act.status;
    -- The metrics ride along because §7.2 embeds them on an Act and §6's ledger is
    -- built from them: a preserved Act without its claims is not the record of what
    -- was published.
    v_snapshot := to_jsonb(v_act) || jsonb_build_object(
      'metrics',
      (select coalesce(jsonb_object_agg(metric::text, value), '{}'::jsonb)
       from public.act_metrics where act_id = p_act_id)
    );
  elsif p_activity_id is not null then
    select * into v_activity from public.activities where id = p_activity_id for update;
    if not found then
      return jsonb_build_object('error', 'NOT_FOUND');
    end if;
    v_subject := 'activity';
    v_subject_id := p_activity_id;
    v_before := v_activity.status::text;
    v_from := v_activity.status;
    v_snapshot := to_jsonb(v_activity);
  else
    select * into v_media from public.media where id = p_media_id for update;
    if not found then
      return jsonb_build_object('error', 'NOT_FOUND');
    end if;
    v_subject := 'media';
    v_subject_id := p_media_id;
    v_before := v_media.status::text;
    v_snapshot := to_jsonb(v_media);
    -- §5.3 gives `media` an enum of its own, mapped onto `content_status` here so the
    -- transition rule below is written once for all three subjects. `uploading`,
    -- `processing` and `rejected` all read as "not published and not held": a photo in
    -- any of them has no verdict a moderator could approve.
    v_from := case v_media.status
                when 'ready' then 'visible'::public.content_status
                when 'held' then 'held'::public.content_status
                when 'removed' then 'removed'::public.content_status
                else 'pending'::public.content_status
              end;
  end if;

  -- §8.3's table, in one place.
  --
  --   * **Removal from any status.** §8.3 lists it from `visible` and `held`, but §11.6
  --     puts a 3-hour clock on a court or government order and §12.6 has staff remove
  --     the content with no mention of what state screening left it in. Content stuck
  --     `pending` that a court orders down has to be removable.
  --   * **Approval only from `held`**, which is §8.3's own row. A moderator must not be
  --     able to publish something `pending`, because §8 opens "Nothing a person writes
  --     or uploads is public until it has been screened" and `pending` means the verdict
  --     has not arrived.
  --   * **`removed` is terminal.** §8.3 gives it no outgoing row, and §11.6 keeps the
  --     row for 180 days precisely as the record of a takedown.
  --   * `held` → `held` is allowed, as a no-op that still writes its audit row: it is
  --     what a moderator confirming a system hold looks like, and what §8.5 does when a
  --     second report crosses a threshold on content already held.
  if v_from = 'removed' or not (
    p_status = 'removed'
    or (p_status = 'held' and v_from in ('pending', 'visible', 'held'))
    or (p_status = 'visible' and v_from = 'held')
  ) then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'status');
  end if;

  v_written := p_status::text;

  if p_status = 'removed' then
    -- §11.6's "Removed content and its records … snapshot in `private.preserved_content`",
    -- written before the row it describes is touched. One row per subject, whichever
    -- subject it was, carrying every object key that belongs to it: §11.6 keeps "its
    -- files for 180 days", and the purge that releases them reads this column.
    --
    -- The keys are gathered from all three path columns rather than the published one
    -- alone, because a held photo has no `public_path` and its original is the only file
    -- there is (§8.1, §17.1). One key names the same object in every bucket it could sit
    -- in, which is what lets the purge delete it without a bucket recorded here.
    insert into private.preserved_content (source_kind, source_id, snapshot, file_paths)
    values (
      v_subject, v_subject_id, v_snapshot,
      (select array_agg(distinct p.path)
       from public.media m
       cross join lateral unnest(
         array_remove(array[m.upload_path, m.public_path, m.thumb_path], null)
       ) as p (path)
       where (p_act_id is not null and m.act_id = p_act_id)
          or (p_activity_id is not null and m.activity_id = p_activity_id)
          or (p_media_id is not null and m.id = p_media_id))
    );

    -- §6.2: "When staff remove an Act, its ledger rows are deleted and the totals
    -- triggers subtract them." §5.4 enforces never-update through grants rather than a
    -- blocking trigger for exactly this, so the delete is the whole reversal. Held
    -- content never earned, so an Act removed from `held` has no rows to find.
    if p_act_id is not null then
      delete from public.impact_entries where act_id = p_act_id;
    end if;

    -- §11.6: "The public `media` bucket must stop serving a removed file immediately.
    -- Moving it to `quarantine` rather than deleting it satisfies both the takedown and
    -- the retention duty." Only the keys the public bucket actually serves are moved. A
    -- held photo's original sits in the private `uploads` bucket (§8.1, §17.1), which
    -- serves nothing, so moving it would buy no takedown and add a failure mode; it is
    -- still named in `file_paths` above, so §11.6's 180 days and the purge that releases
    -- them both reach it where it is. The paths are read before the update below nulls
    -- them.
    for v_path in
      select unnest(array_remove(array[m.public_path, m.thumb_path], null))
      from public.media m
      where (p_act_id is not null and m.act_id = p_act_id)
         or (p_activity_id is not null and m.activity_id = p_activity_id)
         or (p_media_id is not null and m.id = p_media_id)
    loop
      perform pgmq.send('ops', jsonb_build_object(
        'kind', 'quarantine_file',
        'path', v_path
      ));
    end loop;

    -- Every photo of the removed content, and the photo itself when it was the subject.
    -- `public_path` goes with the status for the reason the enum migration gives: a path
    -- left behind is one a retry or an export could hand out after the file has moved.
    update public.media m
    set status = 'removed', public_path = null, thumb_path = null
    where ((p_act_id is not null and m.act_id = p_act_id)
        or (p_activity_id is not null and m.activity_id = p_activity_id)
        or (p_media_id is not null and m.id = p_media_id))
      and m.status <> 'removed';

    -- §11.6 again, and the second place §8.1 records a published object key: the
    -- moderation worker sets `profiles.avatar_path` to the same `upload_path` it
    -- publishes under, so nulling `media.public_path` alone would leave a removed avatar
    -- still rendering on a profile every signed-in person can read. Keyed on
    -- `upload_path`, which nothing nulls, so this is order-independent.
    -- Keyed by the photo's owner so this uses the primary key: `profiles` carries no
    -- index on `avatar_path`, and a takedown would otherwise scan the table.
    update public.profiles p
    set avatar_path = null
    from public.media m
    where p.id = m.owner_id
      and p.avatar_path = m.upload_path
      and ((p_act_id is not null and m.act_id = p_act_id)
        or (p_activity_id is not null and m.activity_id = p_activity_id)
        or (p_media_id is not null and m.id = p_media_id));

    if p_act_id is not null then
      update public.acts set status = 'removed' where id = p_act_id;
    elsif p_activity_id is not null then
      update public.activities set status = 'removed' where id = p_activity_id;
    end if;

  elsif p_act_id is not null then
    if p_status = 'visible' then
      -- §5.2.1 ties `published_at` to the Act "first becoming visible", not to the path
      -- it took to get there, and §6.1 awards points "once, whichever transition gets it
      -- there" — so the two records have to agree about which transition that was.
      -- Coalesced exactly as `private.publish_if_screened` does, because §8.3 sends an
      -- edited Act through `visible` more than once.
      update public.acts
      set status = 'visible', published_at = coalesce(published_at, now())
      where id = p_act_id;
    else
      update public.acts set status = 'held' where id = p_act_id;
    end if;

  elsif p_activity_id is not null then
    -- No ledger and no `published_at`: §6.1 awards nothing for an Activity and §5.2.1
    -- gives `activities` no such column.
    update public.activities set status = p_status where id = p_activity_id;

  elsif p_status = 'visible' then
    -- §8.3's held → visible for a photo, which §17.1 records as having had no writer for
    -- `public_path`: "approving a held photo makes its content visible with no photo
    -- behind it". §5.4 says storage cannot be reached from SQL, so the copy is an `ops`
    -- job and the photo waits in `processing` until it lands — the status a claim hands
    -- out, so §12.5's stuck-screening arm sees a publication that failed.
    --
    -- Nothing cascades to the parent content: §10.2 makes an Act, an Activity and a
    -- photo three separate subjects, so a moderator who approves only the photo has
    -- approved only the photo. What finishes the parent is
    -- `private.publish_if_screened`, called by the worker once this photo is `ready`.
    update public.media set status = 'processing' where id = p_media_id;
    v_written := 'processing';
    perform pgmq.send('ops', jsonb_build_object(
      'kind', 'publish_photo',
      'media_id', p_media_id
    ));

  else
    -- **A hold takes a published photo out of the public bucket**, which this branch did not do.
    -- It was one bare status update, so a photo held *after* it was published kept its
    -- `public_path` and went on being served to anyone with the URL — and if its owner was then
    -- erased, `delete_account` gave that live public path a 180-day retention clock and
    -- `queue_media_deletion` saw the retention row and suppressed the deletion. Net: a publicly
    -- fetchable photo of a deleted account, pinned for 180 days by the record that was supposed to
    -- protect it. Found by the `seam-qa` agent on 13 October 2026 and reproduced end to end.
    --
    -- §8.1 settles it rather than leaving it to a decision: "**A held photo gets no published
    -- copy**, because §8 opens 'Nothing a person writes or uploads is public until it has been
    -- screened' and `media` is a public bucket." The comment further up this function asserted the
    -- consequence as though it were already true — "a held photo has no `public_path`" — and that
    -- belief is what made the missing work invisible to three rounds of review.
    --
    -- **Back to `uploads`, not to `quarantine`.** §11.6 attaches the quarantine move to removal and
    -- its 180-day clock; a hold is reviewable and reversible, and §8.1 puts a held photo's original
    -- in the private `uploads` bucket. Moving it there restores exactly the state a photo held at
    -- screening time is in, so §8.3's `held -> visible` republishes from `uploads` with nothing
    -- special about this case — and `quarantine` stays what §11.6 says it is, the bucket a takedown
    -- moves a file to.
    --
    -- Only when there is something to move: a photo held at screening has no `public_path`, so the
    -- loop runs zero times and this costs nothing on the common path.
    for v_path in
      select unnest(array_remove(array[m.public_path, m.thumb_path], null))
      from public.media m
      where m.id = p_media_id
    loop
      perform pgmq.send('ops', jsonb_build_object(
        'kind', 'unpublish_file',
        'media_id', p_media_id,
        'path', v_path
      ));
    end loop;

    update public.media m
    set status = 'held', public_path = null, thumb_path = null
    where m.id = p_media_id;

    -- The same reasoning the removal branch gives for its own copy of this: the moderation worker
    -- sets `profiles.avatar_path` to the `upload_path` it publishes under, so nulling
    -- `media.public_path` alone would leave a held avatar still rendering on the profile. Keyed by
    -- the owner join for the same reason — there is no index on `avatar_path`.
    update public.profiles p
    set avatar_path = null
    from public.media m
    where p.id = m.owner_id
      and p.avatar_path = m.upload_path
      and m.id = p_media_id;
  end if;

  -- §10: "Every staff action is a Postgres function that … writes the audit log in the
  -- same transaction", and §8.5 asks the system path for the same row with
  -- `actor = 'system'`.
  insert into public.admin_audit_log (
    actor, staff_id, action, subject_type, subject_id, reason, before, after
  ) values (
    p_actor, p_staff_id, 'set_content_status', v_subject, v_subject_id, p_reason,
    jsonb_build_object('status', v_before),
    jsonb_build_object('status', v_written)
  );

  return jsonb_build_object('status', v_written);
end;
$$;

-- The allowlist, so the job the branch above sends is handed to a worker rather than archived in
-- silence. A roll-forward of `claim_ops_jobs` on top of the one that bound the export claim to a
-- live row; everything else in it is unchanged.

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
      'delete_retained_files', 'delete_export_file',
      -- §8.1's held branch, added 13 October 2026: a photo held after it was published has to leave
      -- the public `media` bucket, and §5.4 keeps file moves out of SQL. The destination is
      -- `uploads` rather than `quarantine`, because §11.6 attaches quarantine to a removal and its
      -- 180-day clock while a hold is reviewable — see the held branch of `set_content_status` in
      -- this same migration for the whole argument.
      'unpublish_file'
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

revoke execute on function claim_ops_jobs(int)
  from public, anon, authenticated, service_role;
grant execute on function claim_ops_jobs(int) to service_role;
