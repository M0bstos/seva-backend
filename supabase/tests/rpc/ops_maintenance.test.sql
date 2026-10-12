begin;
create extension if not exists pgtap with schema extensions;
select plan(32);

insert into auth.users (id, created_at)
values ('11111111-1111-1111-1111-111111111111', now() - interval '30 days');
insert into profiles (id, display_name)
values ('11111111-1111-1111-1111-111111111111', 'anand');

-- §8.1's 24-hour sweep: one upload that never completed, and one that did.
insert into media (id, owner_id, purpose, upload_path, status, created_at) values
  ('dddd0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'act', '11111111-1111-1111-1111-111111111111/stale', 'uploading',
   now() - interval '25 hours'),
  ('dddd0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'act', '11111111-1111-1111-1111-111111111111/fresh', 'uploading',
   now() - interval '2 hours'),
  ('dddd0000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   'act', '11111111-1111-1111-1111-111111111111/done', 'ready',
   now() - interval '25 hours');

-- §O7's seven days for an export, and one still inside them.
insert into account_exports (id, user_id, status, file_path, ready_at, expires_at) values
  ('ffff0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'ready', '11111111-1111-1111-1111-111111111111/old.json',
   now() - interval '8 days', now() - interval '1 day'),
  ('ffff0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'ready', '11111111-1111-1111-1111-111111111111/new.json',
   now() - interval '1 day', now() + interval '6 days');

-- §11.6's 180 days, past and present, in both retention tables.
insert into private.preserved_content (source_kind, source_id, snapshot, file_paths, purge_after)
values
  ('act', 'bbbb0000-0000-0000-0000-000000000001', '{"title":"old"}'::jsonb,
   array['11111111-1111-1111-1111-111111111111/expired'], now() - interval '1 day'),
  ('act', 'bbbb0000-0000-0000-0000-000000000002', '{"title":"recent"}'::jsonb,
   array['11111111-1111-1111-1111-111111111111/retained'], now() + interval '90 days');
insert into private.retained_registrations
  (user_id, phone, email, account_created_at, purge_after)
values
  ('cccc0000-0000-0000-0000-000000000001', '919000000001', 'old@seva.test',
   now() - interval '400 days', now() - interval '1 day'),
  ('cccc0000-0000-0000-0000-000000000002', '919000000002', 'recent@seva.test',
   now() - interval '100 days', now() + interval '80 days');

select is_empty(
  $$ select r.rolname || ' -> ' || f.fn from
       (values ('anon'::name), ('authenticated'::name)) as r (rolname)
     cross join (values
       ('sweep_stale_uploads()'),
       ('expire_account_exports()'),
       ('purge_retained_records()'),
       ('complete_account_export(bigint,uuid,text)')) as f (fn)
     where has_function_privilege(r.rolname, f.fn, 'execute') $$,
  'no client may sweep, expire or purge (§9.1, gate 3)'
);

-- §11.6 requires the two retention functions to be definer, and §9.1 requires the rest not to be
-- unless they must. The sweep must, because nobody holds `delete` on `media`.
select ok(
  (select prosecdef from pg_proc where oid = 'purge_retained_records()'::regprocedure)
  and (select prosecdef from pg_proc where oid = 'sweep_stale_uploads()'::regprocedure)
  and not (select prosecdef from pg_proc where oid = 'expire_account_exports()'::regprocedure),
  'the purge and the sweep are definer and the export expiry is not (§11.6, §9.1)'
);

-- §11.6: "`service_role` holds nothing on the table — what it holds is `execute` on the two
-- functions a worker calls."
select ok(
  not has_table_privilege('service_role', 'private.preserved_content',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_table_privilege('service_role', 'private.retained_registrations',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and has_function_privilege('service_role', 'purge_retained_records()', 'execute'),
  'the worker reaches both retention tables only through the purge (§11.6)'
);

set local role service_role;

-- §8.1: "Uploads still sitting in `uploading` after 24 hours are deleted by the operations
-- worker."
select is(
  sweep_stale_uploads() ->> 'swept',
  '1',
  'an upload still in uploading after 24 hours is swept (§8.1)'
);

select is(
  (select count(*)::int from media where id = 'dddd0000-0000-0000-0000-000000000002'),
  1,
  'one from two hours ago is left alone, because §8.1''s window is 24 hours'
);

select is(
  (select count(*)::int from media where id = 'dddd0000-0000-0000-0000-000000000003'),
  1,
  'and a photo that completed is not an abandoned upload whatever its age'
);

-- §5.4: the files go through the delete trigger, which queues the `ops` job the worker drains.
select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'kind' = 'delete_media_files'
     and message ->> 'upload_path' = '11111111-1111-1111-1111-111111111111/stale'),
  1,
  'its file is queued for deletion through §5.4''s trigger rather than by the sweep'
);

-- §O7's seven days.
create temp table expired as select expire_account_exports() as answer;

select is(
  (select answer ->> 'expired' from expired),
  '1',
  'an export past its seven days is marked and its file queued for deletion (§7.3, O7)'
);

