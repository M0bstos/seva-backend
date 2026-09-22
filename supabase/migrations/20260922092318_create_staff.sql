create table staff (
  user_id uuid primary key references profiles (id) on delete restrict,
  role staff_role not null
);

revoke all on table staff from public, anon, authenticated, service_role;

alter table staff enable row level security;
