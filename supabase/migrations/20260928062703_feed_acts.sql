-- §7.3 GET /feed: "Recent visible Acts nearby", for a signed-in caller. One Postgres
-- call per request (§13.4), so the limiter runs here (§17.1).
--
-- §17 O30 sets the geometry of this route: the smallest radius is 5 km and the cache
-- cell is 5 km, because `O29` put every Act on a roughly 5 km grid and a finer radius
-- or cell would filter on precision the column no longer carries. Discover keeps
-- §7.3's 2 km rung and 1 km cell, since an Activity's meeting point is stored exactly.
--
-- No kill switch, onboarding gate or suspension check: §5.3 has no switch over
-- reading, and §7.3 gives this route "Signed in" rather than "Onboarded" — the profile
-- gate and §17 O33's suspension rule both belong to the write functions.
--
-- Unlike Discover, a row carries its photos and its claimed metrics. An Act *is* its
-- evidence — §7.4 refuses metrics with no photo at all (`EVIDENCE_REQUIRED`) — whereas
-- an entry in a list of upcoming events is a time and a place.
create function feed_acts(
  p_user_id uuid,
  p_lon double precision,
  p_lat double precision,
  p_radius_km int,
  p_category category,
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
  v_cursor_at timestamptz;
  v_cursor_id uuid;
  v_key text;
  v_payload jsonb;
begin
  -- §7.3 puts this route behind a session, and §12.2 keys its counter by user ID. A
  -- call with no user has nothing to bill and nothing to filter blocks against, so it
  -- is refused before the limiter rather than counted against an empty bucket. The
  -- route answers §7.4's UNAUTHENTICATED there too, from the token check.
  if p_user_id is null then
    return jsonb_build_object('error', 'UNAUTHENTICATED');
  end if;

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

  -- 0.05° is the grid the Acts themselves sit on, so the cell and the data agree
  -- (§17 O29, O30). The rungs start at 5 km for the same reason; ties go to the wider
  -- one, as in Discover. An absent radius takes the smallest, which is where §7.3 says
  -- Feed starts.
  v_cell := extensions.st_snaptogrid(
    extensions.st_setsrid(extensions.st_makepoint(p_lon, p_lat), 4326), 0.05
  )::extensions.geography;
  select rung into v_radius_km
  from unnest(array[5, 10, 25, 50]) as rung
  order by abs(rung - coalesce(p_radius_km, 5)), rung desc
  limit 1;

  -- §7.3's key, less the date range: Feed has no such filter, because "recent" is its
  -- order rather than a window the caller picks. The cell is rendered to six decimals
  -- rather than left to ST_AsText's default, which prints the snap's floating-point
  -- residue — 73.85 comes out as 73.85000000000001 — and would put that in the key.
  -- The cursor goes in re-encoded for the same reason: `decode` skips whitespace, so
  -- two spellings of one page would otherwise key two entries.
  v_key := concat_ws(
    ':', 'feed', extensions.st_astext(v_cell::extensions.geometry, 6), v_radius_km,
    coalesce(p_category::text, ''),
    coalesce(private.encode_cursor(v_cursor_at, v_cursor_id), ''), v_limit
  );

  select payload into v_payload from private.discover_cache
  where cache_key = v_key and expires_at > now();

  if not found then
    with page as (
      select a.id, a.author_id, a.title, a.story, a.category, a.occurred_on,
             a.activity_id, a.created_at, a.published_at,
             round(extensions.st_distance(a.location_coarse, v_cell))::int as distance_m
      from public.acts a
      where a.status = 'visible'
        and extensions.st_dwithin(a.location_coarse, v_cell, v_radius_km * 1000)
        and (p_category is null or a.category = p_category)
        and (v_cursor_at is null or (a.created_at, a.id) < (v_cursor_at, v_cursor_id))
      -- "Recent" reads on `created_at` and not `published_at`: §5.5 indexes the first,
      -- and §5.2.1 leaves the second null until an Act first becomes visible, which
      -- is the moderation worker's write (§8.3). The two are minutes apart.
      order by a.created_at desc, a.id desc
      limit v_limit
    ),
    listed as (
      select jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'author_id', p.author_id,
          'title', p.title,
          'story', p.story,
          'category', p.category,
          'occurred_on', p.occurred_on,
          'activity_id', p.activity_id,
          'created_at', p.created_at,
          'published_at', p.published_at,
          'distance_m', p.distance_m,
          -- §5.2: metrics are readable for a visible Act (§17 O19), and ready photos
          -- on visible content. Anything `held` or `rejected` stays out (§8.2).
          'metrics', coalesce((
            select jsonb_object_agg(am.metric, am.value)
            from public.act_metrics am where am.act_id = p.id
          ), '{}'::jsonb),
          'photos', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'public_path', m.public_path,
                'thumb_path', m.thumb_path,
                'width', m.width,
                'height', m.height
              ) order by m.position, m.created_at
            )
            from public.media m
            where m.act_id = p.id and m.status = 'ready'
          ), '[]'::jsonb)
        ) order by p.created_at desc, p.id desc
      ) as items, count(*) as taken
      from page p
    ),
    last_row as (
      select p.created_at, p.id from page p order by p.created_at, p.id limit 1
    )
    select jsonb_build_object(
      'acts', coalesce(l.items, '[]'::jsonb),
      'next_cursor', case when l.taken < v_limit
        then null else private.encode_cursor(r.created_at, r.id) end
    ) into v_payload
    from listed l left join last_row r on true;

    insert into private.discover_cache (cache_key, payload, expires_at)
    values (v_key, v_payload, now() + interval '60 seconds')
    on conflict (cache_key) do update
      set payload = excluded.payload, expires_at = excluded.expires_at;
  end if;

  -- §1.1 and §7.2: Feed is "recent visible Acts near a location, with blocked users
  -- removed", and the removal happens after the cache read so one entry serves
  -- everyone (§7.3). The `acts_select` policy carries the same rule for a Data API
  -- read; this call runs as service_role and bypasses it.
  v_payload := jsonb_set(v_payload, '{acts}', (
    select coalesce(jsonb_agg(e order by ord), '[]'::jsonb)
    from jsonb_array_elements(v_payload->'acts') with ordinality as t (e, ord)
    where not exists (
      select 1 from public.blocks
      where blocker_id = p_user_id and blocked_id = (e->>'author_id')::uuid
    )
  ));

  return v_payload;
end;
$$;

revoke execute on function feed_acts(
  uuid, double precision, double precision, int, public.category, text, int,
  text, int, int, int
) from public, anon, authenticated, service_role;
grant execute on function feed_acts(
  uuid, double precision, double precision, int, public.category, text, int,
  text, int, int, int
) to service_role;
