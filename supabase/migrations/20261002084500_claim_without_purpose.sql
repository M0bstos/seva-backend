-- `claim_moderation_jobs` handed the worker a photo's `purpose` and nothing read it:
-- §8.1's avatar rule is `complete_photo_screening`'s, which reads `purpose` off the
-- `media` row in the same frame that derives `profiles.avatar_path` from it. Declared
-- surface with no use, which CLAUDE.md's "write the least code that does the job"
-- rules out. Rolled forward rather than edited (§13.3); nothing else changes.
create or replace function claim_moderation_jobs(p_count int) returns jsonb
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
  if p_count is null or p_count < 1 or p_count > 100 then
    raise exception 'claim_moderation_jobs takes a count between 1 and 100';
  end if;

  for v_msg in
    select msg_id, read_ct, message from pgmq.read('moderation', 60, p_count)
  loop
    v_kind := v_msg.message ->> 'kind';

    if v_msg.read_ct > 5 then
      perform pgmq.archive('moderation', v_msg.msg_id);
      continue;
    end if;

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
      select jsonb_build_object(
               'texts', jsonb_build_array(p.display_name, p.bio),
               'digest', private.text_digest(v_kind, v_id))
      into v_job
      from public.profiles p
      where p.id = v_id;
    else
      -- The object the worker reads in §8.1 step 1, and nothing else: `purpose` stays
      -- on the row, where the completion reads it.
      select jsonb_build_object('upload_path', m.upload_path)
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
