begin;
create extension if not exists pgtap with schema extensions;
select plan(46);

-- An author, three reporters old enough to count, one a day old, one suspended, and one
-- signed-in account with no profile row.
insert into auth.users (id, created_at) values
  ('aaaa1111-1111-1111-1111-111111111111', now() - interval '60 days'),
  ('11111111-1111-1111-1111-111111111111', now() - interval '30 days'),
  ('22222222-2222-2222-2222-222222222222', now() - interval '30 days'),
  ('33333333-3333-3333-3333-333333333333', now() - interval '30 days'),
  ('44444444-4444-4444-4444-444444444444', now() - interval '1 day'),
  ('55555555-5555-5555-5555-555555555555', now() - interval '30 days'),
  ('66666666-6666-6666-6666-666666666666', now() - interval '30 days');
insert into profiles (id, display_name, status, suspended_until) values
  ('aaaa1111-1111-1111-1111-111111111111', 'author', 'active', null),
  ('11111111-1111-1111-1111-111111111111', 'reporter one', 'active', null),
  ('22222222-2222-2222-2222-222222222222', 'reporter two', 'active', null),
  ('33333333-3333-3333-3333-333333333333', 'reporter three', 'active', null),
  ('44444444-4444-4444-4444-444444444444', 'day old', 'active', null),
  ('55555555-5555-5555-5555-555555555555', 'suspended', 'suspended', now() + interval '2 days');
-- 66666666 has an auth row and no profile: the gate §5.2.1's foreign key makes structural.

insert into activities (id, organiser_id, title, description, category, starts_at, ends_at,
                        location, location_label, capacity, status,
                        idempotency_key, request_hash)
values ('aaaa0000-0000-0000-0000-000000000001',
        'aaaa1111-1111-1111-1111-111111111111', 'Lake shore cleanup',
        'Bring gloves and water. We meet at the east gate and finish before noon.',
        'environment', now() + interval '2 days', now() + interval '2 days 3 hours',
        extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
        'East gate', 40, 'visible',
        '00000000-0000-0000-0000-0000000000a1', repeat('a', 64));

insert into acts (id, author_id, title, story, category, occurred_on, location_coarse,
                  status, text_checked, idempotency_key, request_hash)
values
  ('bbbb0000-0000-0000-0000-000000000001', 'aaaa1111-1111-1111-1111-111111111111',
   'Three reports away', 'An ordinary act that three separate people are about to report.',
   'environment', '2026-10-12',
   extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
   'visible', true, '00000000-0000-0000-0000-0000000000b1', repeat('a', 64)),
  ('bbbb0000-0000-0000-0000-000000000002', 'aaaa1111-1111-1111-1111-111111111111',
   'One report away', 'An act whose first intimate imagery report holds it under §8.5.',
   'community', '2026-10-13',
   extensions.st_setsrid(extensions.st_makepoint(73.86, 18.53), 4326)::extensions.geography,
   'visible', true, '00000000-0000-0000-0000-0000000000b2', repeat('b', 64)),
  ('bbbb0000-0000-0000-0000-000000000003', 'aaaa1111-1111-1111-1111-111111111111',
   'Already gone', 'An act staff removed, which §8.3 takes out of every reader''s view.',
   'other', '2026-10-14',
   extensions.st_setsrid(extensions.st_makepoint(73.87, 18.54), 4326)::extensions.geography,
   'removed', true, '00000000-0000-0000-0000-0000000000b3', repeat('c', 64)),
  ('bbbb0000-0000-0000-0000-000000000004', 'aaaa1111-1111-1111-1111-111111111111',
   'Escalation subject', 'An act somebody reports twice, the second time more urgently.',
   'health', '2026-10-15',
   extensions.st_setsrid(extensions.st_makepoint(73.88, 18.55), 4326)::extensions.geography,
   'visible', true, '00000000-0000-0000-0000-0000000000b4', repeat('d', 64)),
  ('bbbb0000-0000-0000-0000-000000000005', 'aaaa1111-1111-1111-1111-111111111111',
   'New reporter subject', 'An act a day-old account reports as intimate imagery.',
   'other', '2026-10-16',
   extensions.st_setsrid(extensions.st_makepoint(73.89, 18.56), 4326)::extensions.geography,
   'visible', true, '00000000-0000-0000-0000-0000000000b5', repeat('e', 64));

