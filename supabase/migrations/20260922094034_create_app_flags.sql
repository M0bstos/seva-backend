create table app_flags (
  key app_flag primary key,
  engaged boolean not null default false,
  updated_by uuid
);

revoke all on table app_flags from public, anon, authenticated, service_role;

grant select on table app_flags to authenticated;
grant select on table app_flags to service_role;

alter table app_flags enable row level security;

create policy app_flags_select on app_flags
  for select to authenticated
  using (true);

insert into app_flags (key) values
  ('uploads'), ('create_acts'), ('create_activities'),
  ('joins'), ('award_points'), ('read_only');
