-- §7.3 PATCH /acts/:id: the author edits title and story, and the Act is re-screened.
-- One Postgres call per request (§13.4), so the kill switch and the limiter are here
-- rather than ahead of it (§17.1).
--
-- §7.1 requires an Idempotency-Key on every *create*; an edit is not one, and §7.1.1
-- scopes the stored key to the three tables that have one. So there is no replay path
-- here and the limiter runs for every call.
--
-- Only `read_only` applies: §5.3's app_flag list has no switch for editing, and
-- `create_acts` governs creation.
--
-- Re-screening sets `text_checked` false, queues a job through §8.2's trigger, and
-- returns a visible Act to `pending`. §8.3 gained that transition during the build:
-- without it an author could publish something benign, wait for `visible`, then edit
-- the text into anything and have it served to everyone until a worker caught up.
create function update_act(
  p_user_id uuid,
  p_act_id uuid,
  p_title text,
  p_story text,
  p_bucket text,
  p_per_minute int,
  p_per_hour int,
  p_per_day int
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_act public.acts%rowtype;
  v_limited jsonb;
begin
  if exists (select 1 from public.app_flags where key = 'read_only' and engaged) then
    return jsonb_build_object('error', 'FEATURE_DISABLED');
  end if;

  -- §5.4: having a profile row is the onboarding gate.
  if not exists (select 1 from public.profiles where id = p_user_id) then
    return jsonb_build_object('error', 'ONBOARDING_REQUIRED');
  end if;

  v_limited := private.check_rate_limit(
    p_bucket, p_user_id, p_per_minute, p_per_hour, p_per_day
  );
  if v_limited is not null then
    return v_limited;
  end if;

  -- §17 O33: this function runs as service_role and bypasses the status = 'active'
  -- policy that governs clients, so suspension is checked here or §10.2's suspension
  -- does nothing to writing. §7.4 covers it: "Not yours, or you are blocked".
  --
  -- Below the limiter, unlike onboarding and age. Those sit above it so a caller
  -- barred by a rule they cannot see is not billed for it (§17.1); a suspended
  -- account has already been judged abusive, and putting the check above would hand
  -- exactly that caller the unmetered path §12.2's D5 note refuses to everyone else.
  if exists (
    select 1 from public.profiles where id = p_user_id and status <> 'active'
  ) then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  select * into v_act from public.acts where id = p_act_id;

  -- §7.4 keeps the two apart: an Act the caller cannot see is missing as far as they
  -- are concerned, while one they can see but do not own is "Not yours".
  if not found or (v_act.author_id <> p_user_id and v_act.status <> 'visible') then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;
  if v_act.author_id <> p_user_id then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  -- §8.3: removed content is kept for its retention period (§11.6), not edited back
  -- into circulation.
  if v_act.status = 'removed' then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  -- §8.3 as amended: an edit to visible content returns it to `pending`. §8.2's rule
  -- is that nothing a person writes is public until it has been screened, and leaving
  -- an edited Act visible would serve the new text to everyone until a worker got to
  -- it. `published_at` is left alone: §5.2.1 records first publication, not this edit.
  begin
    update public.acts
    set title = coalesce(p_title, title),
        story = coalesce(p_story, story),
        text_checked = false,
        status = case when status = 'visible' then 'pending' else status end
    where id = p_act_id
    returning * into v_act;
  exception when check_violation then
    -- §5.2.1 bounds the title and story. A body that slips past the route's own
    -- validation would otherwise raise into a retryable INTERNAL (§7.4), and the
    -- DETAIL would carry it into the log against §9.8.
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'act');
  end;

  return jsonb_build_object(
    'act', jsonb_build_object(
      'id', v_act.id,
      'status', v_act.status,
      'title', v_act.title,
      'story', v_act.story,
      'category', v_act.category,
      'occurred_on', v_act.occurred_on,
      'activity_id', v_act.activity_id,
      'created_at', v_act.created_at,
      'published_at', v_act.published_at
    )
  );
end;
$$;

revoke execute on function update_act(uuid, uuid, text, text, text, int, int, int)
  from public, anon, authenticated, service_role;
grant execute on function update_act(uuid, uuid, text, text, text, int, int, int)
  to service_role;
