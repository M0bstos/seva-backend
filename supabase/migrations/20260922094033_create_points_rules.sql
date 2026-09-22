create table points_rules (
  rule text primary key check (rule in (
    'act_published', 'activity_documented', 'waste_kg', 'trees_planted',
    'volunteer_hours', 'animals_helped', 'people_reached'
  )),
  points_per_unit numeric(8,2) not null check (points_per_unit >= 0),
  max_per_act numeric(10,2),
  active boolean not null default true
);

revoke all on table points_rules from public, anon, authenticated, service_role;

grant select on table points_rules to authenticated;
grant select on table points_rules to service_role;

alter table points_rules enable row level security;

create policy points_rules_select on points_rules
  for select to authenticated
  using (true);

insert into points_rules (rule, points_per_unit, max_per_act) values
  ('act_published', 10, null),
  ('activity_documented', 10, null),
  ('waste_kg', 2, 200),
  ('trees_planted', 5, 200),
  ('volunteer_hours', 10, 12),
  ('animals_helped', 5, 50),
  ('people_reached', 1, 500);
