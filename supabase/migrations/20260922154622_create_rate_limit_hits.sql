create unlogged table private.rate_limit_hits (
  bucket text not null,
  window_start timestamptz not null,
  hits int not null,
  primary key (bucket, window_start)
);

revoke all on table private.rate_limit_hits from public, anon, authenticated, service_role;

grant select, insert, update on table private.rate_limit_hits to service_role;

alter table private.rate_limit_hits enable row level security;
