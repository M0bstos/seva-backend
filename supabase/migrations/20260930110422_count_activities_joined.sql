-- §5.2.1 gives `impact_totals` an `activities_joined` column and §5.4 says counters
-- are "updated by triggers in the same transaction as the change, never recomputed on
-- read". This is the only one of `impact_totals`' columns that cannot come from the
-- ledger: §6.1 is explicit that "joining an Activity earns nothing", so there is no
-- ledger row to count, and §6.1 drops a participant-count campaign goal for exactly
-- that reason.
--
-- **That costs §6.2 a clause.** "Because the ledger is the source of truth, totals
-- can always be rebuilt from it" is true of every column but this one, which rebuilds
-- from `activity_participants` instead. Recorded in §17.1 rather than fixed, because
-- the alternative — a zero-point ledger row for a join — is the farming channel §6.1
-- closes, and inventing a second ledger kind would be a scope change.
--
-- `security definer` (§17.1), like the other counters: §9.2 gives `impact_totals` no
-- client write path and `service_role` holds `select` alone. Written against `joined`
-- in both directions rather than as an else, for the reason
-- `count_activity_participants` gives: with a third `participant_status` one day, a
-- move between two non-joined values would otherwise decrement.
create function count_activities_joined() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_delta int;
begin
  if tg_op = 'INSERT' then
    v_user_id := new.user_id;
    v_delta := case when new.status = 'joined' then 1 else 0 end;
  elsif tg_op = 'UPDATE' then
    v_user_id := new.user_id;
    v_delta := case
                 when old.status is not distinct from new.status then 0
                 when new.status = 'joined' then 1
                 when old.status = 'joined' then -1
                 else 0
               end;
  else
    -- §5.4 removes participations when an account is deleted, by cascade rather than
    -- through the leave function. The totals row cascades away in the same statement,
    -- so there is nothing to decrement — but a participation can also go when the
    -- *Activity* is deleted, and then the person is still here.
    v_user_id := old.user_id;
    v_delta := case when old.status = 'joined' then -1 else 0 end;
  end if;

  if v_delta = 0 then
    return null;
  end if;

  -- Created first and moved second, for the reason `update_impact_totals` records:
  -- `on conflict do update` checks the proposed row against §5.2.1's `>= 0` before it
  -- detects the conflict, so an upsert carrying -1 raises.
  --
  -- Created only on the way up. §5.4 deletes a profile, which cascades to
  -- `activity_participants` and to `impact_totals` in the same statement — and if the
  -- participation goes first this trigger would re-create the totals row for a
  -- profile that no longer exists, raising on `impact_totals_user_id_fkey`. Measured:
  -- that is the order Postgres takes, and it broke an existing test. A decrement
  -- against a row that is not there has nothing to count anyway.
  if v_delta > 0 then
    insert into public.impact_totals (user_id)
    values (v_user_id)
    on conflict (user_id) do nothing;
  end if;

  update public.impact_totals
  set activities_joined = activities_joined + v_delta
  where user_id = v_user_id;

  return null;
end;
$$;

revoke execute on function count_activities_joined()
  from public, anon, authenticated, service_role;

create trigger activity_participants_count_joined
  after insert or update or delete on activity_participants
  for each row execute function count_activities_joined();
