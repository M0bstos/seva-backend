create table impact_totals (
  user_id uuid primary key references profiles (id) on delete cascade,
  points int not null default 0 check (points >= 0),
  acts_count int not null default 0 check (acts_count >= 0),
  activities_joined int not null default 0 check (activities_joined >= 0),
  trees_planted int not null default 0 check (trees_planted >= 0),
  animals_helped int not null default 0 check (animals_helped >= 0),
  people_reached int not null default 0 check (people_reached >= 0),
  waste_kg numeric(12,2) not null default 0 check (waste_kg >= 0),
  volunteer_hours numeric(12,2) not null default 0 check (volunteer_hours >= 0)
);

revoke all on table impact_totals from public, anon, authenticated, service_role;

grant select on table impact_totals to authenticated;
grant select on table impact_totals to service_role;

alter table impact_totals enable row level security;

create policy impact_totals_select on impact_totals
  for select to authenticated
  using (user_id = (select auth.uid()));
