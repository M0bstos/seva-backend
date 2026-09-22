create unlogged table private.discover_cache (
  cache_key text primary key,
  payload jsonb not null,
  expires_at timestamptz not null
);

revoke all on table private.discover_cache from public, anon, authenticated, service_role;

grant select, insert, update on table private.discover_cache to service_role;

alter table private.discover_cache enable row level security;
