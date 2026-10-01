-- §2.1: "An Act can link to an Activity **the author joined, once that Activity has
-- started**." Neither half was enforced. `create_act` checked only that the Activity
-- was visible or the caller's own, so any signed-in person could attach their Act to
-- any visible Activity — including one in a campaign they have nothing to do with,
-- and one that has not happened yet.
--
-- What that cost, reproduced on the local stack: the award trigger took the Activity's
-- `campaign_id` onto every ledger row, and `update_campaign_progress` is the one
-- frame holding a write to `campaigns`. A user who joined nothing moved a 5,000 kg
-- goal by 600 kg in three Acts, and §6.1's daily cap cannot bound it because that
-- section keeps `value` at full size while clamping `points`. The trigger now
-- attributes a campaign only to an author who joined; this closes it at the gate as
-- well, which is where §2.1 puts it.
--
-- Rolled forward as a replacement rather than an edit (§13.3). Everything else about
-- the function is unchanged, including the order §17.1 fixes — kill switch,
-- onboarding, replay, limiter, suspension, content.
--
-- `FORBIDDEN` and not `NOT_FOUND`: the caller can see this Activity, and §7.4 gives
-- FORBIDDEN "not yours", which §17.1 already applies to a photo the caller owns but
-- may not attach. NOT_FOUND stays for an Activity that is not theirs to see at all.
create or replace function create_act(
  p_user_id uuid,
  p_title text,
  p_story text,
  p_category category,
  p_occurred_on date,
  p_lon double precision,
  p_lat double precision,
  p_activity_id uuid,
  p_metrics jsonb,
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
  v_act public.acts%rowtype;
  v_exists boolean;
  v_replayed boolean;
  v_limited jsonb;
  v_photos int := coalesce(array_length(p_photo_ids, 1), 0);
  v_metric text;
  v_json jsonb;
  v_typed public.metric;
  v_value numeric;
  v_max numeric;
begin
  if exists (
    select 1 from public.app_flags
    where key in ('create_acts', 'read_only') and engaged
  ) then
    return jsonb_build_object('error', 'FEATURE_DISABLED');
  end if;

  if not exists (select 1 from public.profiles where id = p_user_id) then
    return jsonb_build_object('error', 'ONBOARDING_REQUIRED');
  end if;

  select * into v_act from public.acts
  where author_id = p_user_id and idempotency_key = p_idempotency_key;
  v_exists := found;
  v_replayed := v_exists and v_act.request_hash is not distinct from p_request_hash;

  if not v_replayed then
    v_limited := private.check_rate_limit(
      p_bucket, p_user_id, p_per_minute, p_per_hour, p_per_day
    );
    if v_limited is not null then
      return v_limited;
    end if;
  end if;

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
    if p_activity_id is not null and not exists (
      select 1 from public.activities
      where id = p_activity_id
        and (status = 'visible' or organiser_id = p_user_id)
    ) then
      return jsonb_build_object('error', 'NOT_FOUND');
    end if;

    -- §2.1's two conditions. The organiser is a participant for this purpose: they
    -- ran the Activity, and §7.3's join route is for everyone else.
    if p_activity_id is not null and not exists (
      select 1 from public.activities a
      where a.id = p_activity_id
        and a.starts_at <= now()
        and (
          a.organiser_id = p_user_id
          or exists (
            select 1 from public.activity_participants p
            where p.activity_id = a.id and p.user_id = p_user_id and p.status = 'joined'
          )
        )
    ) then
      return jsonb_build_object('error', 'FORBIDDEN');
    end if;

    if v_photos > 10 then
      return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'photo_ids');
    end if;
    if v_photos > 0 and v_photos <> (
      select count(*) from (
        select 1 from public.media
        where id = any(p_photo_ids)
          and owner_id = p_user_id
          and purpose = 'act'
          and act_id is null
          and status in ('processing', 'ready')
        for update
      ) locked
    ) then
      return jsonb_build_object('error', 'FORBIDDEN');
    end if;

    if p_metrics is not null and p_metrics <> '{}'::jsonb and v_photos = 0 then
      return jsonb_build_object('error', 'EVIDENCE_REQUIRED');
    end if;

    if p_metrics is not null and jsonb_typeof(p_metrics) <> 'object' then
      return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'metrics');
    end if;

    for v_metric, v_json in
      select key, value from jsonb_each(coalesce(p_metrics, '{}'::jsonb))
    loop
      begin
        v_typed := v_metric::public.metric;
      exception when invalid_text_representation then
        return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'metrics');
      end;
      if jsonb_typeof(v_json) <> 'number' then
        return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', v_metric);
      end if;
      v_value := v_json::text::numeric;
      if v_value <= 0
         or (v_typed not in ('waste_kg', 'volunteer_hours') and v_value <> trunc(v_value))
      then
        return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', v_metric);
      end if;

      select max_per_act into v_max from public.points_rules where rule = v_metric;
      if v_max is not null and v_value > v_max then
        return jsonb_build_object('error', 'METRIC_OUT_OF_RANGE');
      end if;
    end loop;

    begin
      insert into public.acts (
        author_id, activity_id, title, story, category, occurred_on,
        location_coarse, idempotency_key, request_hash
      ) values (
        p_user_id, p_activity_id, p_title, p_story, p_category, p_occurred_on,
        extensions.st_setsrid(extensions.st_makepoint(p_lon, p_lat), 4326)::extensions.geography,
        p_idempotency_key, p_request_hash
      )
      returning * into v_act;
    exception
      when check_violation then
        return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'act');
      when unique_violation then
      select * into v_act from public.acts
      where author_id = p_user_id and idempotency_key = p_idempotency_key;
      if v_act.request_hash is distinct from p_request_hash then
        return jsonb_build_object('error', 'IDEMPOTENCY_KEY_REUSED');
      end if;
      v_replayed := true;
    end;

    if not v_replayed then
      insert into public.act_metrics (act_id, metric, value)
      select v_act.id, key::public.metric, value::text::numeric
      from jsonb_each(coalesce(p_metrics, '{}'::jsonb));

      update public.media m
      set act_id = v_act.id, position = (p.ord - 1)::smallint
      from unnest(p_photo_ids) with ordinality as p (photo_id, ord)
      where m.id = p.photo_id
        and m.owner_id = p_user_id
        and m.purpose = 'act'
        and m.act_id is null
        and m.status in ('processing', 'ready');
    end if;
  end if;

  return jsonb_build_object(
    'replayed', v_replayed,
    'act', jsonb_build_object(
      'id', v_act.id,
      'status', v_act.status,
      'title', v_act.title,
      'story', v_act.story,
      'category', v_act.category,
      'occurred_on', v_act.occurred_on,
      'activity_id', v_act.activity_id,
      'created_at', v_act.created_at,
      'published_at', v_act.published_at
    )
  );
end;
$$;
