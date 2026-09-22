begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

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
insert into supports (user_id, act_id) values
  ('22222222-2222-2222-2222-222222222222', 'bbbb0000-0000-0000-0000-000000000001');

select ok(
  has_table_privilege('authenticated', 'supports', 'SELECT, INSERT, DELETE')
  and not has_table_privilege('authenticated', 'supports',
    'UPDATE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'supports', 'UPDATE, REFERENCES'),
  'a support is added and removed, never edited'
);

select ok(
  has_table_privilege('service_role', 'supports', 'SELECT')
  and not has_table_privilege('service_role', 'supports',
    'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('service_role', 'supports', 'INSERT, UPDATE, REFERENCES'),
  'export_account reads a persons supports and the backend writes none'
);

select ok(
  not has_sequence_privilege('anon', 'supports_id_seq', 'USAGE, SELECT, UPDATE')
  and not has_sequence_privilege('authenticated', 'supports_id_seq', 'USAGE, SELECT, UPDATE'),
  'the identity sequence is closed to clients, which an identity column does not need'
);

select throws_ok(
  $$ insert into supports (user_id) values ('11111111-1111-1111-1111-111111111111') $$,
  '23514',
  null,
  'a support points at exactly one thing'
);

select throws_ok(
  $$ insert into supports (user_id, act_id, activity_id)
     values ('11111111-1111-1111-1111-111111111111',
             'bbbb0000-0000-0000-0000-000000000001',
             'aaaa0000-0000-0000-0000-000000000009') $$,
  '23514',
  null,
  'and never at two'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select lives_ok(
  $$ insert into supports (user_id, act_id)
     values ('11111111-1111-1111-1111-111111111111',
             'bbbb0000-0000-0000-0000-000000000001') $$,
  'a signed-in user supports an act, without needing the identity sequence'
);

select throws_ok(
  $$ insert into supports (user_id, act_id)
     values ('11111111-1111-1111-1111-111111111111',
             'bbbb0000-0000-0000-0000-000000000001') $$,
  '23505',
  null,
  'and cannot support the same act twice'
);

select throws_ok(
  $$ insert into supports (user_id, act_id)
     values ('22222222-2222-2222-2222-222222222222',
             'bbbb0000-0000-0000-0000-000000000001') $$,
  '42501',
  null,
  'nobody supports on someone elses behalf'
);

select results_eq(
  $$ select count(*)::int from supports $$,
  $$ values (1) $$,
  'a signed-in user sees only their own supports, never who else supported what'
);

-- Unqualified on purpose: a WHERE clause would reference a column, which invokes
-- the select policy and would mask whatever the delete policy does.
select lives_ok(
  $$ delete from supports $$,
  'an unqualified delete is filtered by the delete policy rather than refused'
);

reset role;

select results_eq(
  $$ select user_id from supports $$,
  $$ values ('22222222-2222-2222-2222-222222222222'::uuid) $$,
  'and it removed only the callers own support, leaving the other persons behind'
);

select lives_ok(
  $$ delete from profiles where id = '11111111-1111-1111-1111-111111111111' $$,
  'supports cascade away with the profile that made them'
);

select * from finish();
rollback;
