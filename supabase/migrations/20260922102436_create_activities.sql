create table activities (
  id uuid primary key default gen_random_uuid(),
  organiser_id uuid references profiles (id) on delete set null,
  title text not null check (char_length(title) between 5 and 100),
  description text not null check (char_length(description) between 20 and 2000),
  category category not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  location extensions.geography(point, 4326) not null,
  location_label text not null check (char_length(location_label) between 3 and 200),
  capacity int not null check (capacity between 1 and 1000),
  participant_count int not null default 0 check (participant_count >= 0),
  what_to_bring text check (char_length(what_to_bring) <= 500),
  campaign_id uuid references campaigns (id) on delete restrict,
  status content_status not null default 'pending',
  text_checked boolean not null default false,
  cancelled_at timestamptz,
  idempotency_key uuid not null,
  request_hash text not null check (char_length(request_hash) = 64),
  created_at timestamptz not null default now(),
  constraint activities_ends_after_starts check (ends_at > starts_at),
  constraint activities_at_most_24_hours
    check (ends_at <= starts_at + interval '24 hours'),
  constraint activities_within_capacity check (participant_count <= capacity),
  constraint activities_organiser_idempotency unique (organiser_id, idempotency_key)
);

create index activities_location_visible
  on activities using gist (location) where status = 'visible';

create index activities_starts_at_visible
  on activities (starts_at) where status = 'visible';

revoke all on table activities from public, anon, authenticated, service_role;

grant select on table activities to authenticated;
grant select on table activities to service_role;
grant insert (organiser_id, title, description, category, starts_at, ends_at,
              location, location_label, capacity, what_to_bring, campaign_id,
              idempotency_key, request_hash)
  on table activities to service_role;
grant update (status, text_checked, cancelled_at) on table activities to service_role;

alter table activities enable row level security;

create policy activities_select on activities
  for select to authenticated
  using (status = 'visible' or organiser_id = (select auth.uid()));
