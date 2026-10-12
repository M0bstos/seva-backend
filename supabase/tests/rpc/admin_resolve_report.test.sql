begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

insert into auth.users (id, created_at) values
  ('aaaa1111-1111-1111-1111-111111111111', now() - interval '60 days'),
  ('99999999-9999-9999-9999-999999999999', now() - interval '60 days'),
  ('88888888-8888-8888-8888-888888888888', now() - interval '60 days'),
  ('11111111-1111-1111-1111-111111111111', now() - interval '30 days');
insert into profiles (id, display_name) values
  ('aaaa1111-1111-1111-1111-111111111111', 'author'),
  ('99999999-9999-9999-9999-999999999999', 'moderator'),
  ('88888888-8888-8888-8888-888888888888', 'second moderator'),
  ('11111111-1111-1111-1111-111111111111', 'reporter');
insert into staff (user_id, role) values
  ('99999999-9999-9999-9999-999999999999', 'moderator'),
  ('88888888-8888-8888-8888-888888888888', 'moderator');

insert into acts (id, author_id, title, story, category, occurred_on, location_coarse,
                  status, text_checked, idempotency_key, request_hash)
values ('bbbb0000-0000-0000-0000-000000000001', 'aaaa1111-1111-1111-1111-111111111111',
        'Reported act', 'An act somebody reported, whose report a moderator will close.',
        'environment', '2026-10-12',
        extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
        'visible', true, '00000000-0000-0000-0000-0000000000b1', repeat('a', 64));

insert into reports (id, reporter_id, subject_type, act_id, reason, idempotency_key,
                     request_hash)
values ('eeee0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        'act', 'bbbb0000-0000-0000-0000-000000000001', 'spam',
        '00000000-0000-0000-0000-0000000000e1', repeat('e', 64));

select ok(
  has_function_privilege('authenticated',
    'admin_resolve_report(uuid,report_status,text)', 'execute')
  and not has_function_privilege('anon',
    'admin_resolve_report(uuid,report_status,text)', 'execute')
  and not has_function_privilege('service_role',
    'admin_resolve_report(uuid,report_status,text)', 'execute'),
  'staff reach it as authenticated; anon and the secret key cannot (§9.1, §10.3)'
);

set local role authenticated;

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","aal":"aal2"}';
select is(
  admin_resolve_report('eeee0000-0000-0000-0000-000000000001', 'dismissed',
    'nothing wrong here') ->> 'error',
  'FORBIDDEN',
  'the person who filed the report cannot close it themselves (§10, §10.1)'
);

set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","aal":"aal1"}';
select is(
  admin_resolve_report('eeee0000-0000-0000-0000-000000000001', 'dismissed',
    'without MFA') ->> 'error',
  'FORBIDDEN',
  'and neither can a moderator who has not completed MFA (§9.3)'
);

set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","aal":"aal2"}';

select is(
  admin_resolve_report('eeee0000-0000-0000-0000-000000000001', 'dismissed', 'no') ->> 'field',
  'note',
  'a note under §5.2.1''s three characters names the field (§10.2, §10)'
);

-- §10.2 gives two outcomes; §5.3's third is where a report starts.
select is(
  admin_resolve_report('eeee0000-0000-0000-0000-000000000001', 'open',
    'leaving it open') ->> 'field',
  'status',
  'a moderator cannot reopen a report by resolving it to open (§5.2.1)'
);

select is(
  admin_resolve_report('eeee0000-0000-0000-0000-00000000ffff', 'dismissed',
    'no such report') ->> 'error',
  'NOT_FOUND',
  'a report that is not there is NOT_FOUND (§7.4)'
);

select is(
  admin_resolve_report('eeee0000-0000-0000-0000-000000000001', 'actioned',
    'removed the act and warned the author') ->> 'status',
  'actioned',
  'a moderator closes an open report (§10.2)'
);

-- §5.2.1: "resolved_at set exactly when status <> 'open'".
reset role;
select ok(
  (select resolved_at is not null and resolved_by = '99999999-9999-9999-9999-999999999999'
     and resolution_note = 'removed the act and warned the author'
   from reports where id = 'eeee0000-0000-0000-0000-000000000001'),
  'the row records when it was closed, by whom, and the note (§5.2.1, §10.4)'
);

select results_eq(
  $$ select staff_id, action, subject_type, before ->> 'status', after ->> 'status'
     from admin_audit_log where subject_id = 'eeee0000-0000-0000-0000-000000000001' $$,
  $$ values ('99999999-9999-9999-9999-999999999999'::uuid, 'resolve_report',
             'report', 'open', 'actioned') $$,
  'and the audit row names the moderator and the status either side (§10)'
);

-- A second moderator reaching the same report. §5.2.1 makes resolved_by single-valued,
-- so overwriting the first decision silently would lose who actually acted.
set local role authenticated;
set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal2"}';
select is(
  admin_resolve_report('eeee0000-0000-0000-0000-000000000001', 'dismissed',
    'I disagree with that') ->> 'field',
  'status',
  'a report already closed cannot be closed again (§10.2, §10.3)'
);

reset role;
select is(
  (select resolved_by from reports where id = 'eeee0000-0000-0000-0000-000000000001'),
  '99999999-9999-9999-9999-999999999999'::uuid,
  'so the first moderator''s decision and name survive'
);

select is(
  (select count(*)::int from admin_audit_log
   where subject_id = 'eeee0000-0000-0000-0000-000000000001'),
  1,
  'and the refused second call wrote no audit row'
);

select * from finish();
rollback;