-- The job rather than a returned path, for the reason the review gave: the file carries a date of
-- birth and `guardian_consent`, and a worker dying between the mark and the delete left it in the
-- private bucket with nothing naming it.
reset role;
select is(
  (select message ->> 'file_path' from pgmq.q_ops
   where message ->> 'kind' = 'delete_export_file'),
  '11111111-1111-1111-1111-111111111111/old.json',
  'the job names the object, and §5.4 keeps the deletion itself out of SQL'
);

select is(
  (select count(*)::int from pgmq.q_ops where message ->> 'kind' = 'delete_export_file'),
  1,
  'and only that one: the export inside its seven days is not queued'
);
set local role service_role;

-- The orphan review found: the worker writes the object and then calls
-- `complete_account_export`, so a completion refused five times leaves §8.4 marking the row
-- `failed` with `expires_at` null — and the file, which carries a date of birth, was collectable
-- by nothing. `claim_ops_jobs` now writes `file_path` when it hands the job out, so the row names
-- its object before the object exists and `created_at` is the clock.
reset role;
insert into account_exports (id, user_id, status, file_path, created_at)
values ('ffff0000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
        'failed', '11111111-1111-1111-1111-111111111111/orphan.json',
        now() - interval '8 days');
set local role service_role;

select is(
  expire_account_exports() ->> 'file_jobs',
  '1',
  'a failed export whose file was written is collected after seven days (O7)'
);

reset role;
select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'file_path' = '11111111-1111-1111-1111-111111111111/orphan.json'),
  1,
  'so the object a completion never reached is deleted rather than left for ever'
);
set local role service_role;

select is(
  (select status::text from account_exports where id = 'ffff0000-0000-0000-0000-000000000001'),
  'expired',
  'the row is marked expired rather than deleted, so §7.3''s status is still truthful'
);

select is(
  (select status::text from account_exports where id = 'ffff0000-0000-0000-0000-000000000002'),
  'ready',
  'while one inside its seven days is untouched'
);

-- Handing the paths out once: a second run must not re-report a file the worker already deleted.
select is(
  (select (expire_account_exports() ->> 'expired')),
  '0',
  'a second run finds nothing, because the mark and the send are one statement'
);

-- §10.2's seven days, which nothing enforced before this function existed.
reset role;
insert into auth.users (id, created_at) values
  ('aaaa2222-2222-2222-2222-222222222222', now() - interval '30 days'),
  ('aaaa3333-3333-3333-3333-333333333333', now() - interval '30 days'),
  ('aaaa4444-4444-4444-4444-444444444444', now() - interval '30 days');
insert into profiles (id, display_name, status, suspended_until) values
  ('aaaa2222-2222-2222-2222-222222222222', 'served their time', 'suspended',
   now() - interval '1 minute'),
  ('aaaa3333-3333-3333-3333-333333333333', 'still serving', 'suspended',
   now() + interval '2 days'),
  ('aaaa4444-4444-4444-4444-444444444444', 'indefinite', 'suspended', null);
set local role service_role;

select is(
  clear_expired_suspensions() ->> 'cleared',
  '1',
  'a suspension whose end date has passed is lifted (§10.2)'
);

reset role;
select results_eq(
  $$ select id::text, status::text from profiles
     where id in ('aaaa2222-2222-2222-2222-222222222222',
                  'aaaa3333-3333-3333-3333-333333333333',
                  'aaaa4444-4444-4444-4444-444444444444')
     order by id $$,
  $$ values ('aaaa2222-2222-2222-2222-222222222222', 'active'),
            ('aaaa3333-3333-3333-3333-333333333333', 'suspended'),
            ('aaaa4444-4444-4444-4444-444444444444', 'suspended') $$,
  'and only that one: a live suspension and an admin-only indefinite one are untouched (§10.1)'
);
set local role service_role;

-- Two rows naming one object, with different clocks — which `delete_account` now produces on
-- purpose, because a photo's retention clock is its own and its parent Act's snapshot cannot stand
-- in for it. The expired row must not take the live row's file with it.
reset role;
insert into private.preserved_content (source_kind, source_id, snapshot, file_paths, purge_after)
values ('act', 'bbbb9999-0000-0000-0000-000000000001',
        jsonb_build_object('title', 'parent whose clock ran out first'),
        array['11111111-1111-1111-1111-111111111111/shared',
              '11111111-1111-1111-1111-111111111111/parent-only'],
        now() - interval '1 minute'),
       ('media', 'dddd9999-0000-0000-0000-000000000001',
        jsonb_build_object('purpose', 'act'),
        array['11111111-1111-1111-1111-111111111111/shared'],
        now() + interval '170 days'),
       ('activity', 'bbbb9999-0000-0000-0000-000000000002',
        jsonb_build_object('title', 'expired, and every path it names is still claimed'),
        array['11111111-1111-1111-1111-111111111111/shared'],
        now() - interval '1 minute');
set local role service_role;

