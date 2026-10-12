begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

insert into auth.users (id, created_at) values
  ('11111111-1111-1111-1111-111111111111', now() - interval '30 days'),
  ('22222222-2222-2222-2222-222222222222', now() - interval '30 days'),
  ('33333333-3333-3333-3333-333333333333', now() - interval '30 days');
-- 33333333 is signed in and never onboarded, which the two routes treat differently.
insert into profiles (id, display_name, status, suspended_until) values
  ('11111111-1111-1111-1111-111111111111', 'anand', 'active', null),
  ('22222222-2222-2222-2222-222222222222', 'suspended', 'suspended', now() + interval '2 days');

select ok(
  not has_function_privilege('anon',
    'request_account_deletion(uuid,text,int,int,int)', 'execute')
  and not has_function_privilege('authenticated',
    'request_account_export(uuid,text,int,int,int)', 'execute')
  and not has_function_privilege('authenticated',
    'read_account_export(uuid,uuid,text,int,int,int)', 'execute'),
  'no client calls any of the three directly (§9.1, gate 3)'
);

set local role service_role;

-- §5.2.1 gives `account_deletions` a key with **no** foreign key, so §11.2's erasure right
-- does not begin at onboarding.
select is(
  request_account_deletion('33333333-3333-3333-3333-333333333333',
    'account.delete:u3', null, null, 3) ->> 'status',
  'pending',
  'an account that never onboarded can still be erased (§5.2.1, §11.2)'
);

-- §17 O33 is not applied: erasure is a right, not a feature.
select is(
  request_account_deletion('22222222-2222-2222-2222-222222222222',
    'account.delete:u2', null, null, 3) ->> 'status',
  'pending',
  'and so can a suspended one, because §11.2 does not condition the right (§17 O33)'
);

select is(
  request_account_deletion('11111111-1111-1111-1111-111111111111',
    'account.delete:u1', null, null, 3) ->> 'status',
  'pending',
  'a deletion is scheduled rather than performed (§7.3, §5.4)'
);

select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'kind' = 'delete_account'
     and message ->> 'user_id' = '11111111-1111-1111-1111-111111111111'),
  1,
  'with one ops job, which §8.4 retries and §12.5''s waiting arm can see'
);

-- From the table. The three assertions above read `status` out of the answer, which is
-- `jsonb_build_object('status', ...)` — the same echo shape that made three staff-function
-- assertions vacuous, so the row itself is read once here for all of them.
reset role;
select results_eq(
  $$ select user_id::text, status::text from account_deletions
     where user_id in ('11111111-1111-1111-1111-111111111111',
                       '22222222-2222-2222-2222-222222222222',
                       '33333333-3333-3333-3333-333333333333')
     order by user_id $$,
  $$ values ('11111111-1111-1111-1111-111111111111', 'pending'),
            ('22222222-2222-2222-2222-222222222222', 'pending'),
            ('33333333-3333-3333-3333-333333333333', 'pending') $$,
  'and each request is a row the worker will find, not only an answer (§5.2.1, §11.2)'
);
set local role service_role;

-- Asking twice must not queue twice. §7.3 allows three calls a day.
select is(
  request_account_deletion('11111111-1111-1111-1111-111111111111',
    'account.delete:u1', null, null, 3) ->> 'status',
  'pending',
  'asking again while it is pending is answered with the request already on file'
);

select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'kind' = 'delete_account'
     and message ->> 'user_id' = '11111111-1111-1111-1111-111111111111'),
  1,
  'and queues no second job'
);

-- §5.2.1 gives the table a `failed` status so §5.4's flow retries rather than half-performs.
reset role;
update account_deletions set status = 'failed'
where user_id = '11111111-1111-1111-1111-111111111111';
set local role service_role;

select is(
  request_account_deletion('11111111-1111-1111-1111-111111111111',
    'account.delete:u1', null, null, 3) ->> 'status',
  'pending',
  'a failed deletion is restarted when the person asks again (§5.2.1, §5.4)'
);

select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'kind' = 'delete_account'
     and message ->> 'user_id' = '11111111-1111-1111-1111-111111111111'),
  2,
  'with a second job, because the first one did not finish'
);

select is(
  request_account_deletion('11111111-1111-1111-1111-111111111111',
    'account.delete:cap', null, null, 1) ->> 'error',
  null,
  'the first call against a cap of one succeeds'
);

select is(
  request_account_deletion('11111111-1111-1111-1111-111111111111',
    'account.delete:cap', null, null, 1) ->> 'error',
  'DAILY_LIMIT_REACHED',
  'and §7.3''s 3/day is enforced through the caps the route passes (§12.2)'
);

-- The export half. §5.2.1 points `account_exports.user_id` at `profiles`, so here the gate
-- is structural — the opposite of `account_deletions`.
select is(
  request_account_export('33333333-3333-3333-3333-333333333333',
    'account.export:u3', null, null, 2) ->> 'error',
  'ONBOARDING_REQUIRED',
  'an export needs a profile row, which §5.2.1''s foreign key requires'
);

create temp table asked as
  select request_account_export('11111111-1111-1111-1111-111111111111',
    'account.export:u1', null, null, 2) as answer;

select is(
  (select answer ->> 'status' from asked),
  'pending',
  'an export is queued pending (§7.3)'
);

select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'kind' = 'export_account'
     and message ->> 'export_id' = (select answer ->> 'export_id' from asked)),
  1,
  'with an ops job naming the row, because §7.3 makes the export asynchronous'
);

-- §7.3's read half, scoped to the owner.
select is(
  read_account_export('22222222-2222-2222-2222-222222222222',
    (select (answer ->> 'export_id')::uuid from asked),
    'account.export.read:u2', null, 30, null) ->> 'error',
  'NOT_FOUND',
  'another person''s export is NOT_FOUND, so an id cannot be probed (§7.3, §7.4)'
);

select is(
  read_account_export('11111111-1111-1111-1111-111111111111',
    (select (answer ->> 'export_id')::uuid from asked),
    'account.export.read:u1', null, 30, null) ->> 'status',
  'pending',
  'the owner is told the status while it is still being built (§7.3)'
);

select is(
  read_account_export('11111111-1111-1111-1111-111111111111',
    (select (answer ->> 'export_id')::uuid from asked),
    'account.export.read:u1', null, 30, null) ->> 'file_path',
  null,
  'and gets no path to sign until there is a file, which §7.3 signs for an hour'
);

-- A ready export, and one whose seven days are up (§7.3, O7).
reset role;
update account_exports
set status = 'ready', file_path = 'exports/' || user_id || '/x.json',
    ready_at = now(), expires_at = now() + interval '7 days'
where id = (select (answer ->> 'export_id')::uuid from asked);
set local role service_role;

select is(
  read_account_export('11111111-1111-1111-1111-111111111111',
    (select (answer ->> 'export_id')::uuid from asked),
    'account.export.read:u1', null, 30, null) ->> 'file_path',
  'exports/11111111-1111-1111-1111-111111111111/x.json',
  'a ready export hands back the object path for the route to sign (§7.3)'
);

reset role;
update account_exports set expires_at = now() - interval '1 second'
where id = (select (answer ->> 'export_id')::uuid from asked);
set local role service_role;

select is(
  read_account_export('11111111-1111-1111-1111-111111111111',
    (select (answer ->> 'export_id')::uuid from asked),
    'account.export.read:u1', null, 30, null) ->> 'file_path',
  null,
  'and one past its seven days hands back none, because the file is going (§7.3, O7)'
);

reset role;
select * from finish();
rollback;
