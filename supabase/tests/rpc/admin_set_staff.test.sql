begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

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
  has_function_privilege('authenticated', 'admin_set_staff(uuid,staff_role,text)', 'execute')
  and not has_function_privilege('anon', 'admin_set_staff(uuid,staff_role,text)', 'execute')
  and not has_function_privilege('service_role',
    'admin_set_staff(uuid,staff_role,text)', 'execute'),
  'staff reach it as authenticated; anon and the secret key cannot (§9.1, §10.3)'
);

set local role authenticated;

set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","aal":"aal2"}';
select is(
  admin_set_staff('11111111-1111-1111-1111-111111111111', 'moderator',
    'promoting a friend') ->> 'error',
  'FORBIDDEN',
  'a moderator cannot make staff, which §10.1 gives an admin'
);

set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal2"}';

-- §10.2's parenthesis, which is the whole security property of this function.
select is(
  admin_set_staff('88888888-8888-8888-8888-888888888888', null,
    'standing down as admin') ->> 'error',
  'FORBIDDEN',
  'an admin cannot change their own role (§10.2, §10.1)'
);

select is(
  admin_set_staff('dddddddd-dddd-dddd-dddd-dddddddddddd', 'moderator',
    'no such person') ->> 'error',
  'NOT_FOUND',
  'and a person who has no profile cannot be staff, which §5.2.1''s key requires'
);

select is(
  admin_set_staff('11111111-1111-1111-1111-111111111111', 'moderator', 'no') ->> 'field',
  'reason',
  'a reason under §5.2.1''s three characters names the field (§10)'
);

select is(
  admin_set_staff('11111111-1111-1111-1111-111111111111', 'moderator',
    'joining the moderation rota from Monday') ->> 'role',
  'moderator',
  'an admin grants a staff role (§10.2)'
);

select is(
  admin_set_staff('99999999-9999-9999-9999-999999999999', 'admin',
    'taking over campaign management') ->> 'role',
  'admin',
  'and changes one'
);

-- §5.4: "Staff are demoted, never deleted."
select is(
  admin_set_staff('11111111-1111-1111-1111-111111111111', null,
    'left the programme at the end of the month') ->> 'role',
  null,
  'a null role removes the staff row, which §5.4 calls a demotion'
);

reset role;
select ok(
  (select not exists (select 1 from staff where user_id = '11111111-1111-1111-1111-111111111111')
   and exists (select 1 from profiles where id = '11111111-1111-1111-1111-111111111111')),
  'leaving the person''s profile, which §5.2.1''s restrict key is what protects'
);

select * from finish();
rollback;
