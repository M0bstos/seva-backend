-- §7.3 POST /uploads/:id/complete, and §8.1 step 3: "The app calls `POST
-- /uploads/:id/complete`. That route confirms the object exists and is 5 MB or smaller
-- through the Storage API, sets the photo to `processing`, and queues a moderation
-- job." This is the only producer of the photo jobs §8's worker consumes, so until it
-- exists §8.3's photo half has no in-system trigger at all.
--
-- **Two functions, and therefore two round trips.** §13.4 and §12.2 now name this route
-- as the one exception to a single Postgres call (§17.1): §8.1 puts a Storage confirmation
-- *between* the route's checks and its writes, and §5.4 says storage cannot be reached
-- from SQL, so the two cannot be one call. Which half goes first is decided by §17.1
-- rather than by taste: "per-request content is checked **after** the count", and the media id is
-- per-request content. Confirming the object before counting would hand any token
-- holder an unmetered Storage call per guessed id, and answer it a refusal — the
-- unbilled rejection §12.2's D5 note refuses. So the count happens in the first call,
-- the confirmation second, and the write third.
--
-- Nothing is mutated by the first call. A route that died after it leaves the row in
-- `uploading`, which §8.1's own 24-hour sweep collects — so a failed Storage check
-- costs a swept row rather than a photo parked in `processing`, where §12.5's
-- stuck-screening arm would fire on it fifteen minutes later.
--
-- Both are in one migration because they are one behavioural change: neither half of
-- §8.1 step 3 does anything without the other.

-- Which object the route is to confirm, or why it may not. `security invoker`: the
-- route calls it on its secret key, and `media`'s migration grants `service_role`
-- `select` on the table, which is all this half reads.
create function confirm_upload_target(
  p_user_id uuid,
  p_media_id uuid,
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
  v_media public.media%rowtype;
begin
  if exists (
    select 1 from public.app_flags
    where key in ('uploads', 'read_only') and engaged
  ) then
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

  if exists (
    select 1 from public.profiles where id = p_user_id and status <> 'active'
  ) then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  select * into v_media from public.media
  where id = p_media_id and owner_id = p_user_id;

  -- §17.1 already folds five refusals about a photo into one code, so that telling
  -- them apart cannot tell a caller which photo ids exist. The two here — no such id,
  -- and not yours — are the same fold, and `FORBIDDEN` is §7.4's "Not yours".
  if not found then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  -- A photo past `uploading` has already been completed once, and is answered with its
  -- status rather than refused. Not as a §7.1.1 replay — that machinery is for creates,
  -- whose resource has no name until it exists, which is why §5.2.1 gives `media` no
  -- `idempotency_key` at all. This route is a **transition on a resource the URL already
  -- names**, so a repeat is idempotent by construction (§17.1): a `FORBIDDEN` would tell a
  -- caller whose upload in fact succeeded that the photo is not theirs. No `upload_path`
  -- comes back, so the route skips the Storage call and the second write entirely.
  if v_media.status <> 'uploading' then
    return jsonb_build_object('status', v_media.status);
  end if;

  -- The path alone. A `status` here would always read `uploading` and the route reads it
  -- only on the branch above — declared surface with no use, which CLAUDE.md rules out
  -- and `claim_without_purpose` already removed once.
  return jsonb_build_object('upload_path', v_media.upload_path);
end;
$$;

revoke execute on function confirm_upload_target(uuid, uuid, text, int, int, int)
  from public, anon, authenticated, service_role;
grant execute on function confirm_upload_target(uuid, uuid, text, int, int, int)
  to service_role;

-- §8.1 step 3's two writes, once the route has confirmed the object. The third of
-- §8.2's screening producers and the first for a photo: `queue_text_screening` and
-- `queue_profile_text_screening` are triggers, and this one is a function because what
-- moves a photo forward is a call from the app, not a row changing.
--
-- `security invoker`: `media`'s migration grants `service_role` `update (status, ...)`,
-- and §5.1 grants it `usage` on `pgmq` with `execute` on its functions. That is also why
-- this needs none of the `security definer` the delete trigger needs — the caller here
-- is always the route on its own secret key, never a cascade driven by another role.
create function queue_photo_screening(p_user_id uuid, p_media_id uuid) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_media public.media%rowtype;
begin
  -- §10.2 is written about the function that acts: "Functions check them before doing
  -- anything and return `FEATURE_DISABLED`." This is the half that writes, so it checks
  -- them itself rather than trusting the call before it — which also closes the window
  -- where a switch thrown during the Storage round trip would not stop the write.
  if exists (
    select 1 from public.app_flags
    where key in ('uploads', 'read_only') and engaged
  ) then
    return jsonb_build_object('error', 'FEATURE_DISABLED');
  end if;

  -- §17 O33, re-checked here for the same reason and at the same cost: a suspension
  -- landing between the two calls would otherwise still spend a screening call (§8.4).
  if exists (
    select 1 from public.profiles where id = p_user_id and status <> 'active'
  ) then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  -- The limiter is not repeated: `confirm_upload_target` counted this request once, and
  -- counting it twice would halve §7.3's 60/h for every caller.
  --
  -- Locked and re-read on ownership and status, so the write cannot outlive the
  -- condition that justified it — the rule §17.1 records for `create_act`'s photo lock.
  -- Two `complete` calls racing therefore produce one job: the loser re-reads
  -- `processing` and falls through to the branch below.
  select * into v_media from public.media
  where id = p_media_id and owner_id = p_user_id
  for update;

  if not found then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;
  if v_media.status <> 'uploading' then
    return jsonb_build_object('status', v_media.status);
  end if;

  update public.media set status = 'processing' where id = p_media_id;

  -- The kind and the id, and nothing else. `claim_moderation_jobs` reads the
  -- `upload_path` off the row when it hands the job out, so a path recorded here could
  -- disagree with the column by the time a worker saw it.
  perform pgmq.send('moderation', jsonb_build_object(
    'kind', 'photo',
    'id', p_media_id
  ));

  return jsonb_build_object('status', 'processing');
end;
$$;

revoke execute on function queue_photo_screening(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function queue_photo_screening(uuid, uuid) to service_role;
