-- A roll-forward of `admin_suspend_user`, replacing the admin-only precondition. §13.3 forbids
-- editing an applied migration, so the whole body is restated; nothing else in it changes.
--
-- §10.2: "`admin_suspend_user` | Moderator ≤ 7 days · Admin any | Suspends an account and
-- queues a sign-out through the operations worker." The sign-out is a job because §12.4
-- notes an access token lasts an hour and nothing in Auth reads `profiles.status`, so
-- `O33`'s write refusal alone would leave a suspended person's existing session working —
-- and revoking it needs the Auth admin API, which §5.4 says SQL cannot reach.
--
-- **`p_until` carries all three cases §10.1 and §10.2 describe between them**, and the
-- third is the one neither section names. A **null** is the indefinite suspension §10.1
-- gives an admin alone. A timestamp in the **future** is a bounded one, which a moderator
-- may set up to 7 days out. A timestamp **at or before now** lifts it — which §10.2 lists
-- no function for, and which something has to do: §5.2.1's `suspended_until` is a date the
-- schema records and nothing else reads, so without a way back an account suspended for
-- 7 days would stay suspended for ever. `clear_expired_suspensions` is what clears an expired
-- one, on the operations worker's maintenance pass — **built on 7 October 2026, when review
-- found this sentence describing a sweep that did not exist.** Until then a 7-day suspension
-- was indefinite in effect, and a staff member calling this function with a past timestamp was
-- the only way back. This remains that path, for a moderator who wants it back sooner, or who
-- suspended the wrong person.
--
-- **Decided during the build, 5 October 2026: lifting an indefinite suspension needs an admin**,
-- and **amended 15 October 2026 to any suspension a moderator could not have imposed** — the
-- original rule read the ceiling as a null, which left an admin's bounded year undefended. It is
-- §8.2's argument about one boolean, applied here: a moderator who could undo an admin's decision
-- would make §10.1's split meaningless. Lifting a suspension inside §10.2's seven days is lighter
-- than imposing it, so any moderator may.
--
-- `security definer`: §9.2 gives `profiles.status` no client write path at all, and §5.2
-- grants `service_role` nothing on it either.
create or replace function admin_suspend_user(
  p_user_id uuid,
  p_until timestamptz,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff uuid;
  v_actor_role public.staff_role;
  v_target_role public.staff_role;
  v_profile public.profiles%rowtype;
  v_lifting boolean;
  v_indefinite boolean;
  -- The account as it already stands, measured against the same ceiling §10.2 gives a
  -- moderator for imposing one. See the branch below for why it is a duration and not a null.
  v_existing_beyond_reach boolean;
begin
  -- §10.1's floor. The ceiling each case needs is checked below, once the case is known.
  v_staff := private.staff_actor('moderator');
  if v_staff is null then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  if char_length(coalesce(p_reason, '')) not between 3 and 500 then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'reason');
  end if;

  -- **Nobody suspends themselves**, which is `admin_set_staff`'s check for the same reason, in the
  -- function next door. It became necessary when `private.staff_actor` started requiring an active
  -- account: review measured that a sole admin suspending themselves indefinitely was then locked
  -- out of every route back — `admin_suspend_user` and `admin_set_staff` both answer `FORBIDDEN`
  -- because they are no longer staff, and `clear_expired_suspensions` skips an indefinite one by
  -- design. Recoverable only by a migration. One person acting alone, no concurrency, and terminal,
  -- which is what separates it from the zero-admins race §17.1 records as a residual instead.
  if p_user_id = v_staff then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  -- **A staff member may only suspend somebody junior to them**, and this exists because the fix
  -- that made `private.staff_actor` require an active account turned suspension into a way of
  -- stripping a role. Review measured the consequence: one moderator suspended both admins for
  -- seven days — allowed, bounded, inside §10.2's moderator ceiling — and the admins were then
  -- refused everything, including demoting the rogue and lifting each other's suspensions, while
  -- the rogue kept every moderator power and could re-suspend them each time
  -- `clear_expired_suspensions` let them out. A single moderator removing the whole admin tier,
  -- recoverable only by a migration from the ops host. It is §10.1's tiering violated one level up
  -- from the bypass above, and the self-check cannot see it: that tests `p_user_id = v_staff`,
  -- where this needs the target's *role*.
  --
  -- Strictly junior rather than "at least equal", so a moderator cannot suspend a fellow moderator
  -- either. Lateral is recoverable — an admin outranks both — but §10.1's roles are a hierarchy and
  -- a rule a §10.3 screen can state in one sentence is worth more than the narrowest possible one.
  -- A rogue *admin* is handled by the path §10.2 already provides: another admin demotes them with
  -- `admin_set_staff`, which leaves its own audit row, and suspends them afterwards.
  select role into v_target_role from public.staff where user_id = p_user_id;
  if v_target_role is not null then
    select role into v_actor_role from public.staff where user_id = v_staff;
    if v_actor_role <= v_target_role then
      return jsonb_build_object('error', 'FORBIDDEN');
    end if;
  end if;

  -- Locked before the status is read: two moderators acting on one account would
  -- otherwise each record a change from a value the other had already moved, and the
  -- admin check below reads that value.
  select * into v_profile from public.profiles where id = p_user_id for update;
  if not found then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  v_lifting := p_until is not null and p_until <= now();
  v_indefinite := p_until is null;

  -- §10.1: "Admin | … suspend indefinitely", and the same role to undo one.
  --
  -- **Any call against a suspension a moderator could not have imposed needs an admin**, and
  -- what makes one unreachable is its remaining *duration*, not a null `suspended_until`. Two
  -- bypasses were reproduced around weaker forms of this precondition, three days apart:
  --
  --   * 7 October 2026, `v_lifting and suspended_until is null`: the direct lift was refused, so
  --     a moderator called with `p_until = now() + 1 second` — neither indefinite nor a lift, and
  --     inside §10.2's 7 days, so allowed — and that write made the admin-only branch stop
  --     matching. A second call lifted it.
  --   * 15 October 2026, `suspended_until is null`: an admin's **bounded** suspension of a year
  --     was unprotected in one call, because a year out is not null. A moderator who is refused
  --     `now() + 365 days` when imposing it could lift the same ban outright with
  --     `p_until = now() - 1 second`, or shorten it to a minute — the ceiling check below is
  --     gated on `not v_lifting`, so a lift skips it entirely, and a shortening is inside the
  --     seven days. Two truthful audit rows either way.
  --
  -- Both are the same mistake and §17.1 records its lesson on the first: a guard that reads a
  -- column the same function lets the caller change is not a guard — and nullness is not the
  -- column's reach.
  --
  -- **The reach is time remaining, which means a long suspension decays into a moderator's reach
  -- as it runs down**: on day 359 of a year, fewer than seven days remain and any moderator may
  -- lift it. Deliberate and symmetric as far as it goes — at that point it is a suspension a
  -- moderator could have imposed themselves — but it is a *second* decision, and §10.1 and §10.2
  -- are both written about imposing, so neither settles it. `O53` carries it: what the schema
  -- cannot be asked is who imposed the suspension, since §5.2.1 records `suspended_until` and not
  -- the actor, so keying the protection on an admin's authorship instead would need the audit log
  -- or a column. Until the owner rules, time remaining is the reading, and the two assertions
  -- either side of the ceiling in the rpc test are what pin it.
  v_existing_beyond_reach := v_profile.status = 'suspended'
    and (v_profile.suspended_until is null
         or v_profile.suspended_until > now() + interval '7 days');

  if (v_indefinite or v_existing_beyond_reach) and private.staff_actor('admin') is null then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  -- §10.2: "Moderator ≤ 7 days". Only the ceiling is a role question; a shorter one is
  -- any moderator's. Still load-bearing with the branch above in place, and distinguishably so:
  -- this is the only thing that refuses a long suspension of an account that is currently
  -- *active*, where nothing about the existing state is out of reach.
  if not v_lifting and not v_indefinite
     and p_until > now() + interval '7 days'
     and private.staff_actor('admin') is null
  then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  -- §5.2.1's check pairs the two columns: "suspended_until only when suspended".
  update public.profiles
  set status = case when v_lifting then 'active' else 'suspended' end::public.account_status,
      suspended_until = case when v_lifting then null else p_until end
  where id = p_user_id;

  -- §9.8: the row carries the status and the date, never the person's name, and a date of
  -- suspension is not a date of birth.
  insert into public.admin_audit_log (
    actor, staff_id, action, subject_type, subject_id, reason, before, after
  ) values (
    'staff', v_staff, 'suspend_user', 'profile', p_user_id, p_reason,
    jsonb_build_object('status', v_profile.status, 'until', v_profile.suspended_until),
    jsonb_build_object(
      'status', case when v_lifting then 'active' else 'suspended' end,
      'until', case when v_lifting then null else p_until end
    )
  );

  -- §10.2's second half. Not on a lift: there is no session to revoke, and signing
  -- somebody out as a reward for being reinstated is not what that row asks for.
  if not v_lifting then
    perform pgmq.send('ops', jsonb_build_object(
      'kind', 'sign_out',
      'user_id', p_user_id
    ));
  end if;

  return jsonb_build_object(
    'status', case when v_lifting then 'active' else 'suspended' end,
    'suspended_until', case when v_lifting then null else p_until end
  );
end;
$$;

revoke execute on function admin_suspend_user(uuid, timestamptz, text)
  from public, anon, authenticated, service_role;
grant execute on function admin_suspend_user(uuid, timestamptz, text)
  to authenticated;
