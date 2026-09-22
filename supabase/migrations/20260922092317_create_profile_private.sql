create table profile_private (
  user_id uuid primary key references profiles (id) on delete cascade,
  date_of_birth date not null,
  guardian_consent guardian_consent not null default 'not_required',
  locale text not null default 'en-IN' check (locale ~ '^[a-z]{2}(-[A-Z]{2})?$'),
  email_opt_in boolean not null default true,
  terms_version text not null check (terms_version ~ '^\d{4}-\d{2}-\d{2}$'),
  privacy_version text not null check (privacy_version ~ '^\d{4}-\d{2}-\d{2}$'),
  accepted_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger profile_private_updated_at
  before update on profile_private
  for each row execute function extensions.moddatetime (updated_at);

revoke all on table profile_private from public, anon, authenticated, service_role;

grant select on table profile_private to authenticated;
grant update (locale, email_opt_in) on table profile_private to authenticated;
grant select on table profile_private to service_role;
grant insert (user_id, date_of_birth, terms_version, privacy_version)
  on table profile_private to service_role;

alter table profile_private enable row level security;

create policy profile_private_select on profile_private
  for select to authenticated
  using (user_id = (select auth.uid()));

create policy profile_private_update on profile_private
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
