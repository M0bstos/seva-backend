create table supports (
  id bigint generated always as identity primary key,
  user_id uuid not null references profiles (id) on delete cascade,
  act_id uuid references acts (id) on delete cascade,
  activity_id uuid references activities (id) on delete cascade,
  constraint supports_exactly_one_target check (num_nonnulls(act_id, activity_id) = 1)
);

create unique index supports_user_act on supports (user_id, act_id) where act_id is not null;
create unique index supports_user_activity
  on supports (user_id, activity_id) where activity_id is not null;

revoke all on table supports from public, anon, authenticated, service_role;
revoke all on sequence supports_id_seq from public, anon, authenticated, service_role;

grant select, insert, delete on table supports to authenticated;
grant select on table supports to service_role;

alter table supports enable row level security;

create policy supports_select on supports
  for select to authenticated
  using (user_id = (select auth.uid()));

create policy supports_insert on supports
  for insert to authenticated
  with check (user_id = (select auth.uid()));

create policy supports_delete on supports
  for delete to authenticated
  using (user_id = (select auth.uid()));
