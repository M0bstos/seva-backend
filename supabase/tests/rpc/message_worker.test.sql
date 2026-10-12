begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

insert into auth.users (id, created_at) values
  ('11111111-1111-1111-1111-111111111111', now() - interval '30 days'),
  ('22222222-2222-2222-2222-222222222222', now() - interval '30 days'),
  ('33333333-3333-3333-3333-333333333333', now() - interval '30 days');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'organiser'),
  ('22222222-2222-2222-2222-222222222222', 'participant'),
  ('33333333-3333-3333-3333-333333333333', 'who left');

insert into activities (id, organiser_id, title, description, category, starts_at, ends_at,
                        location, location_label, capacity, status, cancelled_at,
                        idempotency_key, request_hash)
values
  ('aaaa0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'Lake shore cleanup',
   'Bring gloves and water. We meet at the east gate and finish before noon.',
   'environment', now() + interval '5 days', now() + interval '5 days 3 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
   'East gate, Pashan Lake', 40, 'visible', now(),
   '00000000-0000-0000-0000-0000000000a1', repeat('a', 64)),
  -- Not cancelled, so a job naming it is one the claim must drop rather than send.
  ('aaaa0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'Still going ahead',
   'Bring gloves and water. We meet at the east gate and finish before noon.',
   'environment', now() + interval '6 days', now() + interval '6 days 3 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.86, 18.53), 4326)::extensions.geography,
   'East gate', 40, 'visible', null,
   '00000000-0000-0000-0000-0000000000a2', repeat('b', 64));
insert into activity_participants (activity_id, user_id, status, left_at) values
  ('aaaa0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
   'joined', null),
  ('aaaa0000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222',
   'joined', null);

create function pg_temp.queue(p_activity uuid, p_user uuid) returns bigint
language sql as $$
  select pgmq.send('email', jsonb_build_object(
    'kind', 'activity_cancelled', 'activity_id', p_activity, 'user_id', p_user));
$$;

select is_empty(
  $$ select r.rolname || ' -> ' || f.fn from
       (values ('anon'::name), ('authenticated'::name)) as r (rolname)
     cross join (values
       ('claim_message_jobs(int)'),
       ('complete_message_job(bigint, text)')) as f (fn)
     where has_function_privilege(r.rolname, f.fn, 'execute') $$,
  'no client may claim or complete a message job (§9.1, gate 3)'
);

set local role service_role;

select throws_ok(
  $$ select claim_message_jobs(0) $$,
  'P0001',
  'claim_message_jobs takes a count between 1 and 100',
  'an unbounded claim is refused, because one call would hide the whole queue (§8.4)'
);

select throws_ok(
  $$ select claim_message_jobs(101) $$,
  'P0001',
  'claim_message_jobs takes a count between 1 and 100',
  'and so is one past the batch §8.4 bounds'
);

-- The happy path. §2.1: an organiser cancels and "every participant" is notified.
select pg_temp.queue('aaaa0000-0000-0000-0000-000000000001',
                     '22222222-2222-2222-2222-222222222222');

create temp table claimed as select claim_message_jobs(10) as jobs;

select is(
  (select jsonb_array_length(jobs) from claimed),
  1,
  'a cancellation job is handed out (§2.1)'
);

select is(
  (select jobs #>> '{0,title}' from claimed),
  'Lake shore cleanup',
  'with the Activity''s own title, which is what the message is about'
);

select is(
  (select jobs #>> '{0,location_label}' from claimed),
  'East gate, Pashan Lake',
  'and its meeting point, which §5.4 stores exactly because it is a public event'
);

-- §5.4 keeps the address in Supabase Auth, so the claim hands out an id and the worker asks the
-- admin API. Nothing about the recipient but their id may be here.
select is_empty(
  $$ select k from jsonb_object_keys((select jobs -> 0 from claimed)) as k
     where k not in ('msg_id', 'kind', 'user_id', 'activity_id', 'title',
                     'starts_at', 'location_label') $$,
  'the job carries no address and no locale: §5.4 keeps one in Auth and v1 sends English'
);

-- §8.4's claim window: the message is hidden for 60 seconds, so a completion inside it works.
select is(
  complete_message_job((select (jobs #>> '{0,msg_id}')::bigint from claimed),
    'activity_cancelled') ->> 'status',
  'sent',
  'a completion inside §8.4''s window finishes the job'
);

select is(
  (select count(*)::int from pgmq.q_email),
  0,
  'and the message is gone, so no second send happens'
);

select is(
  complete_message_job(999999, 'activity_cancelled') ->> 'error',
  'NOT_FOUND',
  'a msg_id nobody claimed is refused, so the id is a capability rather than an integer (§8.4)'
);

-- An Activity that is not cancelled, and a participant who left: §2.1 notifies people whose event
-- was cancelled, and nobody else.
select pg_temp.queue('aaaa0000-0000-0000-0000-000000000002',
                     '22222222-2222-2222-2222-222222222222');
select pg_temp.queue('aaaa0000-0000-0000-0000-000000000001',
                     '33333333-3333-3333-3333-333333333333');

select is(
  jsonb_array_length(claim_message_jobs(10)),
  0,
  'neither an uncancelled Activity nor a non-participant produces a message (§2.1)'
);

-- Somebody who actually left, which is a different row from a non-participant: `leave_activity`
-- keeps the row and sets `status`, so review found this case uncovered and the join matching it.
reset role;
insert into activity_participants (activity_id, user_id, status, left_at)
values ('aaaa0000-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333',
        'left', now() - interval '1 hour');
update activities set cancelled_at = now(), status = 'visible'
where id = 'aaaa0000-0000-0000-0000-000000000002';
set local role service_role;

select pg_temp.queue('aaaa0000-0000-0000-0000-000000000002',
                     '33333333-3333-3333-3333-333333333333');

select is(
  jsonb_array_length(claim_message_jobs(10)),
  0,
  'and somebody who left the Activity gets no cancellation email (§2.1)'
);

select is(
  (select count(*)::int from pgmq.q_email),
  0,
  'and both jobs are deleted rather than archived: there is no work to retry (§8.4)'
);

-- §8.4's "nothing is silently dropped" for a message this version could not have written.
select pgmq.send('email', jsonb_build_object('kind', 'invented', 'activity_id', 'x'));
select is(
  jsonb_array_length(claim_message_jobs(10)),
  0,
  'a kind nothing sends is not handed to the worker'
);

select is(
  (select count(*)::int from pgmq.a_email),
  1,
  'it is archived instead, which §12.5''s dead-job arm is what sees (§8.4)'
);

-- §17.1's starvation defect, in its message-queue form: a malformed id must not raise before the
-- archive checks, because the raise would roll back `pgmq.read`'s own visibility update.
select pgmq.send('email', jsonb_build_object(
  'kind', 'activity_cancelled', 'activity_id', 'not-a-uuid', 'user_id', 'nor-this'));
select is(
  jsonb_array_length(claim_message_jobs(10)),
  0,
  'a malformed id is archived rather than raising, so one message cannot starve the queue (§17.1)'
);

reset role;
select * from finish();
rollback;
