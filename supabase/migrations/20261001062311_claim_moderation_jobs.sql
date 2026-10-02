-- §8's worker side, step one. The worker calls this once per run and gets a batch of
-- jobs with the content already attached, rather than a batch of ids and then one
-- round trip per job.
--
-- §8.4 fixes the queue behaviour this implements: "Queue jobs are hidden for 60
-- seconds while processing and retried up to 5 times. After that they are archived
-- and an alarm fires; nothing is silently dropped." The alarm is `/discover/health`,
-- which counts rows in `pgmq.a_*`.
--
-- `security invoker`: the worker calls it on its own secret key, and §5.1's queue
-- grants give `service_role` `execute` on pgmq's functions plus the relation grants
-- its invoker functions need. Reading the content needs only `select`, which
-- `service_role` holds on all four tables.
--
-- Returns a jsonb array. Each entry carries `msg_id` and the `kind` the worker
-- branches on; a text job carries the strings §8.2 screens, and a photo job carries
-- the object path §8.1 step 1 wrote. Nothing else: the worker has no use for a row.
create function claim_moderation_jobs(p_count int) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_msg record;
  v_kind text;
  v_id uuid;
  v_job jsonb;
  v_jobs jsonb := '[]'::jsonb;
begin
  -- §8.4 keeps the worker's concurrency below Rekognition's 5 a second, so a batch is
  -- small by design. Bounded here as well, because an unbounded count would hide the
  -- whole queue for 60 seconds on one call.
  if p_count is null or p_count < 1 or p_count > 100 then
    raise exception 'claim_moderation_jobs takes a count between 1 and 100';
  end if;

  for v_msg in
    select msg_id, read_ct, message from pgmq.read('moderation', 60, p_count)
  loop
    v_kind := v_msg.message ->> 'kind';

    -- §8.4's fifth retry is the last. Archived rather than deleted, so §12.5's alarm
    -- has something to find and nothing is dropped in silence. **Before the cast
    -- below**, which is the order that matters: measured, a message whose `id` is not
    -- a uuid raised out of the whole batch, rolling back `pgmq.read`'s own visibility
    -- update, so that one message was re-read for ever and could never reach the
    -- archive — §8.4's "nothing is silently dropped" inverted into nothing moving.
    if v_msg.read_ct > 5 then
      perform pgmq.archive('moderation', v_msg.msg_id);
      continue;
    end if;

    -- A message no version of this function wrote. Archived rather than deleted, for
    -- the same reason as an exhausted job.
    if v_kind is null or v_kind not in
      ('act_text', 'activity_text', 'profile_text', 'photo')
    then
      perform pgmq.archive('moderation', v_msg.msg_id);
      continue;
    end if;

    begin
      v_id := (v_msg.message ->> 'id')::uuid;
    exception when invalid_text_representation or null_value_not_allowed then
      perform pgmq.archive('moderation', v_msg.msg_id);
      continue;
    end;

    -- §8.2 screens four kinds of text and §8.1 one kind of file. A job whose content
    -- has since been deleted, or removed by staff, has nothing left to screen: it is
    -- dropped here rather than spending a Rekognition or Guardrails call on it
    -- (§8.4's quotas), and `null` below is what says so.
    -- Each text job carries a digest of the text being handed out, and the completion
    -- refuses a verdict whose digest no longer matches the live row. Without it a
    -- verdict in flight lands on text edited since — reproduced, and it published
    -- unscreened text and made the later flag inert (see `private.text_digest`).
    if v_kind = 'act_text' then
      select jsonb_build_object(
               'texts', jsonb_build_array(a.title, a.story),
               'digest', private.text_digest(v_kind, v_id))
      into v_job
      from public.acts a
      where a.id = v_id and a.status <> 'removed';
    elsif v_kind = 'activity_text' then
      select jsonb_build_object(
               'texts', jsonb_build_array(
                 c.title, c.description, c.location_label, c.what_to_bring),
               'digest', private.text_digest(v_kind, v_id))
      into v_job
      from public.activities c
      where c.id = v_id and c.status <> 'removed';
    elsif v_kind = 'profile_text' then
      -- §8.2: "Profiles are visible straight away", so there is no status to check.
      select jsonb_build_object(
               'texts', jsonb_build_array(p.display_name, p.bio),
               'digest', private.text_digest(v_kind, v_id))
      into v_job
      from public.profiles p
      where p.id = v_id;
    else
      select jsonb_build_object('upload_path', m.upload_path, 'purpose', m.purpose)
      into v_job
      from public.media m
      where m.id = v_id and m.status = 'processing';
    end if;

    if v_job is null then
      perform pgmq.delete('moderation', v_msg.msg_id);
      continue;
    end if;

    v_jobs := v_jobs || jsonb_build_array(
      jsonb_build_object('msg_id', v_msg.msg_id, 'kind', v_kind) || v_job
    );
  end loop;

  return v_jobs;
end;
$$;

revoke execute on function claim_moderation_jobs(int)
  from public, anon, authenticated, service_role;
grant execute on function claim_moderation_jobs(int) to service_role;
