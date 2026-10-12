-- §7.3 `POST /account/delete`: "Schedules full deletion (§5.4) | Signed in | 3/day". §11.3
-- makes it an app-store requirement — "Delete your account in the app" — and §11.2 makes it
-- the erasure right.
--
-- It schedules rather than deletes, because §5.4's deletion touches Storage and Auth, which
-- SQL cannot reach: the operations worker calls `delete_account` and the Storage and Auth
-- APIs. So this writes the request and queues the job.
--
-- **No onboarding gate**, and that is §5.2.1's own design rather than an omission: of the
-- four account tables, `account_deletions` is the one whose key is "user_id uuid pk (**no
-- FK**)". Every other table in this phase needed the gate because a foreign key to
-- `profiles` made it structural; here the schema deliberately allows a row for an account
-- that never onboarded, which is right — §11.2's erasure right does not begin at onboarding,
-- and someone who signed in once and stopped still has an `auth.users` row to erase.
--
-- **No suspension check either.** §17 `O33` bars a suspended account from writing content;
-- erasure is not content, and §11.2 does not condition the right on good standing. §11.6
-- keeps the registration details for 180 days whatever the account's status was, so the
-- record of any violation survives the deletion — which is the thing `O33` protects.
--
-- `security invoker`: §5.2 names "Account function, operations worker" as the writers and
-- grants `service_role` `select`, `insert (user_id)` and `update (status, attempts,
-- completed_at)`.
create function request_account_deletion(
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
  v_request public.account_deletions%rowtype;
begin
  if exists (select 1 from public.app_flags where key = 'read_only' and engaged) then
    return jsonb_build_object('error', 'FEATURE_DISABLED');
  end if;

  v_limited := private.check_rate_limit(
    p_bucket, p_user_id, p_per_minute, p_per_hour, p_per_day
  );
  if v_limited is not null then
    return v_limited;
  end if;

  -- Locked, because the branch below reads the status and then writes against it: §7.3
  -- allows three calls a day and a person who taps twice must not queue two deletions.
  select * into v_request from public.account_deletions
  where user_id = p_user_id for update;

  if found then
    -- A `failed` request is one §5.2.1 expects: it gives the table `attempts smallint` and a
    -- `failed` status so "a blocked deletion is one the flow retries rather than one it
    -- half-performs" (§5.4's `queue_media_deletion` note). Asking again restarts it.
    if v_request.status = 'failed' then
      -- `requested_at` is deliberately left alone, and §5.2 is why it has to be: the grant
      -- is `update (status, attempts, completed_at)` and does not include it. That is also
      -- the better record — §11.2's erasure duty runs from when the person first asked, not
      -- from the retry.
      update public.account_deletions
      set status = 'pending'
      where user_id = p_user_id
      returning * into v_request;
      perform pgmq.send('ops', jsonb_build_object(
        'kind', 'delete_account',
        'user_id', p_user_id
      ));
    end if;
    -- `pending` needs nothing: the job is already on the queue, and §8.4 is what retries it.
    -- `completed` is unreachable from a signed-in caller — the `auth.users` row is gone, so
    -- there is no token — but it is answered rather than refused, because the honest answer
    -- to "delete my account" when it is already deleted is that it is.
    return jsonb_build_object('status', v_request.status,
                              'requested_at', v_request.requested_at);
  end if;

  insert into public.account_deletions (user_id) values (p_user_id)
  returning * into v_request;

  -- Queued rather than polled, so §8.4's five retries and §12.5's waiting-job arm both
  -- cover it: §12.5 alarms on "a job enqueued over 15 minutes ago and not currently
  -- hidden", which is the only signal an erasure that never ran would otherwise have.
  perform pgmq.send('ops', jsonb_build_object(
    'kind', 'delete_account',
    'user_id', p_user_id
  ));

  return jsonb_build_object('status', v_request.status,
                            'requested_at', v_request.requested_at);
end;
$$;

revoke execute on function request_account_deletion(uuid, text, int, int, int)
  from public, anon, authenticated, service_role;
grant execute on function request_account_deletion(uuid, text, int, int, int)
  to service_role;
