-- The `email` queue's two halves, which §1.1 counts as the second of three background workers
-- and §2.1 asks for: an Activity's organiser "can cancel, which notifies every participant by
-- email, or by SMS if they have no email".
--
-- The shape is `claim_moderation_jobs`' and `complete_text_screening`'s, deliberately: a claim
-- that archives what §8.4 says to archive and enriches what the worker needs, and a completion
-- that acts only while the message is still hidden. §8.4's two rules are what make a worker's
-- answer safe — "hidden for 60 seconds while processing and retried up to 5 times. After that
-- they are archived and an alarm fires; nothing is silently dropped", and `msg_id` is a
-- time-bounded capability rather than a bare integer.
--
-- **Neither function reads an address.** §5.4 keeps the phone number and the email in Supabase
-- Auth, and §17.1 records the consequence for this worker: "the message worker reads the
-- address from Auth, because §5.4 keeps it out of the profile tables and §9.8 keeps it out of
-- anything logged". So the claim hands out a user id and the worker asks the Auth admin API,
-- which keeps this pair out of `auth` entirely — and keeps the definer-body lint's one
-- exception at one.
--
-- `security invoker`: §5.1 grants `service_role` `usage` on `pgmq` with `execute` on its
-- functions and the relation privileges the queues migration lists, and §5.2 grants it `select`
-- on `activities` and `activity_participants`.

create function claim_message_jobs(p_count int) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_msg record;
  v_kind text;
  v_activity_id uuid;
  v_user_id uuid;
  v_job jsonb;
  v_jobs jsonb := '[]'::jsonb;
begin
  -- Bounded for the reason §17.1 gives `claim_moderation_jobs`: an unbounded count would hide
  -- the whole queue for the 60 seconds §8.4 allows, on a single call.
  if p_count is null or p_count < 1 or p_count > 100 then
    raise exception 'claim_message_jobs takes a count between 1 and 100';
  end if;

  for v_msg in
    select msg_id, read_ct, message from pgmq.read('email', 60, p_count)
  loop
    v_kind := v_msg.message ->> 'kind';

    if v_msg.read_ct > 5 then
      perform pgmq.archive('email', v_msg.msg_id);
      continue;
    end if;

    -- §5.3 has no enum for a message kind, so the one `cancel_activity` and the account
    -- deletion send is the only one there is. Anything else is a message this version cannot
    -- have written, and §8.4's "nothing is silently dropped" makes that an archive rather than
    -- a delete.
    if v_kind is null or v_kind <> 'activity_cancelled' then
      perform pgmq.archive('email', v_msg.msg_id);
      continue;
    end if;

    -- The casts are guarded for the reason §17.1 measured on the moderation queue: one
    -- malformed message whose cast ran before the archive checks starved the whole queue,
    -- because the raise rolled back `pgmq.read`'s own visibility update and the message was
    -- re-read for ever.
    begin
      v_activity_id := (v_msg.message ->> 'activity_id')::uuid;
      v_user_id := (v_msg.message ->> 'user_id')::uuid;
    exception when invalid_text_representation or null_value_not_allowed then
      perform pgmq.archive('email', v_msg.msg_id);
      continue;
    end;

    -- What the message says, and nothing about who it goes to beyond the id. §2.1 makes this a
    -- cancellation notice, so the Activity's own details are the content.
    select jsonb_build_object(
             'user_id', v_user_id,
             'activity_id', c.id,
             'title', c.title,
             'starts_at', c.starts_at,
             'location_label', c.location_label)
    into v_job
    from public.activities c
    -- Joined to the participant row so a job for somebody who left, or for an Activity that is
    -- gone, resolves to nothing rather than to a message nobody should get.
    --
    -- **`status = 'joined'` is load-bearing and was missing**, found in review: `leave_activity`
    -- sets the status and keeps the row (§5.2.1 gives it `left_at`), so the join alone matched
    -- somebody who had left and the comment above was describing behaviour the code did not have.
    -- Both producers filter on their own side today — `cancel_activity` and `delete_account` — so
    -- nothing reached it, which is exactly why it was invisible: the only check was in the callers.
    join public.activity_participants ap
      on ap.activity_id = c.id and ap.user_id = v_user_id
     and ap.status = 'joined'
    where c.id = v_activity_id and c.cancelled_at is not null;

    if v_job is null then
      -- Nothing to send and nothing to retry: §8.4's archive is for work that failed, and this
      -- is work that no longer exists.
      perform pgmq.delete('email', v_msg.msg_id);
      continue;
    end if;

    v_jobs := v_jobs || jsonb_build_array(
      jsonb_build_object('msg_id', v_msg.msg_id, 'kind', v_kind) || v_job
    );
  end loop;

  return v_jobs;
end;
$$;

revoke execute on function claim_message_jobs(int)
  from public, anon, authenticated, service_role;
grant execute on function claim_message_jobs(int) to service_role;

-- A message that was sent. §8.4's `vt > now()` window is what makes `msg_id` a capability
-- rather than an integer anyone holding a secret key could guess: a completion produced against
-- a lapsed claim is one to discard and let the retry redo, because another worker may have the
-- job by then.
-- **Bound to the kind as well as the window**, for the reason §8.4 gives and `complete_ops_job`
-- carries in full: a verdict is bound to what it is about as well as to when it was claimed, and
-- `msg_id` is a monotonic sequence. One kind on this queue today, so the blast radius was smaller
-- than the `ops` case — but the asymmetry was the same, and a second kind would inherit it.
create function complete_message_job(p_msg_id bigint, p_kind text) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform 1 from pgmq.q_email q
  where q.msg_id = p_msg_id and q.vt > now()
    and q.message ->> 'kind' = p_kind;
  if not found then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  perform pgmq.delete('email', p_msg_id);
  return jsonb_build_object('status', 'sent');
end;
$$;

revoke execute on function complete_message_job(bigint, text)
  from public, anon, authenticated, service_role;
grant execute on function complete_message_job(bigint, text) to service_role;
