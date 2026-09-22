create table campaigns (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 5 and 100),
  description text not null check (char_length(description) <= 2000),
  goal_metric campaign_goal not null,
  goal_value numeric(12,2) not null check (goal_value > 0),
  progress_value numeric(12,2) not null default 0 check (progress_value >= 0),
  starts_on date not null,
  ends_on date not null,
  status campaign_status not null default 'draft',
  created_at timestamptz not null default now(),
  constraint campaigns_ends_on_after_starts_on check (ends_on >= starts_on)
);

revoke all on table campaigns from public, anon, authenticated, service_role;

grant select on table campaigns to authenticated;
grant select on table campaigns to service_role;

alter table campaigns enable row level security;

create policy campaigns_select on campaigns
  for select to authenticated
  using (status = 'active');
