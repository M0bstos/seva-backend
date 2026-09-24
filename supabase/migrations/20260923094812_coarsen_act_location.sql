-- §5.4: an Act's location is snapped to a roughly 5 km grid before it is stored, the
-- same grid for every author. The raw point is never stored, so the snap happens
-- before insert and the column the create function writes is the coarse one already.
--
-- One grid, not two (§17 O29). An earlier draft followed §5.4's original wording and
-- used 0.01° for adults and 0.05° for authors under 18. Because 0.05 is an exact
-- multiple of 0.01, every minor's point landed on the 5 km lattice while only 4.2% of
-- adults did — and `authenticated` can read this column over the Data API (§7.2), so
-- one query returned a list of the child authors §9.6 exists to protect. Picking
-- non-nested grid sizes makes it worse rather than better: the coarse lattice then
-- leaves the fine one and identifies a minor outright. A single grid has no second
-- resolution to detect, which is why the owner chose it.
--
-- 0.05° is about 5.5 km of latitude and about 5.3 km of longitude at Pune, 4.6 km at
-- Srinagar. §5.4 asks for "roughly", and a degree grid keeps the snap a pure function
-- of the point — no date of birth is read, so §9.8's date-of-birth entry stays
-- unreachable from this path.
--
-- An Activity's meeting point is deliberately untouched: §5.4 stores it exactly,
-- because it is a public event.
create function coarsen_act_location() returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.location_coarse := extensions.st_snaptogrid(
    new.location_coarse::extensions.geometry, 0.05
  )::extensions.geography;
  return new;
end;
$$;

-- §9.1: a trigger function in public that PUBLIC can execute would fail gate 3.
-- Firing a trigger checks no execute privilege, so nothing is granted back.
revoke execute on function coarsen_act_location() from public, anon, authenticated, service_role;

create trigger acts_coarsen_location
  before insert on acts
  for each row execute function coarsen_act_location();
