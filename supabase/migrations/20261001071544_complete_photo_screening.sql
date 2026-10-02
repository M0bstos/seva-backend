-- §8.1 step 4: "The worker runs the four steps in the figure, writes both files to the
-- public `media` bucket, sets the photo to `ready` or `held`, and deletes the original
-- upload." This is the database half of that step. The files and the deletion are the
-- worker's, because §5.4 is clear that "storage files cannot be deleted with SQL".
--
-- Three outcomes rather than two, because §8.1's four steps include one that is not a
-- moderation judgement: step 1 checks "JPEG signature · ≤ 5 MB", and §5.3 reserves
-- `rejected` for a file that fails it. §8.3's "pending → held | Any check flags"
-- covers all three the same way — a parent whose photo did not pass goes to `held`
-- for a person to look at, whether the photo was flagged or malformed.
--
-- The verdict's own detail goes to `media_labels` and not to `media` (`O21`), for both
-- a passed and a held photo: §8.4 tunes the threshold "on real uploads during the
-- closed beta", which needs the near-misses as much as the hits.
--
-- §8.1 publishes the copy "under the same object path it had in `uploads`", so the
-- published path is **derived** rather than taken as an argument. §8.1's own reason
-- for keeping clients off `profiles.avatar_path` is that "someone could point their
-- avatar at an unscreened upload, or at another person's photo", and an argument
-- nothing checks against `upload_path` left that enforced nowhere in SQL.
--
-- `security invoker`: `service_role` holds `update (status, public_path, bytes, width,
-- height, ...)` on `media`, `update (avatar_path, text_hidden)` on `profiles`, and
-- `insert, update` on `media_labels`.
create function complete_photo_screening(
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
  v_id := (v_message ->> 'id')::uuid;
  select * into v_media from public.media where id = v_id and status = 'processing';
  if not found then
    perform pgmq.delete('moderation', p_msg_id);
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  update public.media
  set status = p_outcome,
      -- §8.1's own path, not the worker's word for it. A `ready` photo always has a
      -- published copy, so there is no row pointing at nothing on a public bucket.
      public_path = case when p_outcome = 'ready' then v_media.upload_path
                    else public_path end,
      bytes = coalesce(p_bytes, bytes),
      width = coalesce(p_width, width),
      height = coalesce(p_height, height)
  where id = v_id;

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

revoke execute on function complete_photo_screening(
  bigint, media_status, jsonb, int, int, int
) from public, anon, authenticated, service_role;
grant execute on function complete_photo_screening(
  bigint, media_status, jsonb, int, int, int
) to service_role;