select ok(
  not has_function_privilege('anon',
    'submit_report(uuid,report_subject,uuid,uuid,uuid,report_reason,text,uuid,text,text,int,int,int)',
    'execute')
  and not has_function_privilege('authenticated',
    'submit_report(uuid,report_subject,uuid,uuid,uuid,report_reason,text,uuid,text,text,int,int,int)',
    'execute'),
  'no client calls the reports function directly (§9.1, gate 3)'
);

set local role service_role;

-- §5.2.1's foreign key makes onboarding structural, whatever §7.3's "Signed in" says.
select is(
  submit_report('66666666-6666-6666-6666-666666666666', 'act',
    'bbbb0000-0000-0000-0000-000000000001', null, null, 'spam', null,
    '00000000-0000-0000-0000-0000000000f1', repeat('1', 64),
    'reports.create:u6', null, null, 20) ->> 'error',
  'ONBOARDING_REQUIRED',
  'an account with no profile row cannot file a report, because reporter_id needs one'
);

select is_empty(
  $$ select bucket from private.rate_limit_hits where bucket like 'reports.create:u6:%' $$,
  'and is not billed for it, because the gate sits above the count (§17.1)'
);

-- §17 O33 is deliberately not applied: §11.3's duty carries no exception for the
-- reporter's own standing, and O15 lets a suspended person keep browsing.
select is(
  submit_report('55555555-5555-5555-5555-555555555555', 'act',
    'bbbb0000-0000-0000-0000-000000000001', null, null, 'spam', null,
    '00000000-0000-0000-0000-0000000000f2', repeat('2', 64),
    'reports.create:u5', null, null, 20) #>> '{report,status}',
  'open',
  'a suspended account may still report, which §11.3 does not condition (§17 O33)'
);

-- §5.2.1's subject checks, kept off the table's check_violation path (§9.8).
select is(
  submit_report('11111111-1111-1111-1111-111111111111', 'activity',
    'bbbb0000-0000-0000-0000-000000000001', null, null, 'spam', null,
    '00000000-0000-0000-0000-0000000000f3', repeat('3', 64),
    'reports.create:u1', null, null, 20) ->> 'field',
  'subject_type',
  'a subject_type that disagrees with the id names the field rather than raising (§7.4)'
);

-- The measured §9.8 defect: a null subject type escaped a three-valued check, reached the
-- insert, and raised 23502 whose DETAIL carried `details` into the 180-day log.
select is(
  submit_report('11111111-1111-1111-1111-111111111111', null,
    'bbbb0000-0000-0000-0000-000000000001', null, null, 'spam',
    'her address is 12 MG Road',
    '00000000-0000-0000-0000-0000000000f7', repeat('7', 64),
    'reports.create:u1', null, null, 20) ->> 'field',
  'subject_type',
  'and a null subject type is refused before the insert can log the details (§9.8)'
);

select is(
  submit_report('11111111-1111-1111-1111-111111111111', 'act',
    'bbbb0000-0000-0000-0000-000000000001', null,
    '22222222-2222-2222-2222-222222222222', 'spam', null,
    '00000000-0000-0000-0000-0000000000f4', repeat('4', 64),
    'reports.create:u1', null, null, 20) ->> 'field',
  'subject_type',
  'and so does naming two subjects at once, which §5.1 forbids'
);

-- §5.2.1 gives request_hash its own check, which the details handler cannot tell apart.
select is(
  submit_report('11111111-1111-1111-1111-111111111111', 'act',
    'bbbb0000-0000-0000-0000-000000000001', null, null, 'spam', null,
    '00000000-0000-0000-0000-0000000000f8', 'tooshort',
    'reports.create:u1', null, null, 20) ->> 'field',
  'request_hash',
  'a short request hash names its own field, not details (§7.4, §5.2.1)'
);

