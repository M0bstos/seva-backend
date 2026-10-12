-- What onboarding tells a client about the account it just created, in one place because
-- the function answers with it on three paths — a new profile, a repeat call, and two
-- calls racing. Three fields and no more: §7.2 lets a signed-in person read their whole
-- `profiles` row over the Data API, so this exists to confirm the gate is open rather than
-- to be the client's copy of the profile.
create function private.profile_answer(p_profile public.profiles) returns jsonb
language sql
security invoker
-- `stable` and not `immutable`: `jsonb_build_object` is itself stable, so a function built on
-- it cannot be immutable however simple it looks.
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_profile.id,
    'display_name', p_profile.display_name,
    'status', p_profile.status
  );
$$;

revoke execute on function private.profile_answer(public.profiles)
  from public, anon, authenticated, service_role;
grant execute on function private.profile_answer(public.profiles) to service_role;

-- §7.3 `POST /account/onboarding`: "Records date of birth, display name, accepted policy
-- versions | Signed in | once". §5.4 fixes both halves of how it works:
--
--   "**Onboarding gate:** phone, Google and Apple sign-ins don't provide a date of birth.
--   The onboarding function creates the `profiles` and `profile_private` rows together, so
--   **having a profile row is the gate**: every write function returns
--   `ONBOARDING_REQUIRED` until one exists. There is no `onboarded_at` column."
--
-- So "once" is not a counter and this function takes no limit arguments — §17.1 records
-- that decision and why: "every window the limiter holds resets, and the purge clears them,
-- so no argument to `private.check_rate_limit` can express a lifetime cap". The profile row
-- existing is the cap, and a second call is answered by the row that already exists.
--
-- **13+ is checked here**, which §5.2.1 says in as many words beside the column: "date_of_birth
-- date not null — 13+ checked in the onboarding function". `D9` is the rule ("Age | 13+")
-- and §9.6 is what rests on the date being real.
--
-- The two rows are written in one statement each inside one transaction, which is what
-- makes §5.4's gate sound: a `profiles` row without its `profile_private` row would pass
-- every write function's gate while §9.6's age checks read nothing.
--
-- `security invoker`: §5.2 grants `service_role` `insert (id, display_name)` on `profiles`
-- and `insert (user_id, date_of_birth, terms_version, privacy_version)` on
-- `profile_private` — exactly the columns this writes, and §5.2 names the onboarding
-- function as that table's only writer.
create function onboard_account(
  p_user_id uuid,
  p_display_name text,
  p_date_of_birth date,
  p_terms_version text,
  p_privacy_version text
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_profile public.profiles%rowtype;
begin
  -- §10.2's `read_only` is the only switch that reaches here: §5.3 has none for signing up,
  -- and onboarding is a write.
  if exists (select 1 from public.app_flags where key = 'read_only' and engaged) then
    return jsonb_build_object('error', 'FEATURE_DISABLED');
  end if;

  -- §5.4's gate, read from the other side: this is the one function for which an existing
  -- profile row is the refusal rather than the requirement. Answered with the row rather
  -- than an error, so a client whose network dropped the first response is not left unable
  -- to continue — the same reasoning §17.1 gives `POST /uploads/:id/complete`, and for the
  -- same reason: §5.2.1 gives neither table an `idempotency_key`, because the resource is
  -- the caller's own account and a repeat cannot create a second one.
  select * into v_profile from public.profiles where id = p_user_id;
  if found then
    return jsonb_build_object('onboarded', false, 'profile', private.profile_answer(v_profile));
  end if;

  -- §D9 and §5.2.1: 13+, on the `Asia/Kolkata` day §5.1 uses for anything day-based, and
  -- computed the same way `create_activity` computes its 18+ so the two cannot drift.
  --
  -- §9.8 and §17.1: the refusal must not be logged against a user id, because "an
  -- age-band disclosure" is what §9.6 exists to protect. Nothing here logs, and the route
  -- answers the code without writing it anywhere.
  if p_date_of_birth is null
     or p_date_of_birth > ((now() at time zone 'Asia/Kolkata')::date - interval '13 years')::date
  then
    return jsonb_build_object('error', 'AGE_RESTRICTED');
  end if;

  -- A date of birth in the past, which the check above does not imply: a date far enough
  -- back to be impossible is a typo rather than a person, and §5.2.1 puts no bound on the
  -- column. 150 years is the loosest bound that is still a bound.
  if p_date_of_birth < ((now() at time zone 'Asia/Kolkata')::date - interval '150 years')::date
  then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'date_of_birth');
  end if;

  begin
    insert into public.profiles (id, display_name) values (p_user_id, p_display_name)
    returning * into v_profile;

    insert into public.profile_private (
      user_id, date_of_birth, terms_version, privacy_version
    ) values (
      p_user_id, p_date_of_birth, p_terms_version, p_privacy_version
    );
  exception
    when check_violation then
      -- §5.2.1 bounds `display_name` 2–50 and requires both policy versions to look like
      -- `^\d{4}-\d{2}-\d{2}$`. The route checks all three so §7.4's message can name one;
      -- this is the backstop that keeps a body slipping past it out of a retryable
      -- INTERNAL whose DETAIL carries the date of birth into the log (§9.8).
      return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'profile');
    when foreign_key_violation then
      -- §5.2.1 points `profiles.id` at `auth.users`. The id comes from a verified token
      -- (§9.2), so this is reachable only if the account was deleted mid-request.
      return jsonb_build_object('error', 'NOT_FOUND');
    when unique_violation then
      -- Two onboarding calls racing: the second waits on the primary key and then takes
      -- the same path as a repeat, which is the row that now exists.
      select * into v_profile from public.profiles where id = p_user_id;
      return jsonb_build_object(
        'onboarded', false, 'profile', private.profile_answer(v_profile)
      );
  end;

  return jsonb_build_object('onboarded', true, 'profile', private.profile_answer(v_profile));
end;
$$;

revoke execute on function onboard_account(uuid, text, date, text, text)
  from public, anon, authenticated, service_role;
grant execute on function onboard_account(uuid, text, date, text, text) to service_role;
