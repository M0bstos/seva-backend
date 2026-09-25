-- §7.3 POST /acts: creates an Act with its metrics and photos, status pending.
-- One Postgres call per request (§13.4), so the kill switch and the limiter are
-- checked here rather than ahead of this call (§17.1).
--
-- Order: the kill switch, then onboarding, then the limiter, then the content. The
-- limiter is skipped for one case only — a replay this call can see already exists,
-- which writes nothing (§17.1). A key reused with a different body is not that:
-- §7.1.1 calls it a rejection, so it is metered like any other refused request
-- (§12.2). A duplicate racing the first insert cannot be seen at that point and so is
-- metered too, which §17.1 records rather than corrects: it is one write on a real
-- race, not the retry §7.1.1 set out to protect.
--
-- Returns the §7.4 code on refusal, otherwise the Act under `act` with `replayed`
-- saying whether it already existed. §7.1.1 fixes 200 for a replay and no status for
-- a new Act; the Edge Function answers 201 there (§17.1) and strips this key.
create function create_act(
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
  -- §10.2's switches. read_only stops every write, create_acts only this one.
  if exists (
    select 1 from public.app_flags
    where key in ('create_acts', 'read_only') and engaged
  ) then
    return jsonb_build_object('error', 'FEATURE_DISABLED');
  end if;

  -- §5.4: having a profile row is the onboarding gate.
  if not exists (select 1 from public.profiles where id = p_user_id) then
    return jsonb_build_object('error', 'ONBOARDING_REQUIRED');
  end if;

  -- §7.1.1. FOUND is captured now because anything run before it is read would reset
  -- it, and the limiter call below is one such statement.
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
    -- An Act documents an Activity only if the caller can see that Activity. §7.4
    -- folds "missing" and "not visible to you" into one code on purpose.
    if p_activity_id is not null and not exists (
      select 1 from public.activities
      where id = p_activity_id
        and (status = 'visible' or organiser_id = p_user_id)
    ) then
      return jsonb_build_object('error', 'NOT_FOUND');
    end if;

    -- §8.1: up to ten photos, each owned by the caller and in processing or ready.
    -- `act_id is null` is this function's own addition: without it, naming a photo
    -- already attached to an earlier Act would silently move it off that Act.
    if v_photos > 10 then
      return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'photo_ids');
    end if;
    -- `for update` makes this a lock and not just a look. Without it two Acts naming
    -- one photo both pass here on their own snapshots and the second wins the write,
    -- stripping the first Act of the only photo its metrics rest on — reproduced.
    -- The lock is held to commit, so the loser re-reads `act_id` and fails this test.
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

    -- §7.4: metrics claimed with no photo have nothing behind them.
    if p_metrics is not null and p_metrics <> '{}'::jsonb and v_photos = 0 then
      return jsonb_build_object('error', 'EVIDENCE_REQUIRED');
    end if;

    -- jsonb_each raises on anything that is not an object, which the route could only
    -- answer as INTERNAL — retryable (§7.4), so a permanently malformed body would be
    -- retried for ever. A SQL null means no metrics; a JSON null is not an object.
    if p_metrics is not null and jsonb_typeof(p_metrics) <> 'object' then
      return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'metrics');
    end if;

    for v_metric, v_json in
      select key, value from jsonb_each(coalesce(p_metrics, '{}'::jsonb))
    loop
      -- The cast comes first because until it passes, the key is caller text, and
      -- `field` is interpolated into the client-facing message by _shared/errors.ts.
      -- Echoing it back would reopen the §9.8 channel that message was narrowed to
      -- close. After the cast it is one of §5.3's metric names and safe to name.
      begin
        v_typed := v_metric::public.metric;
      exception when invalid_text_representation then
        return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'metrics');
      end;
      -- Every shape below would otherwise reach a cast or a table check and raise,
      -- which the route can only answer as INTERNAL — retryable (§7.4), so a
      -- permanently malformed body would be retried for ever.
      if jsonb_typeof(v_json) <> 'number' then
        return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', v_metric);
      end if;
      v_value := v_json::text::numeric;
      -- §5.2.1: positive, and whole except waste_kg and volunteer_hours.
      if v_value <= 0
         or (v_typed not in ('waste_kg', 'volunteer_hours') and v_value <> trunc(v_value))
      then
        return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', v_metric);
      end if;

      -- §6.3: a value above its per-Act maximum is refused, never clipped, so the
      -- person sees why and an absurd claim never reaches the ledger. The bound is
      -- not conditioned on `active`: that switches scoring off, and §6.3 gives
      -- max_per_act the different job of keeping absurd claims out of the ledger.
      select max_per_act into v_max from public.points_rules where rule = v_metric;
      if v_max is not null and v_value > v_max then
        return jsonb_build_object('error', 'METRIC_OUT_OF_RANGE');
      end if;
    end loop;

    -- The trigger coarsens the point before it is stored (§5.4), so the raw one
    -- passed in here never lands on disk.
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
        -- §5.2.1 bounds the title, story and occurred_on. A body that slips past the
        -- route's own validation would otherwise raise into a retryable INTERNAL
        -- (§7.4) whose DETAIL carries the request body into the log, against §9.8.
        return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'act');
      when unique_violation then
      -- §7.1.1: "the second waits on the unique index, then takes the same path".
      -- It waited here rather than at the lookup above, so it takes that path now.
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

      -- §17 O20: attaching a photo to its Act is this function's write, not the
      -- uploads function's, which runs before the Act exists.
      -- The same predicates as the check above, so the write cannot outlive the
      -- condition that justified it even if the lock were ever removed.
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

revoke execute on function create_act(
  uuid, text, text, public.category, date, double precision, double precision,
  uuid, jsonb, uuid[], uuid, text, text, int, int, int
) from public, anon, authenticated, service_role;
grant execute on function create_act(
  uuid, text, text, public.category, date, double precision, double precision,
  uuid, jsonb, uuid[], uuid, text, text, int, int, int
) to service_role;
