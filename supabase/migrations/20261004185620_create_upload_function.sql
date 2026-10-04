-- §7.3 POST /uploads: "Returns a photo ID and a one-time signed upload URL | Onboarded
-- | 30/h · 100/day". §8.1 step 1 fixes what that ID and URL are about — "a photo ID and
-- a one-time signed URL for `uploads/{user_id}/{media_id}` in the private bucket".
--
-- The signed URL is the route's half, because §5.4 is clear that storage cannot be
-- reached from SQL. This is the database half: one row in `media`, in `uploading`,
-- carrying the object path the route then signs. The path is **returned rather than
-- rebuilt** by the caller for the reason §17.1 records for `complete_photo_screening`:
-- the column is the authority on where a photo lives, and a route that re-derived it
-- could sign one object while the worker reads another.
--
-- `uploads/` in §8.1's path is the bucket, not a prefix inside it: §17.1 records an
-- avatar being served from the public bucket at `{owner_id}/{media_id}`, and the
-- moderation worker already publishes to `media` under the same key it read from
-- `uploads`. So the object key is `{owner_id}/{media_id}` and nothing repeats the
-- bucket name inside it.
--
-- Order as §17.1 fixes it: kill switch, onboarding, limiter, suspension, content.
-- There is no replay step — §5.2.1 gives `media` no `idempotency_key`, so §7.1.1 has
-- nothing to answer with and every call is a new row (§17.1 puts this route among the
-- creates that always answer 201).
--
-- `security invoker`: the route calls it on its own secret key, which resolves to
-- `service_role`, which §5.2 names as a writer of `media` and whose column grant —
-- `insert (id, owner_id, purpose, upload_path)`, in `media`'s own migration — is
-- exactly the four columns this writes. Every other column takes its §5.2.1 default.
create function create_upload(
  p_user_id uuid,
  p_purpose media_purpose,
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
  v_id uuid := gen_random_uuid();
  v_path text;
begin
  -- §10.2's switches. `read_only` stops every write, `uploads` only this one.
  if exists (
    select 1 from public.app_flags
    where key in ('uploads', 'read_only') and engaged
  ) then
    return jsonb_build_object('error', 'FEATURE_DISABLED');
  end if;

  -- §5.4: having a profile row is the onboarding gate. Above the limiter, because a
  -- caller barred by a rule they cannot see is not billed for it (§17.1).
  if not exists (select 1 from public.profiles where id = p_user_id) then
    return jsonb_build_object('error', 'ONBOARDING_REQUIRED');
  end if;

  v_limited := private.check_rate_limit(
    p_bucket, p_user_id, p_per_minute, p_per_hour, p_per_day
  );
  if v_limited is not null then
    return v_limited;
  end if;

  -- §17 O33, and below the limiter for the reason §17.1 gives: a suspended account has
  -- already been judged abusive, so handing it an unmetered path is the one thing
  -- §12.2's D5 note refuses everyone else.
  if exists (
    select 1 from public.profiles where id = p_user_id and status <> 'active'
  ) then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  v_path := p_user_id::text || '/' || v_id::text;

  insert into public.media (id, owner_id, purpose, upload_path)
  values (v_id, p_user_id, p_purpose, v_path);

  return jsonb_build_object('media_id', v_id, 'upload_path', v_path);
end;
$$;

revoke execute on function create_upload(uuid, media_purpose, text, int, int, int)
  from public, anon, authenticated, service_role;
grant execute on function create_upload(uuid, media_purpose, text, int, int, int)
  to service_role;
