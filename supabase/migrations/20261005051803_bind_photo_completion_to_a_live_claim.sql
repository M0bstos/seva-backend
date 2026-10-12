-- **A defect found in review, 5 October 2026: a screening completion could undo a
-- completed takedown.** `complete_photo_screening` read its `media` row with no lock and
-- then updated it with no status predicate, so under READ COMMITTED this interleaving was
-- available: the worker reads the row as `processing`; `set_content_status` locks it, sets
-- `removed`, nulls `public_path` and `profiles.avatar_path`, writes the snapshot and the
-- audit row, and commits; the worker's update then lands and puts the photo back to
-- `ready` with `public_path` restored — and for an avatar, `profiles.avatar_path` with it.
-- `private.preserved_content` and the audit row still record a finished removal while the
-- public bucket serves the file again, against §11.6's "must stop serving a removed file
-- immediately".
--
-- Two lines close it, and they are the two §17.1 already prescribes for this shape. The
-- claim read takes `for update`, so a completion racing a takedown waits and then
-- re-evaluates `status = 'processing'` against the committed row — finding nothing, which
-- the existing branch already answers by deleting the message and returning `NOT_FOUND`,
-- exactly as it would for work another worker had done. And the update repeats the
-- predicate that justified it, so the write cannot outlive the condition even if the lock
-- were ever removed — the rule §17.1 records for `create_act`'s photo lock and for
-- `queue_photo_screening`.
--
-- Rolled forward as a replacement (§13.3), carrying the whole original body with its
-- comments; **everything else is unchanged**, and the two changed lines are marked.
create or replace function complete_photo_screening(
  p_msg_id bigint,
  p_outcome media_status,
  p_labels jsonb,
  p_bytes int,
  p_width int,
  p_height int
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_message jsonb;
  v_id uuid;
  v_media public.media%rowtype;
begin
  -- §5.3 also holds `uploading` and `processing`, which are states rather than
  -- verdicts. A worker naming one would park the photo where §12.5's stuck-screening
  -- arm can never clear it, so it raises rather than being written.
  --
  -- `removed` joins them for the same reason and a stronger one: §11.6 puts it there by a
  -- staff decision, and a screening verdict is not a route back out of a takedown.
  if p_outcome not in ('ready', 'held', 'rejected') then
    raise exception 'complete_photo_screening takes ready, held or rejected';
  end if;

  -- Still invisible, which is what proves the completion is inside the 60 seconds
  -- §8.4 hid the job for. Past that another worker may have taken it.
  select q.message into v_message
  from pgmq.q_moderation q
  where q.msg_id = p_msg_id and q.vt > now();

  if not found then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;
  if v_message ->> 'kind' <> 'photo' then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'msg_id');
  end if;

  -- The id comes from the queue row, so a worker holding two jobs cannot publish one
  -- photo's bytes under the other's row. And `processing` is the only status a claim
  -- hands out, so anything else means the photo already has a verdict and this one is
  -- stale — the photo equivalent of the text digest, bought by `media` being
  -- immutable where text is not.
  --
  -- **Changed:** `for update`. Without it a takedown committing between this read and the
  -- update below was overwritten; with it, the completion waits and then re-reads the
  -- committed row, where `status = 'processing'` no longer holds.
  v_id := (v_message ->> 'id')::uuid;
  select * into v_media from public.media
  where id = v_id and status = 'processing'
  for update;
  if not found then
    perform pgmq.delete('moderation', p_msg_id);
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  -- **Changed:** the update repeats `status = 'processing'`, so it cannot outlive the
  -- condition that justified it.
  update public.media
  set status = p_outcome,
      -- §8.1's own path, not the worker's word for it. A `ready` photo always has a
      -- published copy, so there is no row pointing at nothing on a public bucket.
      public_path = case when p_outcome = 'ready' then v_media.upload_path
                    else public_path end,
      bytes = coalesce(p_bytes, bytes),
      width = coalesce(p_width, width),
      height = coalesce(p_height, height)
  where id = v_id and status = 'processing';

  if p_labels is not null then
    insert into public.media_labels (media_id, labels)
    values (v_id, p_labels)
    on conflict (media_id) do update set labels = excluded.labels;
  end if;

  if p_outcome = 'ready' then
    -- §8.1: "Avatars use the same path with `purpose = 'avatar'`. The moderation
    -- worker sets `profiles.avatar_path` once the photo passes; clients have no grant
    -- on that column (§9.2). Otherwise someone could point their avatar at an
    -- unscreened upload, or at another person's photo."
    if v_media.purpose = 'avatar' then
      update public.profiles
      set avatar_path = v_media.upload_path
      where id = v_media.owner_id;
    end if;
    perform private.publish_if_screened(v_media.act_id, v_media.activity_id);
  else
    -- §8.3: "pending → held | Any check flags", from `pending` or `visible` as the
    -- text completion does. A photo can only be attached while its Act is being
    -- created, so `visible` is unreachable here today; written the same way so the
    -- two halves of one rule cannot drift, which is how they drifted before.
    update public.acts
    set status = 'held'
    where id = v_media.act_id and status in ('pending', 'visible');
    update public.activities
    set status = 'held'
    where id = v_media.activity_id and status in ('pending', 'visible');
  end if;

  perform pgmq.delete('moderation', p_msg_id);
  return jsonb_build_object('status', p_outcome);
end;
$$;
