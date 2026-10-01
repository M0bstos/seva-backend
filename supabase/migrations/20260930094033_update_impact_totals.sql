-- §6.1: "Triggers on the ledger update `impact_totals` and the campaign's
-- `progress_value` in the same transaction." This is the first of those two, and the
-- second of §5.4's three counters.
--
-- Insert and delete only, because §5.4 says the ledger "is never updated, only
-- inserted and deleted" — "that is enforced through grants rather than a blocking
-- trigger, because account deletion has to null those two columns". So the `set null`
-- the foreign keys perform is an update this trigger deliberately does not see: by
-- then §5.4 has already deleted the profile, and `impact_totals` cascaded with it.
--
-- §6.2 is the delete half: "When staff remove an Act, its ledger rows are deleted and
-- the totals triggers subtract them." One trigger, both directions, so a reversal can
-- never disagree with the award it reverses.
--
-- `security definer` (§17.1), like the other two counters: §9.2 gives points no client
-- write path and `impact_totals` grants `service_role` `select` alone.
create function update_impact_totals() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.impact_entries%rowtype;
  v_sign int;
begin
  if tg_op = 'INSERT' then
    v_row := new;
    v_sign := 1;
  else
    v_row := old;
    v_sign := -1;
  end if;

  -- A row whose author has been deleted (§5.4 nulls `user_id`) has no total to move.
  -- It stays on the ledger so campaign progress keeps counting it.
  if v_row.user_id is null then
    return null;
  end if;

  -- §6.1 awards on publication, so the first row an author earns is also the first
  -- time they need a totals row. Made first and moved second, rather than as one
  -- upsert carrying the delta: **measured on the local stack, 30 September 2026**,
  -- `on conflict do update` evaluates the proposed row's check constraints *before*
  -- the conflict is detected, so a delta of -15 against §5.2.1's `points >= 0` raises
  -- 23514 even though the update path would have been taken. Every reversal §6.2 asks
  -- for carries a negative delta, so the upsert form could only ever have worked in
  -- one direction.
  insert into public.impact_totals (user_id)
  values (v_row.user_id)
  on conflict (user_id) do nothing;

  update public.impact_totals set
    points = points + v_sign * v_row.points,
    acts_count = acts_count
      + case when v_row.kind = 'act_published' then v_sign else 0 end,
    trees_planted = trees_planted
      + case when v_row.metric = 'trees_planted' then v_sign * v_row.value else 0 end,
    animals_helped = animals_helped
      + case when v_row.metric = 'animals_helped' then v_sign * v_row.value else 0 end,
    people_reached = people_reached
      + case when v_row.metric = 'people_reached' then v_sign * v_row.value else 0 end,
    waste_kg = waste_kg
      + case when v_row.metric = 'waste_kg' then v_sign * v_row.value else 0 end,
    volunteer_hours = volunteer_hours
      + case when v_row.metric = 'volunteer_hours' then v_sign * v_row.value else 0 end
  where user_id = v_row.user_id;

  return null;
end;
$$;

revoke execute on function update_impact_totals()
  from public, anon, authenticated, service_role;

create trigger impact_entries_update_totals
  after insert or delete on impact_entries
  for each row execute function update_impact_totals();
