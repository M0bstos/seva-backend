-- §8.3's held → visible for a photo, finished. §17.1 recorded the gap this closes: "§8.3's
-- held → visible has no writer for `public_path`, and §5.4 says storage cannot be reached from
-- SQL — so `admin_set_content_status` has to queue an `ops` job on approval. Until it does,
-- approving a held photo makes its content visible with no photo behind it."
--
-- `set_content_status` queues that job and leaves the photo in `processing`; the worker copies
-- the file into the public `media` bucket; this is what turns it `ready`. The order matters and
-- is the same one §8.1 step 4 uses: the bytes are in place before any row says they are, so
-- §8.1's invariant holds — "a `ready` photo always has a published copy, so there is no row
-- pointing at nothing on a public bucket".
--
-- It calls `private.publish_if_screened` for the reason both completion functions do: either
-- half can be the last to arrive, and §8 is explicit that "an Act or Activity leaves `pending`
-- only when its text and every one of its photos have passed".
--
-- `security invoker`: §5.2 grants `service_role` `update (status, public_path, …)` on `media`
-- and `update (avatar_path, text_hidden)` on `profiles`, and §5.1 grants it pgmq.
create function complete_photo_publication(p_msg_id bigint) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_message jsonb;
  v_id uuid;
  v_media public.media%rowtype;
begin
  -- Still hidden, which is what proves the completion is inside the 60 seconds §8.4 hid the job
  -- for (§17.1: `msg_id` is a capability, not an integer).
  select q.message into v_message
  from pgmq.q_ops q
  where q.msg_id = p_msg_id and q.vt > now();
  if not found then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;
  if v_message ->> 'kind' <> 'publish_photo' then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'msg_id');
  end if;

  -- The id comes from the queue row, so a worker holding two jobs cannot publish one photo's
  -- bytes under the other's row. Locked and filtered on `processing` for the reason §17.1
  -- records for `complete_photo_screening`: a takedown committing beside this would otherwise
  -- be overwritten, putting a removed file back on a public bucket.
  v_id := (v_message ->> 'media_id')::uuid;
  select * into v_media from public.media
  where id = v_id and status = 'processing'
  for update;
  if not found then
    -- Staff removed it, or another worker got there first. Either way the job is done with.
    perform pgmq.delete('ops', p_msg_id);
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  update public.media
  -- §8.1's own path rather than the worker's word for it, which is what makes the invariant
  -- structural: "§8.1 publishes the copy under the same object path it had in `uploads`".
  set status = 'ready', public_path = v_media.upload_path
  where id = v_id and status = 'processing';

  -- §8.1: "Avatars use the same path with `purpose = 'avatar'`. The moderation worker sets
  -- `profiles.avatar_path` once the photo passes; clients have no grant on that column (§9.2)."
  -- A staff approval is the other way a photo passes, so it sets the same column the same way.
  if v_media.purpose = 'avatar' then
    update public.profiles
    set avatar_path = v_media.upload_path
    where id = v_media.owner_id;
  end if;

  perform private.publish_if_screened(v_media.act_id, v_media.activity_id);

  perform pgmq.delete('ops', p_msg_id);
  return jsonb_build_object('status', 'ready');
end;
$$;

revoke execute on function complete_photo_publication(bigint)
  from public, anon, authenticated, service_role;
grant execute on function complete_photo_publication(bigint) to service_role;
