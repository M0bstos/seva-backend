-- §9.3 gives the Send SMS hook three jobs in order — signature, number, cap — and
-- this is the third. §12.5 puts the count in Postgres, and §12.2's counter is where
-- it goes; the bucket, the unlogged table and the returned count are decisions §17.1
-- records, so they are not restated here.
--
-- In `public` because §9.4 exposes only that schema to the Data API. The count comes
-- back with the permission because nothing else can read it and §12.5 alarms at 80%
-- of the cap. `p_user_id` is null from the hook: `_shared/limits.ts` builds all five
-- arguments together, and a null is what keeps §7.3's 72-hour halving off a
-- project-wide budget.
create function count_sms_send(
  p_bucket text,
  p_user_id uuid,
  p_per_minute int,
  p_per_hour int,
  p_per_day int
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_limited jsonb;
  v_sent int;
begin
  -- This is the first function that reads a counter back out and hands it to its
  -- caller, and any secret key can call it (§9.5). Pinned to the one bucket §12.2
  -- defines for it, not to the route: a wrong route would make it a reader of another
  -- route's per-day count for a user id, and a wrong *subject* under this route is the
  -- thing §12.2 spends a sentence forbidding — a phone number in `bucket` is the copy
  -- outside Supabase Auth that §5.4 allows nowhere but `retained_registrations`. The
  -- signature could not enforce that; this is where it is enforced instead. A null
  -- daily cap writes no day window, which would report `null` rather than a count and
  -- leave §12.5's alarm quietly blind.
  if p_bucket <> 'sms.send:all' or p_per_day is null then
    raise exception 'count_sms_send takes the sms.send:all bucket and a daily cap';
  end if;

  v_limited := private.check_rate_limit(
    p_bucket, p_user_id, p_per_minute, p_per_hour, p_per_day
  );
  if v_limited is not null then
    return v_limited;
  end if;

  -- The newest day window for this bucket is today's, because the call above has just
  -- upserted it. Read by order rather than by recomputing §5.1's Asia/Kolkata day
  -- start, so the day has one definition and it stays in the limiter.
  select hits into v_sent
  from private.rate_limit_hits
  where bucket = p_bucket || ':day'
  order by window_start desc
  limit 1;

  return jsonb_build_object('sent_today', v_sent);
end;
$$;

revoke execute on function count_sms_send(text, uuid, int, int, int)
  from public, anon, authenticated, service_role;
grant execute on function count_sms_send(text, uuid, int, int, int) to service_role;
