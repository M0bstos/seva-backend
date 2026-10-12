begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

insert into auth.users (id) values
  ('99999999-9999-9999-9999-999999999999'),
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into profiles (id, display_name, bio, text_hidden) values
  ('99999999-9999-9999-9999-999999999999', 'moderator', null, false),
  ('11111111-1111-1111-1111-111111111111', 'ordinary person', 'a bio', false),
  ('22222222-2222-2222-2222-222222222222', 'auto hidden', 'flagged bio', true);
insert into staff (user_id, role) values
  ('99999999-9999-9999-9999-999999999999', 'moderator');

select ok(
  has_function_privilege('authenticated',
    'admin_hide_profile_text(uuid,boolean,text)', 'execute')
  and not has_function_privilege('anon',
    'admin_hide_profile_text(uuid,boolean,text)', 'execute')
  and not has_function_privilege('service_role',
    'admin_hide_profile_text(uuid,boolean,text)', 'execute'),
  'staff reach it as authenticated; anon and the secret key cannot (§9.1, §10.3)'
);

set local role authenticated;

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","aal":"aal2"}';
select is(
  admin_hide_profile_text('22222222-2222-2222-2222-222222222222', false,
    'unhiding my own friend') ->> 'error',
  'FORBIDDEN',
  'a signed-in person who is not staff cannot touch the flag (§10, §9.1)'
);

set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","aal":"aal1"}';
select is(
  admin_hide_profile_text('11111111-1111-1111-1111-111111111111', true,
    'without MFA') ->> 'error',
  'FORBIDDEN',
  'and neither can a moderator who has not completed MFA (§9.3)'
);

set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","aal":"aal2"}';

select is(
  admin_hide_profile_text('11111111-1111-1111-1111-111111111111', true, 'no') ->> 'field',
  'reason',
  'a reason under §5.2.1''s three characters names the field (§10)'
);

select is(
  admin_hide_profile_text('11111111-1111-1111-1111-111111111111', null,
    'neither direction') ->> 'field',
  'hidden',
  'and a call that says neither hide nor show is refused by name'
);

select is(
  admin_hide_profile_text('dddddddd-dddd-dddd-dddd-dddddddddddd', true,
    'no such person') ->> 'error',
  'NOT_FOUND',
  'a profile that is not there is NOT_FOUND (§7.4)'
);

-- §10.2's own direction.
select is(
  admin_hide_profile_text('11111111-1111-1111-1111-111111111111', true,
    'impersonating a government office') ->> 'text_hidden',
  'true',
  'a moderator hides a display name and bio pending review (§10.2, §8.2)'
);

-- `O14`'s open half, which §8.2 left to this phase.
select is(
  admin_hide_profile_text('22222222-2222-2222-2222-222222222222', false,
    'reviewed, the bio is fine') ->> 'text_hidden',
  'false',
  'and clears a hide the worker set, which §8.2 says only a staff function may (O14)'
);

reset role;
select is(
  (select text_hidden from profiles where id = '22222222-2222-2222-2222-222222222222'),
  false,
  'on the row itself, so the client stops substituting "SEVA member" (§8.2)'
);

-- §9.8: the audit row says which direction, and never carries the text being hidden.
select results_eq(
  $$ select action, before ->> 'text_hidden', after ->> 'text_hidden',
            (before ? 'display_name' or after ? 'bio')
     from admin_audit_log
     where subject_id = '22222222-2222-2222-2222-222222222222' $$,
  $$ values ('hide_profile_text', 'true', 'false', false) $$,
  'the audit row records the flag either side and none of the text (§9.8, §10.3)'
);

select * from finish();
rollback;
