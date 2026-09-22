create table private.retained_registrations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  phone text,
  email text,
  account_created_at timestamptz not null,
  deleted_at timestamptz not null default now(),
  purge_after timestamptz not null default now() + interval '180 days',
  created_at timestamptz not null default now()
);

create index retained_registrations_purge_after
  on private.retained_registrations (purge_after);

revoke all on table private.retained_registrations
  from public, anon, authenticated, service_role;

alter table private.retained_registrations enable row level security;
