create table admin_audit_log (
  id bigint generated always as identity primary key,
  actor audit_actor not null,
  staff_id uuid,
  action text not null,
  subject_type text not null,
  subject_id uuid not null,
  reason text not null check (char_length(reason) between 3 and 500),
  before jsonb,
  after jsonb,
  created_at timestamptz not null default now(),
  constraint admin_audit_log_staff_id_matches_actor
    check ((staff_id is not null) = (actor = 'staff'))
);

revoke all on table admin_audit_log from public, anon, authenticated, service_role;
revoke all on sequence admin_audit_log_id_seq from public, anon, authenticated, service_role;

alter table admin_audit_log enable row level security;
