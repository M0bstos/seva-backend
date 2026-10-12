begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222'),
  ('33333333-3333-3333-3333-333333333333'),
  ('44444444-4444-4444-4444-444444444444');
-- 22222222 has onboarded already; the other three have not.
insert into profiles (id, display_name) values
  ('22222222-2222-2222-2222-222222222222', 'already here');
insert into profile_private (user_id, date_of_birth, terms_version, privacy_version)
values ('22222222-2222-2222-2222-222222222222', '1995-04-04', '2026-10-01', '2026-10-01');

select ok(
  not has_function_privilege('anon', 'onboard_account(uuid,text,date,text,text)', 'execute')
  and not has_function_privilege('authenticated',
    'onboard_account(uuid,text,date,text,text)', 'execute'),
  'no client calls onboarding directly (§9.1, gate 3)'
);

-- §17.1: §7.3's "once" is not a counter, so this function takes no limit arguments.
select is(
  (select count(*)::int from pg_proc
   where oid = 'onboard_account(uuid,text,date,text,text)'::regprocedure
     and pronargs = 5),
  1,
  'it takes five arguments and none of §12.2''s windows, because §5.4''s row is the cap'
);

set local role service_role;

-- D9 and §5.2.1: 13+, checked here.
select is(
  onboard_account('11111111-1111-1111-1111-111111111111', 'twelve year old',
    ((now() at time zone 'Asia/Kolkata')::date - interval '12 years')::date,
    '2026-10-01', '2026-10-01') ->> 'error',
  'AGE_RESTRICTED',
  'an account under 13 cannot onboard, which D9 sets as the floor'
);

select is(
  (select count(*)::int from profiles where id = '11111111-1111-1111-1111-111111111111'),
  0,
  'and no profile row is written, so §5.4''s gate stays shut for them'
);

-- Exactly 13 today, on the IST day §5.1 uses for anything day-based.
select is(
  onboard_account('33333333-3333-3333-3333-333333333333', 'thirteen today',
    ((now() at time zone 'Asia/Kolkata')::date - interval '13 years')::date,
    '2026-10-01', '2026-10-01') ->> 'onboarded',
  'true',
  'and somebody who turns 13 today can, computed on the Asia/Kolkata day (§5.1)'
);

select is(
  onboard_account('44444444-4444-4444-4444-444444444444', 'impossible',
    ((now() at time zone 'Asia/Kolkata')::date - interval '151 years')::date,
    '2026-10-01', '2026-10-01') ->> 'field',
  'date_of_birth',
  'a date of birth no person could have is a typo, refused by name'
);

select is(
  onboard_account('11111111-1111-1111-1111-111111111111', 'x',
    '1995-04-04', '2026-10-01', '2026-10-01') ->> 'field',
  'profile',
  'a display name under §5.2.1''s two characters is caught as the backstop (§9.8)'
);

select is(
  onboard_account('11111111-1111-1111-1111-111111111111', 'bad versions',
    '1995-04-04', 'v1', '2026-10-01') ->> 'field',
  'profile',
  'and so is a policy version that is not §5.2.1''s effective date'
);

-- The happy path. §5.4: "The onboarding function creates the `profiles` and
-- `profile_private` rows together."
select is(
  onboard_account('11111111-1111-1111-1111-111111111111', 'anand',
    '1995-04-04', '2026-10-01', '2026-10-01') #>> '{profile,display_name}',
  'anand',
  'onboarding records the display name (§7.3)'
);

select ok(
  (select date_of_birth = '1995-04-04' and terms_version = '2026-10-01'
     and privacy_version = '2026-10-01' and guardian_consent = 'not_required'
   from profile_private where user_id = '11111111-1111-1111-1111-111111111111'),
  'and the date of birth and both accepted versions, with §9.6''s consent state ready'
);

select is(
  (select count(*)::int from profile_private
   where user_id = '11111111-1111-1111-1111-111111111111'),
  1,
  'as one private row beside the profile, which is what makes §5.4''s gate sound'
);

-- §5.4: "having a profile row is the gate", so a second call has nothing to create.
select is(
  onboard_account('22222222-2222-2222-2222-222222222222', 'renaming myself',
    '2000-01-01', '2026-10-01', '2026-10-01') ->> 'onboarded',
  'false',
  'an account that has onboarded is answered with its row rather than refused (§5.4)'
);

select is(
  (select display_name from profiles where id = '22222222-2222-2222-2222-222222222222'),
  'already here',
  'and nothing is overwritten, so onboarding is not a way to edit a profile (§7.2)'
);

-- §10.2's read_only, the only switch that reaches a sign-up.
reset role;
update app_flags set engaged = true where key = 'read_only';
set local role service_role;
select is(
  onboard_account('44444444-4444-4444-4444-444444444444', 'during read only',
    '1995-04-04', '2026-10-01', '2026-10-01') ->> 'error',
  'FEATURE_DISABLED',
  'read_only stops onboarding, which is a write (§10.2)'
);

reset role;
select * from finish();
rollback;
