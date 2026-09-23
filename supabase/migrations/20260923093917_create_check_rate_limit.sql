-- §12.2: the limit check is one upsert inside the same Postgres call as the action,
-- so a route's function calls this and never makes a round trip of its own. The caps
-- arrive as arguments because §12.2 makes `_shared/limits.ts` the only place a limit
-- is named. Swapping in a Redis-backed limiter moves the counting out of SQL and
-- drops these arguments from every route function, which §12.2's D5 note now says.
--
-- Returns null when the action may proceed, and otherwise the §7.4 code the route
-- returns as it stands. Three windows: §7.3 uses per-minute, per-hour and per-day
-- caps, the day being the Asia/Kolkata calendar day of §5.1. A cap left null is a
-- window this route does not use.
--
-- Rejected requests still count, which is what §12.2 accepts when it says each one
-- costs a cheap indexed write.
create function private.check_rate_limit(
  p_bucket text,
  p_user_id uuid,
  p_per_minute int default null,
  p_per_hour int default null,
  p_per_day int default null
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_young boolean;
  v_exceeded record;
begin
  -- §7.3 halves every limit for an account less than 72 hours old. §6.3 pins the
  -- source to auth.users.created_at, which §17's O16 grants as two columns.
  select u.created_at > now() - interval '72 hours' into v_young
  from auth.users u where u.id = p_user_id;
  v_young := coalesce(v_young, false);

  with windows as (
    select *
    from (values
      ('minute', date_trunc('minute', now()), interval '1 minute', p_per_minute),
      ('hour', date_trunc('hour', now()), interval '1 hour', p_per_hour),
      ('day',
       date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata',
       interval '1 day', p_per_day)
    ) as w (kind, window_start, length, cap)
    where w.cap is not null
  ),
  capped as (
    -- §7.3 fixes the halving but not its rounding. Rounding up keeps a cap of 1 at 1
    -- rather than 0, so no cap can lock a new account out of a route altogether.
    select w.kind, w.window_start, w.length,
           case when v_young then ceil(w.cap / 2.0)::int else w.cap end as cap
    from windows w
  ),
  bumped as (
    insert into private.rate_limit_hits as h (bucket, window_start, hits)
    select p_bucket || ':' || c.kind, c.window_start, 1 from capped c
    on conflict (bucket, window_start) do update set hits = h.hits + 1
    returning h.bucket, h.hits
  )
  -- Reported longest window first: a caller over both the minute and the day cap has
  -- to come back tomorrow either way, and naming the minute would send them back in
  -- sixty seconds to be refused again.
  select c.kind, c.window_start, c.length into v_exceeded
  from bumped b
  join capped c on b.bucket = p_bucket || ':' || c.kind
  where b.hits > c.cap
  order by case c.kind when 'day' then 1 when 'hour' then 2 else 3 end
  limit 1;

  if v_exceeded.kind is null then
    return null;
  end if;

  return jsonb_build_object(
    'error',
    case when v_exceeded.kind = 'day' then 'DAILY_LIMIT_REACHED' else 'RATE_LIMITED' end,
    'retry_after',
    ceil(extract(epoch from (v_exceeded.window_start + v_exceeded.length - now())))::int
  );
end;
$$;

-- §9.1: revoking from the two roles alone leaves what PUBLIC granted, and revoking
-- from PUBLIC also strips service_role, so the grant back is required.
revoke execute on function private.check_rate_limit(text, uuid, int, int, int)
  from public, anon, authenticated, service_role;
grant execute on function private.check_rate_limit(text, uuid, int, int, int)
  to service_role;
