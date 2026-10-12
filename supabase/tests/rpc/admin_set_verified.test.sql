begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

insert into auth.users (id) values
  ('88888888-8888-8888-8888-888888888888'),
  ('99999999-9999-9999-9999-999999999999'),
  ('11111111-1111-1111-1111-111111111111');
insert into profiles (id, display_name) values
  ('88888888-8888-8888-8888-888888888888', 'admin'),
  ('99999999-9999-9999-9999-999999999999', 'moderator'),
  ('11111111-1111-1111-1111-111111111111', 'ordinary person');
insert into staff (user_id, role) values
  ('88888888-8888-8888-8888-888888888888', 'admin'),
  ('99999999-9999-9999-9999-999999999999', 'moderator');

select ok(
  has_function_privilege('authenticated',
    'admin_set_verified(uuid,boolean,text,org_type,text)', 'execute')
  and not has_function_privilege('anon',
    'admin_set_verified(uuid,boolean,text,org_type,text)', 'execute')
  and not has_function_privilege('service_role',
    'admin_set_verified(uuid,boolean,text,org_type,text)', 'execute'),
  'staff reach it as authenticated; anon and the secret key cannot (§9.1, §10.3)'
);

set local role authenticated;

-- §10.1 reserves verifying to an admin, so a moderator is the interesting refusal here.
set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","aal":"aal2"}';
select is(
  admin_set_verified('11111111-1111-1111-1111-111111111111', true, 'Pune Green Trust',
    'ngo', 'they sent registration papers') ->> 'error',
  'FORBIDDEN',
  'a moderator cannot verify an organisation, which §10.1 gives an admin (D7)'
);

set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal1"}';
select is(
  admin_set_verified('11111111-1111-1111-1111-111111111111', true, 'Pune Green Trust',
    'ngo', 'without MFA') ->> 'error',
  'FORBIDDEN',
  'and neither can an admin who has not completed MFA (§9.3)'
);

set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal2"}';

select is(
  admin_set_verified('11111111-1111-1111-1111-111111111111', true, 'Pune Green Trust',
    'ngo', 'no') ->> 'field',
  'reason',
  'a reason under §5.2.1''s three characters names the field (§10)'
);

-- §5.2.1: "verified ⇒ org_name and org_type set".
select is(
  admin_set_verified('11111111-1111-1111-1111-111111111111', true, null, null,
    'badge with no organisation behind it') ->> 'field',
  'org_name',
  'a badge without an organisation is refused by name, not by a 23514 (§5.2.1)'
);

select is(
  admin_set_verified('11111111-1111-1111-1111-111111111111', true, repeat('x', 101),
    'ngo', 'an organisation name past §5.2.1''s bound') ->> 'field',
  'org_name',
  'and so is a name over 100, caught as the backstop (§5.2.1, §9.8)'
);

select is(
  admin_set_verified('dddddddd-dddd-dddd-dddd-dddddddddddd', true, 'Trust', 'ngo',
    'no such person') ->> 'error',
  'NOT_FOUND',
  'a profile that is not there is NOT_FOUND (§7.4)'
);

select is(
  admin_set_verified('11111111-1111-1111-1111-111111111111', true, 'Pune Green Trust',
    'ngo', 'registration certificate checked against the register') ->> 'is_verified',
  'true',
  'an admin sets the badge with an organisation name and type (§10.2, D7)'
);

-- From the table. The answer echoes all three arguments, so the assertion above proved only that
-- the call was allowed — review's point, and the same shape as the two it reproduced elsewhere.
-- §9.2 makes verification one of the things no client may write, so this is the column that
-- matters most in the nine.
reset role;
select ok(
  (select is_verified and org_name = 'Pune Green Trust' and org_type::text = 'ngo'
   from profiles where id = '11111111-1111-1111-1111-111111111111'),
  'and the row carries all three, which §9.2 lets nothing but this function write'
);
set local role authenticated;
set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal2"}';

-- Clearing it. §5.2.1's check only binds when the badge is on, so the organisation goes
-- with it.
select is(
  admin_set_verified('11111111-1111-1111-1111-111111111111', false, null, null,
    'the trust was struck off the register') ->> 'is_verified',
  'false',
  'and takes it away again'
);

reset role;
select results_eq(
  $$ select action, before ->> 'is_verified', after ->> 'is_verified'
     from admin_audit_log
     where subject_id = '11111111-1111-1111-1111-111111111111' order by id $$,
  $$ values ('set_verified', 'false', 'true'), ('set_verified', 'true', 'false') $$,
  'both directions wrote their own audit row (§10)'
);

select * from finish();
rollback;
