create table profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 2 and 50),
  bio text check (char_length(bio) <= 280),
  avatar_path text,
  text_hidden boolean not null default false,
  is_verified boolean not null default false,
  org_name text check (char_length(org_name) <= 100),
  org_type org_type,
  status account_status not null default 'active',
  suspended_until timestamptz,
  updated_at timestamptz not null default now(),
  constraint profiles_verified_needs_org
    check (not is_verified or (org_name is not null and org_type is not null)),
  constraint profiles_suspended_until_needs_suspension
    check (suspended_until is null or status = 'suspended')
);

create trigger profiles_updated_at
  before update on profiles
  for each row execute function extensions.moddatetime (updated_at);

revoke all on table profiles from public, anon, authenticated, service_role;

grant select on table profiles to authenticated;
grant update (display_name, bio) on table profiles to authenticated;
grant select on table profiles to service_role;
grant insert (id, display_name) on table profiles to service_role;
grant update (avatar_path) on table profiles to service_role;

alter table profiles enable row level security;

create policy profiles_select on profiles
  for select to authenticated
  using (status = 'active');

create policy profiles_update on profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));
