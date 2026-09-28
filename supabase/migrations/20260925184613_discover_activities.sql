-- §7.3 GET /discover: nearby upcoming Activities, for anyone. One Postgres call per
-- request (§13.4), so the limiter runs here rather than ahead of it (§17.1).
--
-- No kill switch. §5.3's app_flag list has no switch over reading, and `read_only`
-- exists to stop user writes while something is being investigated (§12.6); refusing
-- to serve the public list would take the app offline rather than protect it.
--
-- No onboarding or suspension check either: §7.3 gives this route "Anyone", and both
-- of those gates belong to the write functions (§5.4, §17 O33).
--
-- §7.3's cache: the caller's point snaps to a roughly 1 km cell and the radius to one
-- of five rungs, and the query runs from the snapped point rather than the caller's
-- own, so every caller in a cell is answered by one entry. Blocked organisers are
-- filtered *after* the cache is read, so a shared entry never carries anyone content
-- from someone they blocked.
create function discover_activities(
  p_user_id uuid,
  p_lon double precision,
  p_lat double precision,
  p_radius_km int,
  p_category category,
  p_from date,
  p_to date,
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
  v_cell extensions.geography;
  v_radius_km int;
  v_limit int;
  v_cursor_starts_at timestamptz;
  v_cursor_id uuid;
  v_key text;
  v_payload jsonb;
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

  -- §7.1's cursor is opaque, so it arrives as the text this route handed out. It
  -- returns both halves or neither, and a cursor that does not decode is the caller's
  -- to fix rather than a retryable INTERNAL (§7.4).
  if p_cursor is not null then
    select c.cursor_at, c.cursor_id into v_cursor_starts_at, v_cursor_id
    from private.decode_cursor(p_cursor) c;
    if v_cursor_starts_at is null then
      return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'cursor');
    end if;
  end if;

  -- 0.01° is roughly 1.1 km, the cell §7.3 asks for. The rung is the nearest of the
  -- five, ties going to the wider one: §7.3 fixes the ladder but not the direction,
  -- and a tie that narrows would drop results the caller asked to see. An absent
  -- radius takes the middle rung, since §7.3 names a default for neither route.
  v_cell := extensions.st_snaptogrid(
    extensions.st_setsrid(extensions.st_makepoint(p_lon, p_lat), 4326), 0.01
  )::extensions.geography;
  select rung into v_radius_km
  from unnest(array[2, 5, 10, 25, 50]) as rung
  order by abs(rung - coalesce(p_radius_km, 10)), rung desc
  limit 1;

  -- §7.3 keys the cache on "cell, radius, category, date range and page". A page is
  -- the cursor and the limit together: two callers asking for 10 and 50 rows from the
  -- same cursor are not on the same page, and sharing one entry would serve one of
  -- them the wrong length.
  --
  -- The cursor goes in re-encoded rather than as it arrived, so two spellings of one
  -- page share one entry: `decode` skips whitespace, so a cursor with a space in it
  -- resolves to the same rows under a second key. Null stays null and coalesces to
  -- the empty component a first page has.
  v_key := concat_ws(
    ':', 'discover', extensions.st_astext(v_cell::extensions.geometry, 6), v_radius_km,
    coalesce(p_category::text, ''), coalesce(p_from::text, ''), coalesce(p_to::text, ''),
    coalesce(private.encode_cursor(v_cursor_starts_at, v_cursor_id), ''), v_limit
  );

  select payload into v_payload from private.discover_cache
  where cache_key = v_key and expires_at > now();

  if not found then
    with page as (
      select a.id, a.organiser_id, a.title, a.category, a.starts_at, a.ends_at,
             a.location, a.location_label, a.capacity, a.participant_count,
             a.campaign_id,
             round(extensions.st_distance(a.location, v_cell))::int as distance_m
      from public.activities a
      where a.status = 'visible'
        and a.cancelled_at is null
        and a.starts_at > now()
        and extensions.st_dwithin(a.location, v_cell, v_radius_km * 1000)
        and (p_category is null or a.category = p_category)
        and (p_from is null
             or a.starts_at >= (p_from::timestamp at time zone 'Asia/Kolkata'))
        and (p_to is null
             or a.starts_at < ((p_to + 1)::timestamp at time zone 'Asia/Kolkata'))
        and (v_cursor_starts_at is null
             or (a.starts_at, a.id) > (v_cursor_starts_at, v_cursor_id))
      -- Start time, owner decision of 28 September 2026 (§17 O34). §3.2 described
      -- Discover as "ranking by distance, start time and spots left" and gave no
      -- weights; distance is the radius filter, the places left are `capacity` less
      -- `participant_count` in every row, and the order is start time — which is the
      -- access path §5.5 indexes for this route. §3.2 now says so.
      order by a.starts_at, a.id
      limit v_limit
    ),
    listed as (
      select jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'organiser_id', p.organiser_id,
          'title', p.title,
          'category', p.category,
          'starts_at', p.starts_at,
          'ends_at', p.ends_at,
          -- §5.4 stores an Activity's meeting point exactly, "because it's a public
          -- event", and a list of nearby Activities is what a map is drawn from. The
          -- by-id route returns the same pair.
          'lon', extensions.st_x(p.location::extensions.geometry),
          'lat', extensions.st_y(p.location::extensions.geometry),
          'location_label', p.location_label,
          'capacity', p.capacity,
          'participant_count', p.participant_count,
          'campaign_id', p.campaign_id,
          'distance_m', p.distance_m
        ) order by p.starts_at, p.id
      ) as items, count(*) as taken
      from page p
    ),
    last_row as (
      select p.starts_at, p.id from page p order by p.starts_at desc, p.id desc limit 1
    )
    select jsonb_build_object(
      'activities', coalesce(l.items, '[]'::jsonb),
      -- A short page is the last one, so there is nothing to ask for next.
      'next_cursor', case when l.taken < v_limit
        then null else private.encode_cursor(r.starts_at, r.id) end
    ) into v_payload
    from listed l left join last_row r on true;

    -- §7.3: entries last 60 seconds. Two callers missing at once both compute and the
    -- second overwrites the first with the same answer, which is cheaper than holding
    -- a lock across the query.
    insert into private.discover_cache (cache_key, payload, expires_at)
    values (v_key, v_payload, now() + interval '60 seconds')
    on conflict (cache_key) do update
      set payload = excluded.payload, expires_at = excluded.expires_at;
  end if;

  -- §7.2: a block "takes effect on Feed and Discover at the next request". After the
  -- cache read, never before it, so one entry serves everyone (§7.3). The cursor is
  -- left alone: paging must advance by what was read, not by what survived.
  if p_user_id is not null then
    v_payload := jsonb_set(v_payload, '{activities}', (
      select coalesce(jsonb_agg(e order by ord), '[]'::jsonb)
      from jsonb_array_elements(v_payload->'activities') with ordinality as t (e, ord)
      where not exists (
        select 1 from public.blocks
        where blocker_id = p_user_id and blocked_id = (e->>'organiser_id')::uuid
      )
    ));
  end if;

  return v_payload;
end;
$$;

revoke execute on function discover_activities(
  uuid, double precision, double precision, int, public.category, date, date,
  text, int, text, int, int, int
) from public, anon, authenticated, service_role;
grant execute on function discover_activities(
  uuid, double precision, double precision, int, public.category, date, date,
  text, int, text, int, int, int
) to service_role;
