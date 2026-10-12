begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

insert into auth.users (id) values
  ('99999999-9999-9999-9999-999999999999'),
  ('88888888-8888-8888-8888-888888888888'),
  ('11111111-1111-1111-1111-111111111111');
insert into profiles (id, display_name) values
  ('99999999-9999-9999-9999-999999999999', 'moderator'),
  ('88888888-8888-8888-8888-888888888888', 'admin'),
  ('11111111-1111-1111-1111-111111111111', 'ordinary person');
insert into staff (user_id, role) values
  ('99999999-9999-9999-9999-999999999999', 'moderator'),
  ('88888888-8888-8888-8888-888888888888', 'admin');

select ok(
  not has_function_privilege('anon', 'private.staff_actor(staff_role)', 'execute')
  and not has_function_privilege('authenticated',
    'private.staff_actor(staff_role)', 'execute')
  and not has_function_privilege('service_role',
    'private.staff_actor(staff_role)', 'execute'),
  'nothing but the admin_* bodies can ask this, which gate 6 also asserts'
);

select ok(
  (select provolatile from pg_proc
   where oid = 'private.staff_actor(staff_role)'::regprocedure) = 's'
  and not (select prosecdef from pg_proc
           where oid = 'private.staff_actor(staff_role)'::regprocedure),
  'it is stable and security invoker: it reads the claims and writes nothing'
);

-- §9.3: "staff functions require `aal2`". A session that completed MFA.
set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","aal":"aal2"}';

select is(
  private.staff_actor('moderator'),
  '99999999-9999-9999-9999-999999999999'::uuid,
  'a moderator with MFA is answered with their own id, for admin_audit_log.staff_id'
);

select is(
  private.staff_actor('admin'),
  null,
  'and is not an admin: §10.1 keeps verifying, campaigns and staff to admins'
);

-- §10.1: "Admin | Everything a moderator can, plus …", which is the enum's own order.
set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal2"}';

select is(
  private.staff_actor('admin'),
  '88888888-8888-8888-8888-888888888888'::uuid,
  'an admin with MFA is an admin'
);

select is(
  private.staff_actor('moderator'),
  '88888888-8888-8888-8888-888888888888'::uuid,
  'and can do everything a moderator can (§10.1)'
);

-- The MFA half, which §9.7's callout calls the only control on an admin_* function.
set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal1"}';
select is(
  private.staff_actor('moderator'),
  null,
  'an admin who has not completed MFA is refused (§9.3)'
);

set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888"}';
select is(
  private.staff_actor('moderator'),
  null,
  'and so is a token with no aal claim at all, which fails closed'
);

-- Not staff.
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","aal":"aal2"}';
select is(
  private.staff_actor('moderator'),
  null,
  'a signed-in person with MFA and no staff row is not staff'
);

set local request.jwt.claims = '{"sub":"dddddddd-dddd-dddd-dddd-dddddddddddd","aal":"aal2"}';
select is(
  private.staff_actor('moderator'),
  null,
  'nor is an id with no account behind it'
);

-- A suspended staff member, which review found holds every power without this. The containment
-- that matters: an admin suspends a rogue moderator, and the moderator can no longer suspend them
-- back — which the queued sign-out cannot achieve, because nothing in Auth reads `profiles.status`.
update profiles set status = 'suspended', suspended_until = now() + interval '2 days'
where id = '99999999-9999-9999-9999-999999999999';
set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","aal":"aal2"}';

select is(
  private.staff_actor('moderator'),
  null,
  'a suspended staff member is nobody, so suspension contains them (§10.1, O33)'
);

update profiles set status = 'active', suspended_until = null
where id = '99999999-9999-9999-9999-999999999999';

select is(
  private.staff_actor('moderator'),
  '99999999-9999-9999-9999-999999999999'::uuid,
  'and lifting it gives the role back, so the check is on the status and not on having been one'
);

-- No session at all, which is how a worker's secret-key call arrives.
set local request.jwt.claims = '';
select is(
  private.staff_actor('moderator'),
  null,
  'and a call carrying no claims is nobody, so a secret key alone is not staff'
);

select * from finish();
rollback;
