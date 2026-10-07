-- §7.3 `POST /reports`, and §8.5 in full: "The `submit_report()` Postgres function owns
-- this, not a trigger, so it all happens in one transaction: 1. Insert the report.
-- 2. Count distinct reporters with open reports against that subject, whose accounts are
-- at least 7 days old, excluding the subject's own author. 3. On reaching the threshold,
-- move the content to `held` through the same internal status function staff use, and
-- write an audit row with `actor = 'system'`."
--
-- `security invoker`, which §17.1 fixes: "`admin_audit_log` is written inside the definer
-- status function §8.5 shares with `admin_set_content_status`, so `submit_report()` stays
-- invoker". §5.2 grants `service_role` the `select` and nine-column `insert` on `reports`
-- it needs, and §17's `O16` grant lets it read an account's age without a definer frame —
-- which is exactly one of the three reads that grant was taken for. §8.5 step 3 goes
-- through `hold_reported_content`, so this path cannot reach `set_content_status`'s
-- `removed` branch or the points-ledger delete inside it. The third grant this migration
-- needs — `update (reason, details)` for the escalation below — lands in a migration of its
-- own, beside the table's, which is where CLAUDE.md puts a table's grants.
--
-- Order as §17.1 fixes it for a create function: onboarding, replay, limiter, content. The
-- kill switch is the one step missing, deliberately — see below.
--
-- One exit for every success, which is `create_act`'s shape: the branches set `v_replayed`
-- or `v_already_open` and fall through, so what a reporter is told is built in one place.
-- Four fields — §7.2 grants clients no read on `reports` at all, so it is the only view of
-- one they ever get, and `reporter_id` is their own while `resolved_by`, `resolved_at` and
-- `resolution_note` are a moderator's and reach nobody in v1.

-- How §10.4 and §11.6 rank a reason, which is what decides whether a second report on one
-- subject escalates the first. Three bands, from the deadlines those sections give:
-- `intimate_imagery` has two hours (§10.4) and alarms at 45 minutes; `impersonation` has
-- §11.6's 36 hours and alarms at 60; everything else is measured by the 18-hour arm `O35`
-- applies to every open report. A function rather than the enum's own order, because §5.3
-- declares `report_reason` for reading rather than by urgency, so adding a value there must
-- not silently re-rank these.
create function private.report_urgency(p_reason report_reason) returns int
language sql
security invoker
immutable
set search_path = ''
as $$
  select case p_reason
           when 'intimate_imagery' then 2
           when 'impersonation' then 1
           else 0
         end;
$$;

revoke execute on function private.report_urgency(report_reason)
  from public, anon, authenticated, service_role;
grant execute on function private.report_urgency(report_reason) to service_role;

