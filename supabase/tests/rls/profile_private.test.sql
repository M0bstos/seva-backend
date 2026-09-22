begin;
create extension if not exists pgtap with schema extensions;
select plan(18);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');

insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'anand'),
  ('22222222-2222-2222-2222-222222222222', 'bina');

insert into profile_private (user_id, date_of_birth, terms_version, privacy_version) values
  ('11111111-1111-1111-1111-111111111111', '1998-04-02', '2026-10-01', '2026-10-01'),
  ('22222222-2222-2222-2222-222222222222', '2011-06-15', '2026-10-01', '2026-10-01');

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.profile_private'::regclass
       and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('authenticated', 'public.profile_private', a.attname, 'update')
       and a.attname not in ('locale', 'email_opt_in') $$,
  'authenticated may update only locale and email_opt_in, whatever columns exist'
);

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.profile_private'::regclass
       and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'public.profile_private', a.attname, 'insert')
       and a.attname not in
         ('user_id', 'date_of_birth', 'terms_version', 'privacy_version') $$,
  'the backend inserts only what onboarding records, so guardian consent cannot be minted'
);

select ok(
  not has_table_privilege('service_role', 'profile_private',
    'UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('service_role', 'public.profile_private', 'UPDATE'),
  'the backend never updates the private record; deletion cascades from profiles'
);

select results_eq(
  $$ select guardian_consent::text, email_opt_in from profile_private
     where user_id = '11111111-1111-1111-1111-111111111111' $$,
  $$ values ('not_required'::text, true) $$,
  'a new private record defaults to not_required, which O3 pins as a legal decision'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select results_eq(
  $$ select date_of_birth from profile_private $$,
  $$ values ('1998-04-02'::date) $$,
  'a signed-in user reads only their own private record'
);

select is_empty(
  $$ select 1 from profile_private
     where user_id = '22222222-2222-2222-2222-222222222222' $$,
  'nobody reads another person''s date of birth'
);

select lives_ok(
  $$ update profile_private set locale = 'hi-IN', email_opt_in = false
     where user_id = '11111111-1111-1111-1111-111111111111' $$,
  'a signed-in user updates their own locale and email preference'
);

select results_eq(
  $$ select locale, email_opt_in from profile_private
     where user_id = '11111111-1111-1111-1111-111111111111' $$,
  $$ values ('hi-IN'::text, false) $$,
  'the preference update took effect'
);

select lives_ok(
  $$ update profile_private set locale = 'ta-IN'
     where user_id = '22222222-2222-2222-2222-222222222222' $$,
  'updating someone else is filtered by the policy rather than refused'
);

select throws_ok(
  $$ update profile_private set date_of_birth = '2000-01-01'
     where user_id = '11111111-1111-1111-1111-111111111111' $$,
  '42501',
  null,
  'date of birth has no client write path, so age cannot be edited'
);

select throws_ok(
  $$ update profile_private set guardian_consent = 'granted'
     where user_id = '11111111-1111-1111-1111-111111111111' $$,
  '42501',
  null,
  'guardian consent has no client write path'
);

select throws_ok(
  $$ insert into profile_private (user_id, date_of_birth, terms_version, privacy_version)
     values ('22222222-2222-2222-2222-222222222222', '1990-01-01', '2026-10-01', '2026-10-01') $$,
  '42501',
  null,
  'the private record is created by the onboarding function, not by clients'
);

select throws_ok(
  $$ delete from profile_private
     where user_id = '11111111-1111-1111-1111-111111111111' $$,
  '42501',
  null,
  'clients never delete the private record'
);

reset role;

select results_eq(
  $$ select locale from profile_private
     where user_id = '22222222-2222-2222-2222-222222222222' $$,
  $$ values ('en-IN'::text) $$,
  'the other private record was left untouched'
);

insert into auth.users (id) values ('33333333-3333-3333-3333-333333333333');
set local role service_role;

select lives_ok(
  $$ insert into profiles (id, display_name)
     values ('33333333-3333-3333-3333-333333333333', 'chandra');
     insert into profile_private (user_id, date_of_birth, terms_version, privacy_version)
     values ('33333333-3333-3333-3333-333333333333', '2005-02-11', '2026-10-01', '2026-10-01') $$,
  'the onboarding function creates the profile and the private record together'
);

select results_eq(
  $$ select date_of_birth from profile_private
     where user_id = '33333333-3333-3333-3333-333333333333' $$,
  $$ values ('2005-02-11'::date) $$,
  'the backend can read a date of birth, which every age rule in 9.6 depends on'
);

reset role;

select lives_ok(
  $$ delete from profiles where id = '33333333-3333-3333-3333-333333333333' $$,
  'deleting a profile is allowed and takes the private record with it'
);

select is_empty(
  $$ select 1 from profile_private
     where user_id = '33333333-3333-3333-3333-333333333333' $$,
  'the private record cascades away with the profile, so erasure needs no delete grant'
);

select * from finish();
rollback;
