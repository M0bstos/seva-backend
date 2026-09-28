-- §7.3 GET /discover/campaigns: "Active campaigns with progress", for anyone. One
-- Postgres call per request (§13.4), so the limiter runs here (§17.1).
--
-- §17 O17: this route filters `status = 'active'` itself. `discover` runs on a secret
-- key and `service_role` bypasses RLS, so the `campaigns_select` policy that carries
-- the same rule for signed-in readers does not apply to this call.
--
-- No cache. §7.3's cache key is "cell, radius, category, date range and page", and a
-- campaign list has no cell, radius or category; §5.2 has staff create campaigns by
-- hand, so this is a short list read straight off the primary key.
--
-- Ordered newest first. §7.2 asks for "active campaigns with progress" and neither it
-- nor §5.2 gives an order, so this takes the conventional one rather than inventing a
-- rank; the cursor then pairs a timestamp with the primary key like every other list
-- route (§7.1).
create function discover_campaigns(
  p_user_id uuid,
  p_cursor text,
  p_limit int,
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
  v_limited jsonb;
  v_limit int;
  v_cursor_at timestamptz;
  v_cursor_id uuid;
begin
  v_limited := private.check_rate_limit(
    p_bucket, p_user_id, p_per_minute, p_per_hour, p_per_day
  );
  if v_limited is not null then
    return v_limited;
  end if;

  -- §7.1 caps a function page at 50. This clamps rather than refusing: the route
  -- validates what the caller typed and names the field (§7.4), and a second error
  -- path here would be the same rule in two places. What the clamp is for is the
  -- query below, where a null limit would put no bound on the scan at all.
  v_limit := least(greatest(coalesce(p_limit, 20), 1), 50);

  if p_cursor is not null then
    select c.cursor_at, c.cursor_id into v_cursor_at, v_cursor_id
    from private.decode_cursor(p_cursor) c;
    if v_cursor_at is null then
      return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'cursor');
    end if;
  end if;

  return (
    with page as (
      select c.id, c.title, c.description, c.goal_metric, c.goal_value,
             c.progress_value, c.starts_on, c.ends_on, c.created_at
      from public.campaigns c
      where c.status = 'active'
        and (v_cursor_at is null or (c.created_at, c.id) < (v_cursor_at, v_cursor_id))
      order by c.created_at desc, c.id desc
      limit v_limit
    ),
    listed as (
      select jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'title', p.title,
          'description', p.description,
          'goal_metric', p.goal_metric,
          'goal_value', p.goal_value,
          'progress_value', p.progress_value,
          'starts_on', p.starts_on,
          'ends_on', p.ends_on
        ) order by p.created_at desc, p.id desc
      ) as items, count(*) as taken
      from page p
    ),
    last_row as (
      select p.created_at, p.id from page p order by p.created_at, p.id limit 1
    )
    select jsonb_build_object(
      'campaigns', coalesce(l.items, '[]'::jsonb),
      'next_cursor', case when l.taken < v_limit
        then null else private.encode_cursor(r.created_at, r.id) end
    )
    from listed l left join last_row r on true
  );
end;
$$;

revoke execute on function discover_campaigns(uuid, text, int, text, int, int, int)
  from public, anon, authenticated, service_role;
grant execute on function discover_campaigns(uuid, text, int, text, int, int, int)
  to service_role;
