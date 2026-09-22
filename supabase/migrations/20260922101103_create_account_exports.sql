create table account_exports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles (id) on delete cascade,
  status export_status not null default 'pending',
  file_path text,
  ready_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz not null default now()
);

revoke all on table account_exports from public, anon, authenticated, service_role;

grant select on table account_exports to authenticated;
grant select on table account_exports to service_role;
grant insert (user_id) on table account_exports to service_role;
grant update (status, file_path, ready_at, expires_at) on table account_exports to service_role;

alter table account_exports enable row level security;

create policy account_exports_select on account_exports
  for select to authenticated
  using (user_id = (select auth.uid()));
