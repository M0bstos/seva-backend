-- §7.3 GET /discover/activities/:id: "One Activity, for shared links", for anyone.
-- One Postgres call per request (§13.4), so the limiter runs here (§17.1).
--
-- No cache. §7.3 keys the Discover cache on "cell, radius, category, date range and
-- page", none of which a lookup by primary key has; the read is one indexed row and
-- an entry per shared Activity would be a key space nothing bounds.
--
-- §5.4 stores an Activity's meeting point exactly, "because it's a public event", so
-- this is the one route that returns coordinates. §9.8 keeps them out of logs, not out
-- of answers, and a shared link with no map is not a shared link.
--
-- No organiser name or avatar. §9.1 gives `anon` no grant on `profiles` at all, and
-- serving profile columns through this route would reopen that as a second read path;
-- a signed-in client reads them over the Data API, where §8.2's `text_hidden` rule is
-- visible to it. The organiser's id is returned because it is the key the client needs
-- to make that request, and because the block filter below has to have it.
create function discover_activity(
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
  v_limited jsonb;
  v_activity public.activities%rowtype;
begin
  v_limited := private.check_rate_limit(
    p_bucket, p_user_id, p_per_minute, p_per_hour, p_per_day
  );
  if v_limited is not null then
    return v_limited;
  end if;

  -- §5.2 gives signed-in readers "visible and own"; this route serves logged-out
  -- callers too, so it offers visible only. An organiser reads their own pending
  -- Activity over the Data API, where that policy already applies.
  select * into v_activity from public.activities
  where id = p_activity_id and status = 'visible';
  if not found then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  -- §7.2: a block "takes effect on Feed and Discover at the next request". §7.4 folds
  -- "missing" and "not visible to you" into NOT_FOUND, which is what a blocked
  -- organiser's Activity is — FORBIDDEN is for the caller being the blocked one.
  if p_user_id is not null and exists (
    select 1 from public.blocks
    where blocker_id = p_user_id and blocked_id = v_activity.organiser_id
  ) then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  -- A cancelled Activity is returned rather than hidden: the link is already in
  -- somebody's hands, and `cancelled_at` is what lets the app say so instead of
  -- showing the event as if it were still on. §5.2.1 has no uncancel.
  return jsonb_build_object(
    'activity', jsonb_build_object(
      'id', v_activity.id,
      'organiser_id', v_activity.organiser_id,
      'title', v_activity.title,
      'description', v_activity.description,
      'category', v_activity.category,
      'starts_at', v_activity.starts_at,
      'ends_at', v_activity.ends_at,
      'lon', extensions.st_x(v_activity.location::extensions.geometry),
      'lat', extensions.st_y(v_activity.location::extensions.geometry),
      'location_label', v_activity.location_label,
      'capacity', v_activity.capacity,
      'participant_count', v_activity.participant_count,
      'what_to_bring', v_activity.what_to_bring,
      'campaign_id', v_activity.campaign_id,
      'cancelled_at', v_activity.cancelled_at,
      'created_at', v_activity.created_at,
      -- §5.2: ready photos on visible content. `held` and `rejected` ones are left
      -- out here for the same reason the Act text is: nothing unscreened is public
      -- (§8.2). §9.6 keeps participants out of every answer, so none is listed.
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
        where m.activity_id = v_activity.id and m.status = 'ready'
      ), '[]'::jsonb)
    )
  );
end;
$$;

revoke execute on function discover_activity(uuid, uuid, text, int, int, int)
  from public, anon, authenticated, service_role;
grant execute on function discover_activity(uuid, uuid, text, int, int, int)
  to service_role;
