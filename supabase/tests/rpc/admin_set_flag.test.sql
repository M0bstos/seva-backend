begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

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
  has_function_privilege('authenticated', 'admin_set_flag(app_flag,boolean,text)', 'execute')
  and not has_function_privilege('anon', 'admin_set_flag(app_flag,boolean,text)', 'execute')
  and not has_function_privilege('service_role',
    'admin_set_flag(app_flag,boolean,text)', 'execute'),
  'staff reach it as authenticated; anon and the secret key cannot (§9.1, §10.3)'
);

set local role authenticated;

-- §10.1 reserves kill switches to an admin.
set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","aal":"aal2"}';
select is(
  admin_set_flag('read_only', true, 'turning the site read only') ->> 'error',
  'FORBIDDEN',
  'a moderator cannot use a kill switch, which §10.1 gives an admin'
);

set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal1"}';
select is(
  admin_set_flag('read_only', true, 'without MFA') ->> 'error',
  'FORBIDDEN',
  'and neither can an admin who has not completed MFA (§9.3)'
);

set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal2"}';

select is(
  admin_set_flag('uploads', true, 'no') ->> 'field',
  'reason',
  'a reason under §5.2.1''s three characters names the field (§10)'
);

select is(
  admin_set_flag('uploads', null, 'neither on nor off') ->> 'field',
  'engaged',
  'and a call that says neither on nor off is refused by name'
);

-- §12.6's "Harmful content spreading" step: "Turn off `uploads` and `create_acts`".
select is(
  admin_set_flag('uploads', true, 'coordinated image spam from many new accounts')
    ->> 'engaged',
  'true',
  'an admin engages a switch (§10.2, §12.6)'
);

reset role;
select ok(
  (select engaged and updated_by = '88888888-8888-8888-8888-888888888888'
   from app_flags where key = 'uploads'),
  'and the row records who last moved it, which §5.2.1 gives it instead of updated_at'
);

select results_eq(
  $$ select action, subject_type, before ->> 'engaged', after ->> 'engaged'
     from admin_audit_log where reason like 'coordinated image spam%' $$,
  $$ values ('set_flag', 'app_flag', 'false', 'true') $$,
  'with an audit row carrying the switch either side (§10, §17.1)'
);

select * from finish();
rollback;
