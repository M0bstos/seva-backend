-- §7.3 POST /activities/:id/join: "Joins under a capacity lock. Joining twice returns
-- the existing row." One Postgres call per request (§13.4), so the kill switch and
-- the limiter are here rather than ahead of it (§17.1).
--
-- The lock is `for update` on the Activity row, taken before the count is read and
-- held to commit, so two callers racing for the last place are serialised and the
-- second sees the first's count. §5.2.1's `participant_count <= capacity` check is
-- the backstop, not the control: reaching it would mean answering a caller with an
-- INTERNAL where §7.4 has `ACTIVITY_FULL`.
--
-- Joining twice writes nothing, but is still counted: §7.1.1's unbilled replay is for
-- a create carrying an Idempotency-Key, and §7.1 requires one only on a create. A
-- repeat join is an ordinary request against §7.3's 30/h.
--
-- No age bar here. §9.6 stops a minor organising, not taking part.
create function join_activity(
  p_user_id uuid,
  p_activity_id uuid,
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
  v_activity public.activities%rowtype;
  v_participant public.activity_participants%rowtype;
  v_limited jsonb;
begin
  if exists (
    select 1 from public.app_flags where key in ('joins', 'read_only') and engaged
  ) then
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

  -- The capacity lock. Everything after this reads a count nobody else can move.
  select * into v_activity from public.activities where id = p_activity_id for update;
  if not found then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  -- §7.4: "Started, cancelled, or not yet visible".
  if v_activity.status <> 'visible'
     or v_activity.cancelled_at is not null
     or v_activity.starts_at <= now()
  then
    return jsonb_build_object('error', 'ACTIVITY_NOT_JOINABLE');
  end if;

  select * into v_participant from public.activity_participants
  where activity_id = p_activity_id and user_id = p_user_id;

  -- §7.3: "Joining twice returns the existing row."
  if found and v_participant.status = 'joined' then
    return jsonb_build_object(
      'joined_at', v_participant.joined_at,
      'participant_count', v_activity.participant_count,
      'already_joined', true
    );
  end if;

  if v_activity.participant_count >= v_activity.capacity then
    return jsonb_build_object('error', 'ACTIVITY_FULL');
  end if;

  if found then
    -- Rejoining after leaving. §5.2.1 ties left_at to the status, so it clears here.
    update public.activity_participants
    set status = 'joined', left_at = null
    where activity_id = p_activity_id and user_id = p_user_id
    returning * into v_participant;
  else
    insert into public.activity_participants (activity_id, user_id)
    values (p_activity_id, p_user_id)
    returning * into v_participant;
  end if;

  return jsonb_build_object(
    'joined_at', v_participant.joined_at,
    -- The trigger moved the count inside this transaction (§5.4), so read it back
    -- rather than adding one to the value taken before the write.
    'participant_count', (
      select participant_count from public.activities where id = p_activity_id
    ),
    'already_joined', false
  );
end;
$$;

revoke execute on function join_activity(uuid, uuid, text, int, int, int)
  from public, anon, authenticated, service_role;
grant execute on function join_activity(uuid, uuid, text, int, int, int)
  to service_role;
