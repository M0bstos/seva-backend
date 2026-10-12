-- §10.2 gives a moderator "suspend accounts for up to 7 days", and until this function a
-- suspension never ended. Found in review, and the gap was hidden by a comment of mine that
-- claimed otherwise: `admin_suspend_user` says "the operations worker clears an expired one on
-- its own schedule", and no such sweep existed. Every write function enforces suspension as
-- `profiles.status <> 'active'` and nothing anywhere compared `suspended_until` to `now()`, so a
-- 7-day suspension was indefinite in effect — and the only way back was a staff member calling
-- `admin_suspend_user` with a past timestamp, which is the door the §10.1 bypass walked through.
--
-- `security definer`, because §9.2 gives no client role an update on `profiles.status` and the
-- worker's `service_role` is a client role for this purpose. Owned by the table's owner, pinned
-- `search_path`, no arguments, no dynamic SQL — nothing for a caller to widen.
--
-- No audit row. §10's audit log records what a *person* did, and this is a clock running out:
-- the decision is already in the log, written by `admin_suspend_user` with the end date in
-- `after`, so the expiry adds nothing a reader cannot derive. The count comes back instead, which
-- is what the worker logs (§9.8 allows a count).
--
-- Indefinite suspensions are untouched: `suspended_until is null` is what §10.1 reserves to an
-- admin, and a sweep that lifted those would undo an admin's decision on a timer — the same
-- property the §10.1 bypass fix is about.
create function clear_expired_suspensions() returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cleared int;
begin
  with lifted as (
    update public.profiles
    set status = 'active', suspended_until = null
    where status = 'suspended'
      and suspended_until is not null
      and suspended_until <= now()
    returning 1
  )
  select count(*) into v_cleared from lifted;

  return jsonb_build_object('cleared', v_cleared);
end;
$$;

revoke execute on function clear_expired_suspensions()
  from public, anon, authenticated, service_role;
-- The operations worker's maintenance pass, beside §8.1's sweep and §11.6's purges.
grant execute on function clear_expired_suspensions() to service_role;

-- The index this function needs, in the function's own migration rather than the table's because
-- that one is applied and because it exists for nothing else — the two would be reverted together.
-- Measured without it: `Seq Scan on profiles` with the predicate as a filter, so every maintenance
-- pass scanned the whole profile table to find a handful of expired rows, and the cost grew with
-- the user table rather than with the suspension list (CLAUDE.md asks for indexed queries; §5.5 is
-- "indexes that matter"). Partial, so it holds only suspended rows with an end date and stays close
-- to empty.
create index profiles_suspension_expiry
  on public.profiles (suspended_until)
  where status = 'suspended' and suspended_until is not null;
