-- §7.3 POST /activities: creates an Activity, status pending, for an onboarded adult.
-- One Postgres call per request (§13.4), so the kill switch and the limiter are here
-- rather than ahead of it (§17.1).
--
-- Order as §17.1 fixes it: the kill switch, onboarding and age — all categorical —
-- then a replay, then the limiter, then suspension, then the content. Age comes
-- before the count because §9.6 bars an under-18 from organising outright, and
-- billing a cap for a request that could never succeed is the case §17.1 names;
-- suspension comes after it for the opposite reason, given below.
--
-- §5.4 stores the meeting point exactly, unlike an Act's: it is a public event, so no
-- trigger coarsens `activities.location`.
create function create_activity(
  p_user_id uuid,
  p_title text,
  p_description text,
  p_category category,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_lon double precision,
  p_lat double precision,
  p_location_label text,
  p_capacity int,
  p_what_to_bring text,
  p_campaign_id uuid,
  p_photo_ids uuid[],
  p_idempotency_key uuid,
  p_request_hash text,
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
  v_exists boolean;
  v_replayed boolean;
  v_limited jsonb;
  v_photos int := coalesce(array_length(p_photo_ids, 1), 0);
  v_dob date;
begin
  if exists (
    select 1 from public.app_flags
    where key in ('create_activities', 'read_only') and engaged
  ) then
    return jsonb_build_object('error', 'FEATURE_DISABLED');
  end if;

  -- §5.4: having a profile row is the onboarding gate.
  if not exists (select 1 from public.profiles where id = p_user_id) then
    return jsonb_build_object('error', 'ONBOARDING_REQUIRED');
  end if;

  -- §9.6: "Can't create Activities (AGE_RESTRICTED). Every organiser is an adult",
  -- and age is calculated from the date of birth on every request, on the IST day
  -- §5.1 uses for anything day-based.
  select date_of_birth into v_dob
  from public.profile_private where user_id = p_user_id;
  if v_dob is null
     or v_dob > ((now() at time zone 'Asia/Kolkata')::date - interval '18 years')::date
  then
    return jsonb_build_object('error', 'AGE_RESTRICTED');
  end if;

  -- §7.1.1, and §5.2.1's unique (organiser_id, idempotency_key).
  select * into v_activity from public.activities
  where organiser_id = p_user_id and idempotency_key = p_idempotency_key;
  v_exists := found;
  v_replayed := v_exists and v_activity.request_hash is not distinct from p_request_hash;

  if not v_replayed then
    v_limited := private.check_rate_limit(
      p_bucket, p_user_id, p_per_minute, p_per_hour, p_per_day
    );
    if v_limited is not null then
      return v_limited;
    end if;
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

  if v_exists then
    if not v_replayed then
      return jsonb_build_object('error', 'IDEMPOTENCY_KEY_REUSED');
    end if;
  else
    -- §17 O17: `campaign_id` is a restrict foreign key and the key does not check
    -- status, so an Activity may only be attached to a campaign that is active.
    if p_campaign_id is not null and not exists (
      select 1 from public.campaigns where id = p_campaign_id and status = 'active'
    ) then
      return jsonb_build_object('error', 'NOT_FOUND');
    end if;

    -- §8.1: up to ten photos, each owned by the caller, each still unattached.
    if v_photos > 10 then
      return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'photo_ids');
    end if;
    -- `for update` makes this a lock and not just a look: without it two Activities
    -- naming one photo both pass here and the second wins the write.
    if v_photos > 0 and v_photos <> (
      select count(*) from (
        select 1 from public.media
        where id = any(p_photo_ids)
          and owner_id = p_user_id
          and purpose = 'activity'
          and activity_id is null
          and status in ('processing', 'ready')
        for update
      ) locked
    ) then
      return jsonb_build_object('error', 'FORBIDDEN');
    end if;

    begin
      insert into public.activities (
        organiser_id, title, description, category, starts_at, ends_at,
        location, location_label, capacity, what_to_bring, campaign_id,
        idempotency_key, request_hash
      ) values (
        p_user_id, p_title, p_description, p_category, p_starts_at, p_ends_at,
        extensions.st_setsrid(extensions.st_makepoint(p_lon, p_lat), 4326)::extensions.geography,
        p_location_label, p_capacity, p_what_to_bring, p_campaign_id,
        p_idempotency_key, p_request_hash
      )
      returning * into v_activity;
    exception
      when unique_violation then
        -- §7.1.1: the second of two concurrent duplicates waited on the index here
        -- rather than at the lookup, so it takes that path now.
        select * into v_activity from public.activities
        where organiser_id = p_user_id and idempotency_key = p_idempotency_key;
        if v_activity.request_hash is distinct from p_request_hash then
          return jsonb_build_object('error', 'IDEMPOTENCY_KEY_REUSED');
        end if;
        v_replayed := true;
      when check_violation then
        -- §5.2.1 bounds the title, description, times and capacity. A body that slips
        -- past the route's own validation would otherwise raise into a retryable
        -- INTERNAL (§7.4), so a permanently malformed request would retry for ever.
        return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'activity');
    end;

    if not v_replayed then
      update public.media m
      set activity_id = v_activity.id, position = (p.ord - 1)::smallint
      from unnest(p_photo_ids) with ordinality as p (photo_id, ord)
      where m.id = p.photo_id
        and m.owner_id = p_user_id
        and m.purpose = 'activity'
        and m.activity_id is null
        and m.status in ('processing', 'ready');
    end if;
  end if;

  return jsonb_build_object(
    'replayed', v_replayed,
    'activity', jsonb_build_object(
      'id', v_activity.id,
      'status', v_activity.status,
      'title', v_activity.title,
      'description', v_activity.description,
      'category', v_activity.category,
      'starts_at', v_activity.starts_at,
      'ends_at', v_activity.ends_at,
      'location_label', v_activity.location_label,
      'capacity', v_activity.capacity,
      'participant_count', v_activity.participant_count,
      'what_to_bring', v_activity.what_to_bring,
      'campaign_id', v_activity.campaign_id,
      'cancelled_at', v_activity.cancelled_at,
      'created_at', v_activity.created_at
    )
  );
end;
$$;

revoke execute on function create_activity(
  uuid, text, text, public.category, timestamptz, timestamptz, double precision,
  double precision, text, int, text, uuid, uuid[], uuid, text, text, int, int, int
) from public, anon, authenticated, service_role;
grant execute on function create_activity(
  uuid, text, text, public.category, timestamptz, timestamptz, double precision,
  double precision, text, int, text, uuid, uuid[], uuid, text, text, int, int, int
) to service_role;
