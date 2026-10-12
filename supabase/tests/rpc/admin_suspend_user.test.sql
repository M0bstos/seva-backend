begin;
create extension if not exists pgtap with schema extensions;
select plan(26);

insert into auth.users (id) values
  ('99999999-9999-9999-9999-999999999999'),
  ('77777777-7777-7777-7777-777777777777'),
  ('88888888-8888-8888-8888-888888888888'),
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222'),
  ('33333333-3333-3333-3333-333333333333');
insert into profiles (id, display_name) values
  ('99999999-9999-9999-9999-999999999999', 'moderator'),
  -- A second moderator, so the lateral case has a target.
  ('77777777-7777-7777-7777-777777777777', 'other moderator'),
  ('88888888-8888-8888-8888-888888888888', 'admin'),
  ('11111111-1111-1111-1111-111111111111', 'first person'),
  ('22222222-2222-2222-2222-222222222222', 'second person'),
  ('33333333-3333-3333-3333-333333333333', 'third person');
insert into staff (user_id, role) values
  ('99999999-9999-9999-9999-999999999999', 'moderator'),
  ('77777777-7777-7777-7777-777777777777', 'moderator'),
  ('88888888-8888-8888-8888-888888888888', 'admin');

select ok(
  has_function_privilege('authenticated',
    'admin_suspend_user(uuid,timestamptz,text)', 'execute')
  and not has_function_privilege('anon',
    'admin_suspend_user(uuid,timestamptz,text)', 'execute')
  and not has_function_privilege('service_role',
    'admin_suspend_user(uuid,timestamptz,text)', 'execute'),
  'staff reach it as authenticated; anon and the secret key cannot (§9.1, §10.3)'
);

set local role authenticated;

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","aal":"aal2"}';
select is(
  admin_suspend_user('22222222-2222-2222-2222-222222222222',
    now() + interval '1 day', 'I disagree with them') ->> 'error',
  'FORBIDDEN',
  'a signed-in person who is not staff cannot suspend anyone (§10, §9.1)'
);

set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","aal":"aal1"}';
select is(
  admin_suspend_user('22222222-2222-2222-2222-222222222222',
    now() + interval '1 day', 'without MFA') ->> 'error',
  'FORBIDDEN',
  'and neither can a moderator who has not completed MFA (§9.3)'
);

set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","aal":"aal2"}';

select is(
  admin_suspend_user('22222222-2222-2222-2222-222222222222',
    now() + interval '1 day', 'no') ->> 'field',
  'reason',
  'a reason under §5.2.1''s three characters names the field (§10)'
);

select is(
  admin_suspend_user('dddddddd-dddd-dddd-dddd-dddddddddddd',
    now() + interval '1 day', 'no such person') ->> 'error',
  'NOT_FOUND',
  'a profile that is not there is NOT_FOUND (§7.4)'
);

-- §10.2: "Moderator ≤ 7 days".
select is(
  admin_suspend_user('22222222-2222-2222-2222-222222222222',
    now() + interval '3 days', 'repeated harassment reports upheld') ->> 'status',
  'suspended',
  'a moderator suspends for three days (§10.2)'
);

-- Read as the owner: §5.1 grants `authenticated` nothing in `pgmq`, which gates 6 and 7
-- assert and this test would otherwise be asserting the wrong schema.
reset role;
select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'kind' = 'sign_out'
     and message ->> 'user_id' = '22222222-2222-2222-2222-222222222222'),
  1,
  'and queues the sign-out §10.2 asks for, which SQL cannot do itself (§5.4, §12.4)'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","aal":"aal2"}';

select is(
  admin_suspend_user('33333333-3333-3333-3333-333333333333',
    now() + interval '10 days', 'longer than a moderator may') ->> 'error',
  'FORBIDDEN',
  'a moderator cannot go past seven days (§10.2)'
);

select is(
  admin_suspend_user('33333333-3333-3333-3333-333333333333', null,
    'indefinitely, which is an admin decision') ->> 'error',
  'FORBIDDEN',
  'nor suspend indefinitely, which §10.1 reserves to an admin'
);

reset role;
select is(
  (select status::text from profiles where id = '33333333-3333-3333-3333-333333333333'),
  'active',
  'and neither refusal touched the account'
);

-- §10.1: "Admin | … suspend indefinitely".
set local role authenticated;
set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal2"}';

select is(
  admin_suspend_user('33333333-3333-3333-3333-333333333333', null,
    'coordinated inauthentic behaviour across many accounts') ->> 'status',
  'suspended',
  'an admin suspends indefinitely (§10.1)'
);

reset role;
select ok(
  (select status = 'suspended' and suspended_until is null
   from profiles where id = '33333333-3333-3333-3333-333333333333'),
  'with no end date, which §5.2.1''s check pairs with the suspended status'
);