create function submit_report(
  p_user_id uuid,
  p_subject_type report_subject,
  p_act_id uuid,
  p_activity_id uuid,
  p_reported_user_id uuid,
  p_reason report_reason,
  p_details text,
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
  v_report public.reports%rowtype;
  v_exists boolean;
  v_replayed boolean := false;
  v_already_open boolean := false;
  -- Whether this call wrote a row — an insert or an escalation. §8.5's count and hold hang
  -- off this and not off reaching the end of the function, for the reason in the comment
  -- above them.
  v_wrote boolean := false;
  v_limited jsonb;
  v_threshold int;
  v_reporters int;
  v_subject_owner uuid;
begin
  -- **No kill switch, and `read_only` in particular.** §17.1 exempts staff moderation from
  -- every switch because §12.6 turns `read_only` on during a suspected breach, "precisely
  -- when §11.6's 3-hour court-order clock and §10.4's 2-hour intimate-imagery clock are
  -- most likely to be running". That argument covers the intake as much as the action: a
  -- switch that let staff take content down while the public could not tell them to would
  -- close the channel §11.3 requires at the moment §10.4's clocks matter most. §5.3 gives
  -- `reports` no switch of its own, so there is no narrower lever to leave engaged.

  -- §7.3 gives this route to "Signed in" rather than "Onboarded", but §5.4 is the governing
  -- sentence — "having a profile row is the gate: every write function returns
  -- `ONBOARDING_REQUIRED` until one exists" — and §5.2.1 makes it structural here anyway,
  -- with `reporter_id not null references profiles`. Answering the code is what keeps the
  -- foreign key from raising 23503 into a retryable INTERNAL (§17.1).
  if not exists (select 1 from public.profiles where id = p_user_id) then
    return jsonb_build_object('error', 'ONBOARDING_REQUIRED');
  end if;

  -- §7.1.1. FOUND is captured now because anything run before it is read would reset it.
  select * into v_report from public.reports
  where reporter_id = p_user_id and idempotency_key = p_idempotency_key;
  v_exists := found;
  v_replayed := v_exists and v_report.request_hash is not distinct from p_request_hash;

  if not v_replayed then
    v_limited := private.check_rate_limit(
      p_bucket, p_user_id, p_per_minute, p_per_hour, p_per_day
    );
    if v_limited is not null then
      return v_limited;
    end if;
  end if;

  -- **§17 `O33` is deliberately not applied here**, reversing an earlier reading of it. O33
  -- bars a suspended account from writing *content*; a report is not content, and §11.3's
  -- duty — "Report content and respond quickly" — carries no exception for the reporter's
  -- own standing. `O15` separately lets a suspended person keep browsing, so barring them
  -- would mean somebody could see intimate imagery of themselves and have no way to start
  -- §10.4's two-hour clock for up to the seven days §10.2 allows a moderator.
  --
  -- The retaliation worry that first argued for the bar is real but smaller: §8.5 counts
  -- *distinct* reporters, so one suspended account cannot reach the threshold of three on
  -- its own, and on the two first-report reasons the urgency outweighs it — a hold is
  -- reviewable inside §10.4's 20 hours and leaves an `actor = 'system'` audit row, where a
  -- missed intimate-imagery complaint is a legal deadline nobody can recover.

  if v_exists and not v_replayed then
    return jsonb_build_object('error', 'IDEMPOTENCY_KEY_REUSED');
  end if;

  if not v_replayed then
    -- §5.2.1's subject checks, kept off the table's own `check_violation` path for the
    -- reason §17.1 gives: a 23514 reaches the route as a retryable INTERNAL whose DETAIL
    -- carries the request body into the log (§9.8).
    --
    -- `p_subject_type is not null` comes first, and it is load-bearing rather than tidy:
    -- the three comparisons after it are three-valued, so a null subject type made each of
    -- them NULL, the whole condition NULL, and control reached the insert — which raised
    -- 23502, whose DETAIL carries the failing row with `details` in it. Measured: a street
    -- address and a mobile number in that field reached the Postgres log §11.6 keeps for
    -- 180 days, through the one function whose stated design keeps them out of it.
    if p_subject_type is null
       or p_reason is null
       or num_nonnulls(p_act_id, p_activity_id, p_reported_user_id) <> 1
       or (p_act_id is not null and p_subject_type <> 'act')
       or (p_activity_id is not null and p_subject_type <> 'activity')
       or (p_reported_user_id is not null and p_subject_type <> 'profile')
    then
      return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'subject_type');
    end if;

    -- §5.2.1 gives `request_hash` a check of its own — exactly 64 characters, the SHA-256
    -- hex §7.1.1 specifies. Named here because the `check_violation` handler below cannot
    -- tell it from the bound on `details` and would otherwise blame the wrong field (§7.4).
    if p_request_hash is null or char_length(p_request_hash) <> 64 then
      return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'request_hash');
    end if;

    -- The last `not null` column the handler below would have had to speak for, and it
    -- cannot: a null key reaches the insert, raises 23502, and gets answered `details` —
    -- the mislabel the guard above was added to prevent (§7.4 has the message name the
    -- field).
    if p_idempotency_key is null then
      return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'idempotency_key');
    end if;

    -- §5.2.1 bounds `details` at 500, and the insert's handler is not enough to hold that
    -- bound: the escalation `update` below sits outside it, so an overlong `details` on a
    -- *second, more urgent* report raised 23514 from there with nothing to catch it.
    -- Measured in review — a mobile number and a street address in that field reached the
    -- Postgres log §11.6 keeps for 180 days, which is the same leak as the 23502 above and
    -- through the same function. One guard ahead of both writes rather than a second
    -- handler, so there is one place to keep in step.
    if p_details is not null and char_length(p_details) > 500 then
      return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'details');
    end if;

    -- The subject has to be there, and `removed` content is already gone from every
    -- reader's view (§8.3), so there is nothing left to report about it. §7.4 folds
    -- "missing" and "not visible to you" into one code, which is what keeps this from
    -- telling a caller which ids exist. The owner is read in the same statement, because
    -- §8.5 step 2 excludes "the subject's own author" from the count.
    --
    -- `pending` is **not** excluded, though it is content only its author can see. §8.3
    -- sends a visible Act back to `pending` when its author edits it, and §8.5's own
    -- threshold is expected to keep crossing on `held` content — so a reporter who saw
    -- something a moment ago can find it in either state through no act of their own, and
    -- refusing then would drop a complaint that may be on §10.4's two-hour clock, for a
    -- reason the reporter cannot see. The residual is that a caller already holding a uuid
    -- can tell "exists" from "does not", which needs the uuid first.
    if p_act_id is not null then
      select author_id into v_subject_owner from public.acts
      where id = p_act_id and status <> 'removed';
    elsif p_activity_id is not null then
      select organiser_id into v_subject_owner from public.activities
      where id = p_activity_id and status <> 'removed';
    else
      select id into v_subject_owner from public.profiles where id = p_reported_user_id;
    end if;
    if not found then
      return jsonb_build_object('error', 'NOT_FOUND');
    end if;

    -- §5.2.1's "one open report per reporter per subject" is a partial unique index, so a
    -- second open report is forbidden by design rather than by accident. The person's
    -- report is already on file and open, so answering with that row is the truthful
    -- answer — and it keeps a double tap on Report off the 23505 path, which the route
    -- could only answer as a retryable INTERNAL.
    --
    -- **Except when the new reason is more urgent, which was a defect found in review.** A
    -- reporter with an open `spam` report on an Act who then reported it as
    -- `intimate_imagery` got the `spam` row back: no row carrying the urgent reason was
    -- ever written, so §8.5's threshold of one never fired and `health_status`'s 45-minute
    -- arm — which reads `reason = 'intimate_imagery'` — could never see it. §10.4's
    -- two-hour clock became unobservable through nothing but the order two reports arrived
    -- in. The index is per subject and not per reason, so there is nowhere to put a second
    -- row: the open one is **escalated** instead, and then falls through to §8.5's count.
    select * into v_report from public.reports
    where reporter_id = p_user_id
      and status = 'open'
      and (act_id = p_act_id or activity_id = p_activity_id
           or reported_user_id = p_reported_user_id)
    for update;

    if found then
      v_already_open := true;
    else
      -- §8.5 step 1.
      begin
        insert into public.reports (
          reporter_id, subject_type, act_id, activity_id, reported_user_id,
          reason, details, idempotency_key, request_hash
        ) values (
          p_user_id, p_subject_type, p_act_id, p_activity_id, p_reported_user_id,
          p_reason, p_details, p_idempotency_key, p_request_hash
        )
        returning * into v_report;
        v_wrote := true;
      exception
        when check_violation or not_null_violation then
          -- §5.2.1 bounds `details` at 500, and every other column here is `not null`. The
          -- route checks both, so this is the backstop — and it is what keeps a body
          -- slipping past it out of the 180-day log, because a 23502's DETAIL carries the
          -- failing row with `details` in it (§9.8). It catches `not_null_violation` as
          -- well as the guard above, because a guard is a list of columns and this is not.
          return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'details');
        when unique_violation then
          -- §7.1.1: "the second waits on the unique index, then takes the same path."
          -- Either index can have been the one that blocked, so both are re-read.
          select * into v_report from public.reports
          where reporter_id = p_user_id and idempotency_key = p_idempotency_key;
          if found then
            if v_report.request_hash is distinct from p_request_hash then
              return jsonb_build_object('error', 'IDEMPOTENCY_KEY_REUSED');
            end if;
            v_replayed := true;
          else
            select * into v_report from public.reports
            where reporter_id = p_user_id
              and status = 'open'
              and (act_id = p_act_id or activity_id = p_activity_id
                   or reported_user_id = p_reported_user_id)
            for update;
            -- Neither re-read found a row, which is reachable: a moderator resolving the
            -- conflicting open report between the insert raising 23505 and this statement's
            -- own snapshot leaves nothing matching `status = 'open'`. Answering a success
            -- with a null report would drop a complaint behind a 200 — for
            -- `intimate_imagery`, §10.4's two-hour clock never starting. `INTERNAL` is the
            -- honest answer, and §7.4 marks it retryable, which is what should happen now
            -- that the conflict is gone.
            if not found then
              return jsonb_build_object('error', 'INTERNAL');
            end if;
            v_already_open := true;
          end if;
      end;
    end if;

    -- The escalation, on one site both paths reach. It was on the first path only, which
    -- left the defect the comment above describes alive under concurrency: two overlapping
    -- reports from one reporter, the first `spam` and the second `intimate_imagery`, take
    -- the 23505 re-read instead and used to leave the row carrying `spam` — so §12.5's
    -- 45-minute arm, which reads `reason = 'intimate_imagery'`, still could not see it.
    -- Both re-reads lock the row, so the comparison here is against a row no other
    -- transaction can move underneath it.
    --
    -- `v_replayed` is excluded by construction rather than by a test: the same key and the
    -- same hash is the same request, so the row it found is the one it wrote itself.
    if v_already_open
       and private.report_urgency(p_reason) > private.report_urgency(v_report.reason) then
      update public.reports
      set reason = p_reason, details = coalesce(p_details, details)
      where id = v_report.id
      returning * into v_report;
      v_wrote := true;
    end if;

    -- **Only when this call wrote something**, which was a defect found in review. A
    -- duplicate — the same reporter tapping Report again on content they have already
    -- reported, and the concurrent replay the 23505 handler answers — fell through to the
    -- count and re-entered `hold_reported_content` on a threshold nothing had crossed. The
    -- hold itself is a no-op (§17.1's `held` → `held`), but the audit row is not: §11.6
    -- makes `admin_audit_log` the evidentiary record of a takedown and §10.3 renders it, so
    -- a second `actor = 'system'` row saying content reached a threshold it reached minutes
    -- earlier is a false entry in the one place that is supposed to be exact. §17.1 sanctions
    -- the no-op for a *second reporter* crossing a threshold on content already held, which
    -- is a different event. An escalation genuinely needs the recount; a duplicate does not.
    if v_wrote then
      -- §8.5's table. `intimate_imagery` holds on the first report "because the response
      -- deadline is two hours (§10.4)", and `impersonation` with it (§11.6). Read before the
      -- count, because the count depends on it.
      --
      -- From the row and not from `p_reason`, which are equal on both paths that get here —
      -- an insert writes `p_reason` and an escalation sets it — but the audit line below
      -- quotes this, and §11.6 makes that line evidence. The reason a row carries is the
      -- honest one to hold content for.
      v_threshold := case
                       when v_report.reason in ('intimate_imagery', 'impersonation') then 1
                       else 3
                     end;

      -- §8.5 step 2. Distinct reporters, not reports: §5.2.1 already holds one open report
      -- per reporter per subject, so the two differ only across reasons, and what the
      -- threshold is about is how many *people* complained.
      --
      -- **Neither filter applies to the two first-report reasons**, which was a defect found
      -- in review. §8.5 writes the 7-day floor and the author exclusion as one step and the
      -- threshold as the next, so read literally they apply to both — and on a threshold of
      -- one that inverts them: the only report in play is the one just filed, so a reporter
      -- whose account is under a week old could never hold anything, however many such
      -- reports arrived. §11.6 says both reasons "hold content on the **first** report", and
      -- the typical intimate-imagery complainant is somebody who signed up in order to
      -- report. The floor is an anti-brigading control for the threshold of three, where
      -- minting accounts is the attack it answers; at one there is nothing to brigade.
      select count(distinct r.reporter_id) into v_reporters
      from public.reports r
      join auth.users u on u.id = r.reporter_id
      where r.status = 'open'
        and (v_threshold = 1 or u.created_at <= now() - interval '7 days')
        and (v_threshold = 1 or r.reporter_id is distinct from v_subject_owner)
        and (r.act_id = p_act_id or r.activity_id = p_activity_id
             or r.reported_user_id = p_reported_user_id);

      -- §8.5 step 3, through the wrapper rather than `set_content_status` itself: this
      -- function is `security invoker` and runs as `service_role`, and granting that role the
      -- whole status function would hand every Edge Function key a points-ledger delete
      -- through its `removed` branch.
      --
      -- A profile is not content and §8.3's statuses do not describe one: §10.2 gives a
      -- person `admin_suspend_user` and `admin_hide_profile_text` instead, both a person's
      -- decision, so a reported profile reaches the review queue through the open report and
      -- §12.5's 45- and 60-minute arms rather than through an automatic hold.
      if v_reporters >= v_threshold and p_reported_user_id is null then
        perform public.hold_reported_content(
          p_act_id, p_activity_id,
          'automatic hold at ' || v_reporters || ' reports for ' || v_report.reason
        );
      end if;
    end if;
  end if;

  -- Nothing about the hold comes back. §8.5's threshold is a moderation control, and a
  -- caller who could see it fire could find the threshold by experiment and tell which
  -- content is already near it.
  --
  -- `replayed` is §7.1.1's strict sense — same key, same hash — and `already_open` is
  -- §5.2.1's one-open-report fold, including an escalation. Two flags rather than one
  -- because they mean different things to a person: "we already have this request" against
  -- "you have already told us about this". The route answers 201 only when both are false,
  -- since nothing was created otherwise.
  return jsonb_build_object(
    'replayed', v_replayed,
    'already_open', v_already_open,
    'report', jsonb_build_object(
      'id', v_report.id,
      'status', v_report.status,
      'reason', v_report.reason,
      'created_at', v_report.created_at
    )
  );
end;
$$;

revoke execute on function submit_report(
  uuid, report_subject, uuid, uuid, uuid, report_reason, text, uuid, text,
  text, int, int, int
) from public, anon, authenticated, service_role;
grant execute on function submit_report(
  uuid, report_subject, uuid, uuid, uuid, report_reason, text, uuid, text,
  text, int, int, int
) to service_role;
