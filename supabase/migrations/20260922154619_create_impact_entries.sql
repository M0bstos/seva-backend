create table impact_entries (
  id bigint generated always as identity primary key,
  user_id uuid references profiles (id) on delete set null,
  act_id uuid references acts (id) on delete set null,
  kind ledger_kind not null,
  metric metric,
  value numeric(10,2),
  points int not null check (points >= 0),
  campaign_id uuid references campaigns (id) on delete restrict,
  location_coarse extensions.geography(point, 4326) not null,
  created_at timestamptz not null default now(),
  constraint impact_entries_metric_matches_kind check (
    num_nonnulls(metric, value) = case when kind = 'metric' then 2 else 0 end
  )
);

create index impact_entries_user_created_at on impact_entries (user_id, created_at);
create index impact_entries_act_id on impact_entries (act_id);
create index impact_entries_campaign_id on impact_entries (campaign_id);

revoke all on table impact_entries from public, anon, authenticated, service_role;
revoke all on sequence impact_entries_id_seq from public, anon, authenticated, service_role;

grant select on table impact_entries to authenticated;
grant select on table impact_entries to service_role;

alter table impact_entries enable row level security;

create policy impact_entries_select on impact_entries
  for select to authenticated
  using (user_id = (select auth.uid()));