-- The attack review reproduced, which the self-check could not see: a moderator suspending the
-- admins for seven days — allowed, bounded, inside §10.2's ceiling — stripped their powers, because
-- `staff_actor` now requires an active account. One moderator removed the whole admin tier and
-- re-suspended them each time the sweep let them out, recoverable only by a migration.
set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","aal":"aal2"}';
select is(
  admin_suspend_user('88888888-8888-8888-8888-888888888888', now() + interval '7 days',
    'removing the admin tier') ->> 'error',
  'FORBIDDEN',
  'a moderator cannot suspend an admin, which would strip their role (§10.1)'
);

reset role;
select is(
  (select status::text from profiles where id = '88888888-8888-8888-8888-888888888888'),
  'active',
  'and the admin is untouched, so the containment path stays open'
);
set local role authenticated;

-- Lateral too: §10.1's roles are a hierarchy, so a moderator cannot suspend a fellow moderator.
select is(
  admin_suspend_user('77777777-7777-7777-7777-777777777777', now() + interval '1 day',
    'a colleague I disagree with') ->> 'error',
  'FORBIDDEN',
  'nor a fellow moderator, because junior is the rule rather than at-least-equal (§10.1)'
);

set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal2"}';
select is(
  admin_suspend_user('99999999-9999-9999-9999-999999999999', now() + interval '2 days',
    'suspending a moderator pending review') ->> 'status',
  'suspended',
  'while an admin may suspend a moderator, which is the containment §10.1 provides for'
);

reset role;
update profiles set status = 'active', suspended_until = null
where id = '99999999-9999-9999-9999-999999999999';
set local role authenticated;
set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal2"}';

-- Nobody suspends themselves. Review measured that once `staff_actor` required an active account,
-- a sole admin who did this indefinitely was locked out of every route back and recoverable only by
-- a migration — so the check `admin_set_staff` has needed to exist here too.
select is(
  admin_suspend_user('88888888-8888-8888-8888-888888888888', null,
    'locking myself out by accident') ->> 'error',
  'FORBIDDEN',
  'an admin cannot suspend themselves, which staff_actor made unrecoverable (§10.1, §10.2)'
);

reset role;
select is(
  (select status::text from profiles where id = '88888888-8888-8888-8888-888888888888'),
  'active',
  'and the account is untouched, so their own staff powers still work'
);
set local role authenticated;
set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal2"}';

-- Lifting. §10.2 lists no function for it, and §5.2.1's `suspended_until` is read by
-- nothing, so without a way back a seven-day suspension would never end.
set local role authenticated;
set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","aal":"aal2"}';

select is(
  admin_suspend_user('33333333-3333-3333-3333-333333333333', now(),
    'reinstating them') ->> 'error',
  'FORBIDDEN',
  'a moderator cannot lift an indefinite suspension, which would undo an admin (§10.1)'
);

select is(
  admin_suspend_user('22222222-2222-2222-2222-222222222222', now() - interval '1 second',
    'the reports were dismissed on review') ->> 'status',
  'active',
  'but may lift a bounded one, which is lighter than imposing it'
);

-- The bypass review reproduced, which the assertion above could not see: the direct lift was
-- refused, so the moderator rewrote the admin's indefinite suspension as a bounded one first —
-- neither indefinite nor a lift, and inside §10.2's 7 days — and the admin-only branch, which
-- read `suspended_until` for null, then no longer matched.
select is(
  admin_suspend_user('33333333-3333-3333-3333-333333333333', now() + interval '1 second',
    'making this one bounded') ->> 'error',
  'FORBIDDEN',
  'and cannot rewrite an indefinite suspension as bounded, which was the way round it (§10.1)'
);

-- Read outside the `authenticated` frame: `O15`'s policy is `status = 'active' or id = auth.uid()`,
-- so a moderator's own token cannot see the suspended row it just failed to change.
reset role;
select ok(
  (select status = 'suspended' and suspended_until is null
   from profiles where id = '33333333-3333-3333-3333-333333333333'),
  'the account is still suspended indefinitely, so the second step has nothing to lift'
);
set local role authenticated;

reset role;
select ok(
  (select status = 'active' and suspended_until is null
   from profiles where id = '22222222-2222-2222-2222-222222222222'),
  'and both columns go back together (§5.2.1)'
);

select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'kind' = 'sign_out'
     and message ->> 'user_id' = '22222222-2222-2222-2222-222222222222'),
  1,
  'with no second sign-out: there is no session to revoke when reinstating someone'
);
-- (already the owner here, from the `reset role` above)

set local role authenticated;
set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal2"}';
select is(
  admin_suspend_user('33333333-3333-3333-3333-333333333333', now(),
    'appeal upheld by the programme') ->> 'status',
  'active',
  'and an admin lifts the indefinite one (§10.1)'
);

reset role;
select results_eq(
  $$ select action, before ->> 'status', after ->> 'status'
     from admin_audit_log
     where subject_id = '33333333-3333-3333-3333-333333333333' order by id $$,
  $$ values ('suspend_user', 'active', 'suspended'),
            ('suspend_user', 'suspended', 'active') $$,
  'every suspension and every lift wrote its own audit row (§10)'
);

select * from finish();
rollback;
