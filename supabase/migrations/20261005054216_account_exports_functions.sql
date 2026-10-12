-- §7.3's two export routes, which are two halves of one thing and land together:
--
--   `POST /account/export`     — "Queues an export; returns `202 { export_id }`" · 2/day
--   `GET /account/export/:id`  — "Returns `{ status, url? }`; the URL is signed for 1 hour" · 30/h
--
-- §7.3 is explicit that it is asynchronous and why: "A synchronous export would not fit
-- inside an Edge Function's 2 seconds of CPU and 256 MB of memory for an account with a long
-- history." So the request writes a row and queues a job; the operations worker calls
-- `export_account(user_id)` and writes the file; this pair never touches Storage.

-- §7.3's queue half. `security invoker`: §5.2 grants `service_role` `select`,
-- `insert (user_id)` and `update (status, file_path, ready_at, expires_at)` on
-- `account_exports`, and names the account function and the operations worker as its writers.
create function request_account_export(
  p_user_id uuid,
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
  v_export public.account_exports%rowtype;
begin
  if exists (select 1 from public.app_flags where key = 'read_only' and engaged) then
    return jsonb_build_object('error', 'FEATURE_DISABLED');
  end if;

  -- §7.3 gives this route to "Signed in", but §5.2.1 makes `account_exports.user_id`
  -- `not null references profiles cascade`, so a row cannot exist without a profile — the
  -- same structural gate `submit_report` has, and the opposite of `account_deletions`, whose
  -- key §5.2.1 deliberately leaves without a foreign key. Above the limiter, so a caller
  -- barred by a rule they cannot see is not billed (§17.1).
  if not exists (select 1 from public.profiles where id = p_user_id) then
    return jsonb_build_object('error', 'ONBOARDING_REQUIRED');
  end if;

  v_limited := private.check_rate_limit(
    p_bucket, p_user_id, p_per_minute, p_per_hour, p_per_day
  );
  if v_limited is not null then
    return v_limited;
  end if;

  -- §17 `O33` is not applied here, for the reason `request_account_deletion` gives: §11.2's
  -- access right is not conditional on good standing, and an export is a read of the
  -- person's own data rather than content anyone else sees.
  --
  -- §5.2.1 gives this table no unique key on `user_id`, so §7.3's 2/day is the only bound
  -- on how many a person may ask for — which is what that limit is for, and why a second
  -- request is a second row rather than a replay.
  insert into public.account_exports (user_id) values (p_user_id)
  returning * into v_export;

  perform pgmq.send('ops', jsonb_build_object(
    'kind', 'export_account',
    'user_id', p_user_id,
    'export_id', v_export.id
  ));

  return jsonb_build_object('export_id', v_export.id, 'status', v_export.status);
end;
$$;

revoke execute on function request_account_export(uuid, text, int, int, int)
  from public, anon, authenticated, service_role;
grant execute on function request_account_export(uuid, text, int, int, int)
  to service_role;

-- §7.3's read half. It answers the status and, when there is one, the object path for the
-- route to sign — because §5.4 keeps Storage out of SQL and §7.3 puts the one-hour signature
-- on the route.
--
-- No kill switch: this is a read, and the four `discover` functions and `feed_acts` check
-- none either. §10.2's switches stop writes.
create function read_account_export(
  p_user_id uuid,
  p_export_id uuid,
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
  v_export public.account_exports%rowtype;
begin
  v_limited := private.check_rate_limit(
    p_bucket, p_user_id, p_per_minute, p_per_hour, p_per_day
  );
  if v_limited is not null then
    return v_limited;
  end if;

  -- §7.3 scopes this route to "Owner", and the `user_id` predicate is what makes it so: this
  -- function runs as `service_role`, which bypasses the `account_exports_select` policy that
  -- governs clients (§17 `O33`'s reasoning, applied to a read). An export id belonging to
  -- somebody else is `NOT_FOUND`, which §7.4 defines as "Missing, or not visible to you" —
  -- so the two cannot be told apart and an id cannot be probed.
  select * into v_export from public.account_exports
  where id = p_export_id and user_id = p_user_id;
  if not found then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  -- The path only when there is a file to sign. §7.3 keeps an export 7 days and §5.2.1 gives
  -- the row `expires_at`, so a `ready` row past its expiry has no file left — the operations
  -- worker deletes it and marks the row `expired`, and until it has, this must not hand out
  -- a signature for an object that is about to go. Measured on the local stack:
  -- `createSignedUrl` errors on an object that is not there, so a route signing blind would
  -- answer 500 rather than a status.
  return jsonb_build_object(
    'status', v_export.status,
    'file_path', case
                   when v_export.status = 'ready'
                        and v_export.expires_at is not null
                        and v_export.expires_at > now()
                   then v_export.file_path
                 end,
    'expires_at', v_export.expires_at
  );
end;
$$;

revoke execute on function read_account_export(uuid, uuid, text, int, int, int)
  from public, anon, authenticated, service_role;
grant execute on function read_account_export(uuid, uuid, text, int, int, int)
  to service_role;
