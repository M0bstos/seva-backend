begin;
create extension if not exists pgtap with schema extensions;
select plan(19);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222'),
  ('33333333-3333-3333-3333-333333333333');

insert into profiles (id, display_name, status) values
  ('11111111-1111-1111-1111-111111111111', 'anand', 'active'),
  ('22222222-2222-2222-2222-222222222222', 'bina', 'active'),
  ('33333333-3333-3333-3333-333333333333', 'chandra', 'suspended');

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.profiles'::regclass and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('authenticated', 'public.profiles', a.attname, 'update')
       and a.attname not in ('display_name', 'bio') $$,
  'authenticated may update only display_name and bio, whatever columns exist'
);

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.profiles'::regclass and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'public.profiles', a.attname, 'update')
       and a.attname not in ('avatar_path', 'text_hidden') $$,
  'the backend may update only avatar_path and text_hidden (§17 `O14`), so verification and status stay earned'
);

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.profiles'::regclass and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'public.profiles', a.attname, 'insert')
       and a.attname not in ('id', 'display_name') $$,
  'the backend may insert only id and display_name, so verification cannot be minted at onboarding'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select results_eq(
  $$ select display_name from profiles where id = '22222222-2222-2222-2222-222222222222' $$,
  $$ values ('bina'::text) $$,
  'a signed-in user reads an active profile'
);

select is_empty(
  $$ select 1 from profiles where id = '33333333-3333-3333-3333-333333333333' $$,
  'a suspended profile is not readable'
);

select lives_ok(
  $$ update profiles set display_name = 'anand v', bio = 'planting trees'
     where id = '11111111-1111-1111-1111-111111111111' $$,
  'a signed-in user updates their own display name and bio'
);

select results_eq(
  $$ select display_name, bio from profiles
     where id = '11111111-1111-1111-1111-111111111111' $$,
  $$ values ('anand v'::text, 'planting trees'::text) $$,
  'the update to their own row took effect'
);

select lives_ok(
  $$ update profiles set display_name = 'hacked'
     where id = '22222222-2222-2222-2222-222222222222' $$,
  'updating someone else is filtered by the policy rather than refused'
);

select results_eq(
  $$ select display_name from profiles where id = '22222222-2222-2222-2222-222222222222' $$,
  $$ values ('bina'::text) $$,
  'the other profile is unchanged'
);

select throws_ok(
  $$ update profiles set avatar_path = 'forged.jpg'
     where id = '11111111-1111-1111-1111-111111111111' $$,
  '42501',
  null,
  'avatar_path has no client write path'
);

select throws_ok(
  $$ update profiles set is_verified = true
     where id = '11111111-1111-1111-1111-111111111111' $$,
  '42501',
  null,
  'is_verified has no client write path'
);

select throws_ok(
  $$ update profiles set status = 'active', suspended_until = null
     where id = '33333333-3333-3333-3333-333333333333' $$,
  '42501',
  null,
  'a suspension cannot be lifted by a client'
);

select throws_ok(
  $$ insert into profiles (id, display_name)
     values ('44444444-4444-4444-4444-444444444444', 'forged') $$,
  '42501',
  null,
  'profiles are created by the onboarding function, not by clients'
);

select throws_ok(
  $$ delete from profiles where id = '11111111-1111-1111-1111-111111111111' $$,
  '42501',
  null,
  'clients never delete a profile'
);

reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}';

-- §17 `O15`, decided during the build: a suspended person reads their own row, so an
-- app can tell them they are suspended and until when. `O33` already stops them
-- writing. This assertion used to read the other way, before `O15` was settled.
select results_eq(
  $$ select status::text from profiles
     where id = '33333333-3333-3333-3333-333333333333' $$,
  $$ values ('suspended') $$,
  'a suspended account reads its own profile, which is how it learns it is suspended'
);

-- `O33` stops a suspended account writing; nothing in §10.2 or §7.3 stops it
-- reading, and the assertion above would also pass if reading were broken outright.
select isnt(
  (select display_name from profiles where id = '11111111-1111-1111-1111-111111111111'),
  null,
  'and still reads an active profile, so suspension is not a read lockout'
);

reset role;
insert into auth.users (id) values ('44444444-4444-4444-4444-444444444444');
set local role service_role;

select lives_ok(
  $$ insert into profiles (id, display_name)
     values ('44444444-4444-4444-4444-444444444444', 'devi') $$,
  'the onboarding function can create a profile'
);

select lives_ok(
  $$ update profiles set avatar_path = 'avatars/devi.jpg'
     where id = '44444444-4444-4444-4444-444444444444' $$,
  'the moderation worker can set avatar_path'
);

-- Scoped to this file's own fixtures. §13.1's rule — "a pgTAP assertion is scoped to
-- the fixtures its own file inserted, never to a whole table" — and this assertion
-- counted the table: a single row left behind by anything else running against the
-- same stack failed it, which is how it was found.
select results_eq(
  $$ select count(*)::int from profiles
     where id in ('11111111-1111-1111-1111-111111111111',
                  '22222222-2222-2222-2222-222222222222',
                  '33333333-3333-3333-3333-333333333333',
                  '44444444-4444-4444-4444-444444444444') $$,
  $$ values (4) $$,
  'the backend reads every profile it was given, including a suspended one'
);

reset role;
select * from finish();
rollback;