-- The details bound, which the route also checks (§17.1's two layers).
select is(
  submit_report('11111111-1111-1111-1111-111111111111', 'act',
    'bbbb0000-0000-0000-0000-000000000001', null, null, 'spam', repeat('x', 501),
    '00000000-0000-0000-0000-0000000000f9', repeat('9', 64),
    'reports.create:u1', null, null, 20) ->> 'field',
  'details',
  'and details past §5.2.1''s 500 are caught as the backstop (§9.8)'
);

select is(
  submit_report('11111111-1111-1111-1111-111111111111', 'act',
    'bbbb0000-0000-0000-0000-00000000ffff', null, null, 'spam', null,
    '00000000-0000-0000-0000-0000000000f5', repeat('5', 64),
    'reports.create:u1', null, null, 20) ->> 'error',
  'NOT_FOUND',
  'a subject that does not exist is NOT_FOUND, which §7.4 folds with "not visible to you"'
);

select is(
  submit_report('11111111-1111-1111-1111-111111111111', 'act',
    'bbbb0000-0000-0000-0000-000000000003', null, null, 'spam', null,
    '00000000-0000-0000-0000-0000000000f6', repeat('6', 64),
    'reports.create:u1', null, null, 20) ->> 'error',
  'NOT_FOUND',
  'and so is one staff already removed, which no reader can see to report (§8.3)'
);

-- §7.3's three subject types.
select is(
  submit_report('11111111-1111-1111-1111-111111111111', 'activity',
    null, 'aaaa0000-0000-0000-0000-000000000001', null, 'unsafe', null,
    '00000000-0000-0000-0000-00000000001a', repeat('a', 64),
    'reports.create:u1', null, null, 20) #>> '{report,status}',
  'open',
  'an Activity can be reported (§7.3)'
);

select is(
  submit_report('11111111-1111-1111-1111-111111111111', 'profile',
    null, null, 'aaaa1111-1111-1111-1111-111111111111', 'impersonation', null,
    '00000000-0000-0000-0000-00000000001b', repeat('b', 64),
    'reports.create:u1', null, null, 20) #>> '{report,status}',
  'open',
  'and so can a person (§7.3)'
);

-- §8.3's statuses do not describe a person, so a profile report never auto-holds even at
-- the threshold of one §11.6 gives impersonation.
reset role;
select ok(
  (select status = 'active' and not text_hidden
   from profiles where id = 'aaaa1111-1111-1111-1111-111111111111'),
  'a reported person is not held or hidden automatically: §10.2 gives staff that (§8.3)'
);
set local role service_role;

-- §8.5 step 1, and the threshold of 3 for an ordinary reason.
select is(
  submit_report('11111111-1111-1111-1111-111111111111', 'act',
    'bbbb0000-0000-0000-0000-000000000001', null, null, 'spam', 'posted this four times',
    '00000000-0000-0000-0000-00000000000a', repeat('a', 64),
    'reports.create:u1', null, null, 20) #>> '{report,status}',
  'open',
  'a report is filed open (§8.5 step 1)'
);

select is(
  (select status::text from acts where id = 'bbbb0000-0000-0000-0000-000000000001'),
  'visible',
  'and one report does not reach §8.5''s threshold of three for spam'
);

-- §7.1.1 on this route, which §5.2.1 gives an idempotency key for.
select is(
  submit_report('11111111-1111-1111-1111-111111111111', 'act',
    'bbbb0000-0000-0000-0000-000000000001', null, null, 'spam', 'posted this four times',
    '00000000-0000-0000-0000-00000000000a', repeat('a', 64),
    'reports.create:replay', null, null, 20) ->> 'replayed',
  'true',
  'the same key and the same body answers the original row (§7.1.1)'
);

select is_empty(
  $$ select bucket from private.rate_limit_hits
     where bucket like 'reports.create:replay:%' $$,
  'and a clean replay is not billed (§17.1)'
);

select is(
  submit_report('11111111-1111-1111-1111-111111111111', 'act',
    'bbbb0000-0000-0000-0000-000000000001', null, null, 'harassment', 'different body',
    '00000000-0000-0000-0000-00000000000a', repeat('f', 64),
    'reports.create:reuse', null, null, 20) ->> 'error',
  'IDEMPOTENCY_KEY_REUSED',
  'the same key with a different body is refused (§7.1.1)'
);

select isnt_empty(
  $$ select bucket from private.rate_limit_hits
     where bucket like 'reports.create:reuse:%' $$,
  'and a key reused is billed, unlike a clean replay (§17.1)'
);

-- §5.2.1's one-open-report index, answered with the row on file rather than a 23505 — and
-- flagged as `already_open` rather than as §7.1.1's `replayed`, which means something else.
select is(
  submit_report('11111111-1111-1111-1111-111111111111', 'act',
    'bbbb0000-0000-0000-0000-000000000001', null, null, 'misleading', null,
    '00000000-0000-0000-0000-00000000000b', repeat('b', 64),
    'reports.create:u1', null, null, 20) ->> 'already_open',
  'true',
  'a second open report on one subject answers the first (§5.2.1)'
);

select is(
  submit_report('11111111-1111-1111-1111-111111111111', 'act',
    'bbbb0000-0000-0000-0000-000000000001', null, null, 'misleading', null,
    '00000000-0000-0000-0000-00000000000c', repeat('c', 64),
    'reports.create:u1', null, null, 20) ->> 'replayed',
  'false',
  'and is not called a replay, which §7.1.1 fixes as same key and same hash'
);

select is(
  (select count(*)::int from reports
   where act_id = 'bbbb0000-0000-0000-0000-000000000001'
     and reporter_id = '11111111-1111-1111-1111-111111111111'),
  1,
  'with no second row, which §5.2.1''s partial unique index forbids'
);

select is(
  (select reason::text from reports
   where act_id = 'bbbb0000-0000-0000-0000-000000000001'
     and reporter_id = '11111111-1111-1111-1111-111111111111'),
  'spam',
  'and no escalation, because `misleading` is no more urgent than `spam` (§10.4)'
);

-- The defect found in review: an urgent reason arriving second was swallowed, so no row
-- carried it and §12.5's 45-minute arm could never see it.
select is(
  submit_report('22222222-2222-2222-2222-222222222222', 'act',
    'bbbb0000-0000-0000-0000-000000000004', null, null, 'spam', null,
    '00000000-0000-0000-0000-00000000002a', repeat('a', 64),
    'reports.create:u2', null, null, 20) #>> '{report,reason}',
  'spam',
  'a reporter files an ordinary report on an act'
);

select is(
  (select status::text from acts where id = 'bbbb0000-0000-0000-0000-000000000004'),
  'visible',
  'which does not reach the threshold of three'
);

select is(
  submit_report('22222222-2222-2222-2222-222222222222', 'act',
    'bbbb0000-0000-0000-0000-000000000004', null, null, 'intimate_imagery',
    'it is a photo of me',
    '00000000-0000-0000-0000-00000000002b', repeat('b', 64),
    'reports.create:u2', null, null, 20) #>> '{report,reason}',
  'intimate_imagery',
  'and the same reporter escalating is answered with the urgent reason (§10.4, §11.6)'
);

select is(
  (select reason::text from reports
   where act_id = 'bbbb0000-0000-0000-0000-000000000004'),
  'intimate_imagery',
  'on the row itself, which is what §12.5''s 45-minute arm reads'
);

select is(
  (select details from reports where act_id = 'bbbb0000-0000-0000-0000-000000000004'),
  'it is a photo of me',
  'carrying the newer complaint'
);

select is(
  (select status::text from acts where id = 'bbbb0000-0000-0000-0000-000000000004'),
  'held',
  'and the escalation holds the content on that first urgent report (§8.5, §11.6)'
);

-- The second defect: §8.5's 7-day floor inverted the threshold of one, so a reporter who
-- signed up in order to report could never hold anything.
select is(
  submit_report('44444444-4444-4444-4444-444444444444', 'act',
    'bbbb0000-0000-0000-0000-000000000005', null, null, 'intimate_imagery', null,
    '00000000-0000-0000-0000-00000000004a', repeat('a', 64),
    'reports.create:u4', null, null, 20) #>> '{report,status}',
  'open',
  'a day-old account files an intimate imagery report'
);

select is(
  (select status::text from acts where id = 'bbbb0000-0000-0000-0000-000000000005'),
  'held',
  'and it holds on that first report, which §11.6 requires of this reason (§8.5)'
);

-- §8.5's filters still apply where the threshold is three.
select is(
  submit_report('44444444-4444-4444-4444-444444444444', 'act',
    'bbbb0000-0000-0000-0000-000000000001', null, null, 'spam', null,
    '00000000-0000-0000-0000-00000000004b', repeat('b', 64),
    'reports.create:u4', null, null, 20) #>> '{report,status}',
  'open',
  'a day-old account may file an ordinary report'
);

select is(
  submit_report('aaaa1111-1111-1111-1111-111111111111', 'act',
    'bbbb0000-0000-0000-0000-000000000001', null, null, 'spam', null,
    '00000000-0000-0000-0000-00000000000d', repeat('d', 64),
    'reports.create:author', null, null, 20) #>> '{report,status}',
  'open',
  'and so may the author, whom §8.5 excludes from the count rather than refusing'
);

select is(
  (select status::text from acts where id = 'bbbb0000-0000-0000-0000-000000000001'),
  'visible',
  'but at a threshold of three neither counts, so the content is still visible (§8.5)'
);

select is(
  submit_report('33333333-3333-3333-3333-333333333333', 'act',
    'bbbb0000-0000-0000-0000-000000000001', null, null, 'spam', null,
    '00000000-0000-0000-0000-000000000010', repeat('0', 64),
    'reports.create:u3', null, null, 20) #>> '{report,status}',
  'open',
  'the third eligible reporter files like any other'
);

select is(
  (select status::text from acts where id = 'bbbb0000-0000-0000-0000-000000000001'),
  'held',
  'and §8.5''s threshold of three holds the content through the staff status function'
);

-- Nothing about the hold reaches the reporter.
select is_empty(
  $$ select 1 from jsonb_object_keys(
       submit_report('22222222-2222-2222-2222-222222222222', 'act',
         'bbbb0000-0000-0000-0000-000000000002', null, null, 'intimate_imagery', null,
         '00000000-0000-0000-0000-000000000013', repeat('3', 64),
         'reports.create:u2', null, null, 20)
     ) as k where k not in ('replayed', 'already_open', 'report') $$,
  'the answer carries only the report and the two flags the route picks a status from'
);

-- §10.2's read_only is deliberately not checked: §11.3's channel has to survive the switch
-- §12.6 engages during exactly the incident §10.4's clocks run through.
reset role;
update app_flags set engaged = true where key = 'read_only';
set local role service_role;
select is(
  submit_report('33333333-3333-3333-3333-333333333333', 'act',
    'bbbb0000-0000-0000-0000-000000000005', null, null, 'intimate_imagery', null,
    '00000000-0000-0000-0000-000000000014', repeat('4', 64),
    'reports.create:u3', null, null, 20) #>> '{report,status}',
  'open',
  'a report is filed even under read_only, which §12.6 engages during an incident (§11.3)'
);
reset role;
update app_flags set engaged = false where key = 'read_only';

-- The defect found in review: a duplicate re-entered §8.5's hold on a threshold nothing had
-- crossed, writing a second actor = 'system' audit row into the record §11.6 makes evidence.
-- Reporter three already has an open report on this held act, so this call writes nothing —
-- and the audit assertion at the end of this file, which pins exactly which rows exist, is
-- what proves no row was added.
select is(
  submit_report('33333333-3333-3333-3333-333333333333', 'act',
    'bbbb0000-0000-0000-0000-000000000005', null, null, 'intimate_imagery', null,
    '00000000-0000-0000-0000-000000000015', repeat('5', 64),
    'reports.create:u3', null, null, 20) ->> 'already_open',
  'true',
  'a duplicate on already-held content is answered with the row on file (§5.2.1)'
);

-- The measured leak on the escalation path: §5.2.1's 500-character bound on `details` is a
-- table check, and the escalation `update` sits outside the insert's handler, so an overlong
-- `details` on a second, more urgent report raised 23514 whose DETAIL carried the text into
-- the log §11.6 keeps 180 days (§9.8). Reporter three's open report on act one is `spam`,
-- so this call would escalate.
select is(
  submit_report('33333333-3333-3333-3333-333333333333', 'act',
    'bbbb0000-0000-0000-0000-000000000001', null, null, 'impersonation',
    'MY NUMBER IS 9812345678 AND I LIVE AT 12 MG ROAD ' || repeat('x', 500),
    '00000000-0000-0000-0000-000000000016', repeat('6', 64),
    'reports.create:u3', null, null, 20) ->> 'field',
  'details',
  'an overlong details on the escalation path is named, not raised out of the update (§9.8)'
);

select is(
  (select reason::text from reports
   where reporter_id = '33333333-3333-3333-3333-333333333333'
     and act_id = 'bbbb0000-0000-0000-0000-000000000001'),
  'spam',
  'and the refusal wrote nothing, so the open report keeps the reason it had'
);

-- The last not-null column the handler would otherwise have spoken for, and mislabelled.
select is(
  submit_report('33333333-3333-3333-3333-333333333333', 'act',
    'bbbb0000-0000-0000-0000-000000000002', null, null, 'spam',
    'her address is 12 MG Road', null, repeat('7', 64),
    'reports.create:u3', null, null, 20) ->> 'field',
  'idempotency_key',
  'a null idempotency key names its own field rather than details (§7.4)'
);

-- §5.2.1's unique indexes make the 23505 path reachable only from a second session, which a
-- pgTAP file running in one transaction cannot produce. So the property is asserted over the
-- text of the function instead: one escalation site, after both branches, guarded by the flag
-- both of them set. Recorded in §17.1 as the weaker form of assertion it is — it would not
-- catch a wrong comparison, only the escalation moving back inside the first branch, which is
-- the regression that left the concurrent path unescalated.
select is(
  (select count(*)::int from regexp_matches(
     pg_get_functiondef('submit_report(uuid, report_subject, uuid, uuid, uuid, report_reason,
       text, uuid, text, text, int, int, int)'::regprocedure),
     'set reason = p_reason', 'g')),
  1,
  'one escalation site, so both the ordinary and the 23505 path reach it (§8.5)'
);

select ok(
  pg_get_functiondef('submit_report(uuid, report_subject, uuid, uuid, uuid, report_reason,
    text, uuid, text, text, int, int, int)'::regprocedure)
    like '%if v_already_open%private.report_urgency(p_reason) > private.report_urgency%',
  'and it is guarded by the flag both branches set, not by the first branch''s own if'
);

-- §8.5 step 3's audit rows, written inside the status function with actor = 'system'.
select results_eq(
  $$ select subject_id::text, (before ->> 'status') || '->' || (after ->> 'status')
     from admin_audit_log
     where actor = 'system' and staff_id is null
       and subject_id in ('bbbb0000-0000-0000-0000-000000000001',
                          'bbbb0000-0000-0000-0000-000000000002',
                          'bbbb0000-0000-0000-0000-000000000004',
                          'bbbb0000-0000-0000-0000-000000000005')
     order by subject_id, id $$,
  $$ values ('bbbb0000-0000-0000-0000-000000000001', 'visible->held'),
            ('bbbb0000-0000-0000-0000-000000000002', 'visible->held'),
            ('bbbb0000-0000-0000-0000-000000000004', 'visible->held'),
            ('bbbb0000-0000-0000-0000-000000000005', 'visible->held'),
            ('bbbb0000-0000-0000-0000-000000000005', 'held->held') $$,
  'each threshold crossing wrote its own audit row with actor = system (§8.5 step 3)'
);

select * from finish();
rollback;
