-- §11.2's consent record lives only in profile_private, which cascades away on
-- erasure. Nullable: an account deleted before onboarding accepted no policy (O23).
alter table private.retained_registrations
  add column terms_version text,
  add column privacy_version text,
  add column accepted_at timestamptz;