-- §11.6's 180 days. The row's id is captured first, because the purge deletes it and the
-- assertions below need to tell one job from another.
reset role;
create temp table released_act as
  select id from private.preserved_content
  where source_id = 'bbbb0000-0000-0000-0000-000000000001';
set local role service_role;
create temp table purged as select purge_retained_records() as answer;

select is(
  (select answer ->> 'preserved_content' from purged),
  '3',
  'every preserved row past its 180 days is purged (§11.6, rule 3(1)(g))'
);

select is(
  (select answer ->> 'registrations' from purged),
  '1',
  'and a retained registration past its own (§11.6, rule 3(1)(h))'
);

-- The object keys leave by the queue and not in the reply, which is the review finding: the
-- rows and the files have to go in one transaction or a worker that dies between them leaves
-- an object nothing names (§11.6, `O7`).
select is(
  (select answer ->> 'file_jobs' from purged),
  '2',
  'one file-deletion job per released row with a file nothing else claims (§5.4, §11.6)'
);

reset role;
select is(
  (select message -> 'paths' from pgmq.q_ops
   where message ->> 'kind' = 'delete_retained_files'
     and message ->> 'preserved_id' = (select id::text from released_act)),
  to_jsonb(array['11111111-1111-1111-1111-111111111111/expired']),
  'carrying the keys whose retention has ended, for the worker to delete (§5.4)'
);

select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'kind' = 'delete_retained_files'
     and message -> 'paths' @> to_jsonb(array['11111111-1111-1111-1111-111111111111/retained'])),
  0,
  'and not the keys of a row still inside its window'
);
set local role service_role;

-- The shared path is not queued for deletion, because the media row still names it. Without this
-- the parent's purge would destroy a file 170 days inside its own retention.
reset role;
select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'kind' = 'delete_retained_files'
     and message -> 'paths' @> to_jsonb(array['11111111-1111-1111-1111-111111111111/shared'])),
  0,
  'a path another live retention row still names is not released (§11.6)'
);

select is(
  (select count(*)::int from private.preserved_content
   where source_id = 'dddd9999-0000-0000-0000-000000000001'),
  1,
  'and the row holding it is untouched, so the file is released when its own clock runs out'
);

-- The other half, and the half a single shared path could not measure: the released row's *own*
-- file still goes. A row is skipped whole only when every path it names is still claimed, and the
-- paths it alone named are deleted either way.
select is(
  (select message -> 'paths' from pgmq.q_ops
   where message ->> 'kind' = 'delete_retained_files'
     and message -> 'paths' @> to_jsonb(array['11111111-1111-1111-1111-111111111111/parent-only'])),
  to_jsonb(array['11111111-1111-1111-1111-111111111111/parent-only']),
  'and the job carries the paths nothing else claims, and only those (§11.6)'
);

-- A released row whose every path is still claimed sends no job at all, rather than one carrying an
-- empty array. That is the only thing the row-level guard decides, and it is noise in a queue
-- §12.5's dead-and-waiting arm reads.
select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'kind' = 'delete_retained_files'
     and jsonb_array_length(message -> 'paths') = 0),
  0,
  'a released row with nothing left to delete sends no job (§8.4, §12.5)'
);
set local role service_role;

-- §11.6's constraint on that definer frame: "neither function may return or log `phone` or
-- `email`".
select ok(
  (select answer::text not like '%919000000001%'
     and answer::text not like '%old@seva.test%'
   from purged),
  'the purge returns neither a phone number nor an email, which §11.6 forbids it (§9.8)'
);

reset role;
-- Which rows survived, not how many the table holds: a count over the whole table passes for the
-- wrong reason as soon as another fixture is added, which is how this one first broke.
select results_eq(
  $$ select source_id::text from private.preserved_content
     where source_id in ('bbbb0000-0000-0000-0000-000000000001',
                         'bbbb0000-0000-0000-0000-000000000002',
                         'bbbb9999-0000-0000-0000-000000000001',
                         'dddd9999-0000-0000-0000-000000000001')
     order by source_id $$,
  $$ values ('bbbb0000-0000-0000-0000-000000000002'),
            ('dddd9999-0000-0000-0000-000000000001') $$,
  'the rows inside their windows survive and the expired ones do not (§11.6)'
);

select is(
  (select count(*)::int from private.retained_registrations),
  1,
  'and so does the registration'
);

-- The three indexes this phase added, each for a query in this file. They are the one kind of
-- object that can be dropped without any behaviour changing until the table is large, so they are
-- asserted rather than left to a plan nobody re-measures (§5.5, CLAUDE.md's indexed-queries rule).
reset role;
select has_index('private', 'preserved_content', 'preserved_content_source',
  'the (source_kind, source_id) lookup delete_account makes once per subject is indexed');
select has_index('private', 'preserved_content', 'preserved_content_file_paths',
  'and the file_paths overlap queue_media_deletion makes once per deleted row');
select has_index('public', 'profiles', 'profiles_suspension_expiry',
  'and the suspension sweep, which scanned every profile without it (§10.2)');

select * from finish();
rollback;
