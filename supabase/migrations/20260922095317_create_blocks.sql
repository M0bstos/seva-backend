create table blocks (
  blocker_id uuid not null references profiles (id) on delete cascade,
  blocked_id uuid not null references profiles (id) on delete cascade,
  primary key (blocker_id, blocked_id),
  constraint blocks_no_self_block check (blocker_id <> blocked_id)
);

revoke all on table blocks from public, anon, authenticated, service_role;

grant select, insert, delete on table blocks to authenticated;
grant select on table blocks to service_role;

alter table blocks enable row level security;

create policy blocks_select on blocks
  for select to authenticated
  using (blocker_id = (select auth.uid()));

create policy blocks_insert on blocks
  for insert to authenticated
  with check (blocker_id = (select auth.uid()));

create policy blocks_delete on blocks
  for delete to authenticated
  using (blocker_id = (select auth.uid()));
