create table private.preserved_content (
  id uuid primary key default gen_random_uuid(),
  source_kind text not null,
  source_id uuid not null,
  snapshot jsonb not null,
  file_paths text[],
  purge_after timestamptz not null default now() + interval '180 days',
  created_at timestamptz not null default now()
);

create index preserved_content_purge_after
  on private.preserved_content (purge_after);

revoke all on table private.preserved_content from public, anon, authenticated, service_role;

alter table private.preserved_content enable row level security;
