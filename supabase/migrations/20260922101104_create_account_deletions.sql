create table account_deletions (
  user_id uuid primary key,
  status deletion_status not null default 'pending',
  attempts smallint,
  requested_at timestamptz not null default now(),
  completed_at timestamptz
);

revoke all on table account_deletions from public, anon, authenticated, service_role;

grant select on table account_deletions to service_role;
grant insert (user_id) on table account_deletions to service_role;
grant update (status, attempts, completed_at) on table account_deletions to service_role;

alter table account_deletions enable row level security;
