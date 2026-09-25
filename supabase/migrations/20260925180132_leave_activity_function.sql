-- §7.3 POST /activities/:id/leave: "Frees the place", and shares the join limit, so
-- the Edge Function passes the join bucket rather than one of its own.
--
-- Two departures from the other write functions, both because leaving withdraws
-- rather than adds:
--
-- Only `read_only` is checked. §5.3's `joins` switch exists to stop people joining
-- (§12.6 turns switches off when something is spreading); leaving is the way out, and
-- disabling it would strand people in an Activity the operator is trying to empty.
--
-- A suspended account may leave. §17 O33 stops a suspended person writing content;
-- holding a place they cannot give up penalises the organiser instead of them.
--
-- Leaving twice is not an error. §7.3 describes the outcome, a freed place, and the
-- second call has nothing left to free.
create function leave_activity(
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
  v_participant public.activity_participants%rowtype;
  v_limited jsonb;
begin
  if exists (select 1 from public.app_flags where key = 'read_only' and engaged) then
    return jsonb_build_object('error', 'FEATURE_DISABLED');
  end if;

  if not exists (select 1 from public.profiles where id = p_user_id) then
    return jsonb_build_object('error', 'ONBOARDING_REQUIRED');
  end if;

  v_limited := private.check_rate_limit(
    p_bucket, p_user_id, p_per_minute, p_per_hour, p_per_day
  );
  if v_limited is not null then
    return v_limited;
  end if;

  if not exists (select 1 from public.activities where id = p_activity_id) then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  select * into v_participant from public.activity_participants
  where activity_id = p_activity_id and user_id = p_user_id;

  if not found then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  if v_participant.status = 'joined' then
    -- §5.2.1 ties left_at to the status, so the two move together.
    update public.activity_participants
    set status = 'left', left_at = now()
    where activity_id = p_activity_id and user_id = p_user_id;
  end if;

  return jsonb_build_object(
    'left', true,
    -- Read the count back: the trigger moved it inside this transaction (§5.4).
    'participant_count', (
      select participant_count from public.activities where id = p_activity_id
    )
  );
end;
$$;

revoke execute on function leave_activity(uuid, uuid, text, int, int, int)
  from public, anon, authenticated, service_role;
grant execute on function leave_activity(uuid, uuid, text, int, int, int)
  to service_role;
