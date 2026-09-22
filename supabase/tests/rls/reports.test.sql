begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'anand'),
  ('22222222-2222-2222-2222-222222222222', 'bina');
insert into acts (id, author_id, title, story, category, occurred_on, location_coarse,
                  status, idempotency_key, request_hash)
values ('bbbb0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
   'Cleared the lake shore', 'We filled twelve sacks with plastic from the east bank this morning.',
   'environment', '2026-10-12',
   extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
   'visible', '00000000-0000-0000-0000-0000000000b1', repeat('a', 64));
insert into reports (reporter_id, subject_type, act_id, reason, idempotency_key, request_hash)
values ('11111111-1111-1111-1111-111111111111', 'act',
        'bbbb0000-0000-0000-0000-000000000001', 'spam',
        '00000000-0000-0000-0000-0000000000c1', repeat('a', 64));

select ok(
  not has_table_privilege('authenticated', 'reports',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'reports',
    'SELECT, INSERT, UPDATE, REFERENCES'),
  'a reporter cannot read the queue, not even their own reports'
);

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.reports'::regclass and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'public.reports', a.attname, 'insert')
       and a.attname not in ('reporter_id', 'subject_type', 'act_id', 'activity_id',
                             'reported_user_id', 'reason', 'details',
                             'idempotency_key', 'request_hash') $$,
  'submit_report files a report and cannot resolve one in the same breath'
);

select ok(
  not has_any_column_privilege('service_role', 'public.reports', 'UPDATE'),
  'resolving a report happens inside the staff function, not on the secret key'
);

select is_empty(
  $$ select policyname from pg_policies
     where schemaname = 'public' and tablename = 'reports' $$,
  'reports carries no policy, because no client can reach it to be policed'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.reports'::regclass),
  'row level security is on regardless, so a later grant cannot open the table by itself'
);

select throws_ok(
  $$ insert into reports (reporter_id, subject_type, act_id, reported_user_id, reason,
                          idempotency_key, request_hash)
     values ('11111111-1111-1111-1111-111111111111', 'act',
             'bbbb0000-0000-0000-0000-000000000001',
             '22222222-2222-2222-2222-222222222222', 'spam',
             '00000000-0000-0000-0000-0000000000c2', repeat('b', 64)) $$,
  '23514',
  null,
  'a report names at most one subject'
);

select throws_ok(
  $$ insert into reports (reporter_id, subject_type, act_id, reason,
                          idempotency_key, request_hash)
     values ('11111111-1111-1111-1111-111111111111', 'profile',
             'bbbb0000-0000-0000-0000-000000000001', 'spam',
             '00000000-0000-0000-0000-0000000000c3', repeat('c', 64)) $$,
  '23514',
  null,
  'and the subject column has to match the declared type'
);

select throws_ok(
  $$ update reports set status = 'actioned' where reason = 'spam' $$,
  '23514',
  null,
  'a resolved report must record when it was resolved'
);

select throws_ok(
  $$ insert into reports (reporter_id, subject_type, act_id, reason,
                          idempotency_key, request_hash)
     values ('11111111-1111-1111-1111-111111111111', 'act',
             'bbbb0000-0000-0000-0000-000000000001', 'unsafe',
             '00000000-0000-0000-0000-0000000000c4', repeat('d', 64)) $$,
  '23505',
  null,
  'one open report per reporter per subject, whatever the reason'
);

select throws_ok(
  $$ insert into reports (reporter_id, subject_type, reported_user_id, reason,
                          idempotency_key, request_hash)
     values ('11111111-1111-1111-1111-111111111111', 'profile',
             '22222222-2222-2222-2222-222222222222', 'spam',
             '00000000-0000-0000-0000-0000000000c1', repeat('e', 64)) $$,
  '23505',
  null,
  'and the same idempotency key cannot file a second report'
);

select lives_ok(
  $$ update reports set status = 'actioned', resolved_at = now(),
                        resolved_by = '22222222-2222-2222-2222-222222222222',
                        resolution_note = 'content removed'
     where reason = 'spam' $$,
  'the staff function resolves it, as the table owner'
);

select lives_ok(
  $$ insert into reports (reporter_id, subject_type, act_id, reason,
                          idempotency_key, request_hash)
     values ('11111111-1111-1111-1111-111111111111', 'act',
             'bbbb0000-0000-0000-0000-000000000001', 'unsafe',
             '00000000-0000-0000-0000-0000000000c5', repeat('f', 64)) $$,
  'and once it is resolved the same subject can be reported again'
);

set local role service_role;

select lives_ok(
  $$ insert into reports (reporter_id, subject_type, reported_user_id, reason,
                          details, idempotency_key, request_hash)
     values ('11111111-1111-1111-1111-111111111111', 'profile',
             '22222222-2222-2222-2222-222222222222', 'impersonation',
             'pretending to be someone else', '00000000-0000-0000-0000-0000000000c9',
             repeat('9', 64)) $$,
  'submit_report files a report on the secret key, which is the whole reports route'
);

select results_eq(
  $$ select status::text, resolved_at from reports
     where idempotency_key = '00000000-0000-0000-0000-0000000000c9' $$,
  $$ values ('open'::text, null::timestamptz) $$,
  'and it arrives open and unresolved, whatever the caller asked for'
);

reset role;

select lives_ok(
  $$ delete from acts where id = 'bbbb0000-0000-0000-0000-000000000001';
     $$,
  'deleting the reported act leaves the report behind with a null subject'
);

select * from finish();
rollback;
