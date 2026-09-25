-- §7.3 POST /activities/:id/cancel: "Cancels and emails participants | Organiser |
-- 5/day". One Postgres call per request (§13.4), so the kill switch and the limiter
-- are here rather than ahead of it (§17.1).
--
-- The email is queued, not sent: §4 has the workers as the only code that calls AWS,
-- and §8.4 gives a queued job its retry budget. One job per participant still joined,
-- carrying only the two ids — the message worker reads the address from Auth, because
-- §5.4 keeps it out of the profile tables and §9.8 keeps it out of anything logged.
--
-- Only `read_only` is checked, and a suspended organiser may still cancel: §17 O33
-- stops a suspended person writing content, and leaving participants expecting an
-- event the organiser can no longer run punishes them instead. Cancelling is one-way
-- (§5.2.1 has no uncancel), so it is not a channel for repeated mail.
create function cancel_activity(
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
  v_limited jsonb;
  v_queued int;
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

  -- Locked for the same reason join locks: the participant list is about to be read
  -- and mailed, and a join arriving between the read and the write would be missed.
  select * into v_activity from public.activities where id = p_activity_id for update;
  if not found then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  -- §7.3 scopes this to the organiser. §5.2.1 lets organiser_id go null when an
  -- account is deleted (§5.4), and a null owner is nobody's to cancel.
  if v_activity.organiser_id is distinct from p_user_id then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  -- Already cancelled: nothing to do, and no second round of mail.
  if v_activity.cancelled_at is not null then
    return jsonb_build_object('cancelled_at', v_activity.cancelled_at, 'notified', 0);
  end if;

  update public.activities
  set cancelled_at = now()
  where id = p_activity_id
  returning * into v_activity;

  with notified as (
    select user_id from public.activity_participants
    where activity_id = p_activity_id and status = 'joined'
  ),
  sent as (
    select pgmq.send('email', jsonb_build_object(
      'kind', 'activity_cancelled',
      'activity_id', p_activity_id,
      'user_id', notified.user_id
    ))
    from notified
  )
  select count(*) into v_queued from sent;

  return jsonb_build_object(
    'cancelled_at', v_activity.cancelled_at,
    'notified', v_queued
  );
end;
$$;

revoke execute on function cancel_activity(uuid, uuid, text, int, int, int)
  from public, anon, authenticated, service_role;
grant execute on function cancel_activity(uuid, uuid, text, int, int, int)
  to service_role;
