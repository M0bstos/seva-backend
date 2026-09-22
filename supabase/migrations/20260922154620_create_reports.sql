create table reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references profiles (id) on delete cascade,
  subject_type report_subject not null,
  act_id uuid references acts (id) on delete set null,
  activity_id uuid references activities (id) on delete set null,
  reported_user_id uuid references profiles (id) on delete set null,
  reason report_reason not null,
  details text check (char_length(details) <= 500),
  status report_status not null default 'open',
  resolved_by uuid references profiles (id) on delete set null,
  resolved_at timestamptz,
  resolution_note text check (char_length(resolution_note) <= 500),
  idempotency_key uuid not null,
  request_hash text not null check (char_length(request_hash) = 64),
  created_at timestamptz not null default now(),
  constraint reports_at_most_one_subject
    check (num_nonnulls(act_id, activity_id, reported_user_id) <= 1),
  constraint reports_subject_matches_type check (
    (act_id is null or subject_type = 'act')
    and (activity_id is null or subject_type = 'activity')
    and (reported_user_id is null or subject_type = 'profile')
  ),
  constraint reports_resolved_at_matches_status
    check ((resolved_at is not null) = (status <> 'open')),
  constraint reports_reporter_idempotency unique (reporter_id, idempotency_key)
);

create index reports_status_created_at on reports (status, created_at);
create index reports_open_act on reports (act_id) where status = 'open';
create index reports_open_activity on reports (activity_id) where status = 'open';
create index reports_open_user on reports (reported_user_id) where status = 'open';

create unique index reports_one_open_per_act
  on reports (reporter_id, act_id) where status = 'open' and act_id is not null;
create unique index reports_one_open_per_activity
  on reports (reporter_id, activity_id) where status = 'open' and activity_id is not null;
create unique index reports_one_open_per_user
  on reports (reporter_id, reported_user_id)
  where status = 'open' and reported_user_id is not null;

revoke all on table reports from public, anon, authenticated, service_role;

grant select on table reports to service_role;
grant insert (reporter_id, subject_type, act_id, activity_id, reported_user_id,
              reason, details, idempotency_key, request_hash)
  on table reports to service_role;

alter table reports enable row level security;
