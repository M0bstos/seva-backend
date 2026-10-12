begin;
create extension if not exists pgtap with schema extensions;
select plan(36);

insert into auth.users (id, created_at) values
  ('11111111-1111-1111-1111-111111111111', now() - interval '30 days'),
  ('99999999-9999-9999-9999-999999999999', now() - interval '60 days');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'anand'),
  ('99999999-9999-9999-9999-999999999999', 'moderator');

insert into acts (id, author_id, title, story, category, occurred_on, location_coarse,
                  status, text_checked, idempotency_key, request_hash)
values ('bbbb0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        'Cleared the lake shore',
        'We filled twelve sacks with plastic from the east bank this morning.',
        'environment', '2026-10-12',
        extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
        'pending', true, '00000000-0000-0000-0000-0000000000b1', repeat('a', 64));

-- One photo a moderator has approved, which `set_content_status` leaves in `processing`, and one
-- avatar in the same state so §8.1's `avatar_path` write has a subject.
insert into media (id, owner_id, purpose, act_id, upload_path, status) values
  ('dddd0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'act', 'bbbb0000-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111/one', 'processing');
insert into media (id, owner_id, purpose, upload_path, status) values
  ('dddd0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'avatar', '11111111-1111-1111-1111-111111111111/avatar', 'processing'),
  -- Held rather than processing: a job naming it is one staff have since taken back.
  ('dddd0000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   'avatar', '11111111-1111-1111-1111-111111111111/held', 'held');

select is_empty(
  $$ select r.rolname || ' -> ' || f.fn from
       (values ('anon'::name), ('authenticated'::name)) as r (rolname)
     cross join (values
       ('claim_ops_jobs(int)'),
       ('complete_ops_job(bigint, text)'),
       ('complete_photo_publication(bigint)'),
       ('complete_sign_out(bigint)')) as f (fn)
     where has_function_privilege(r.rolname, f.fn, 'execute') $$,
  'no client may claim or complete an ops job (§9.1, gate 3)'
);

-- §9.1 asks for definer only where it is required. `complete_sign_out` is the one of the four
-- that is, because no other role may touch `auth.sessions`.
select ok(
  (select prosecdef from pg_proc where oid = 'complete_sign_out(bigint)'::regprocedure)
  and not (select prosecdef from pg_proc where oid = 'claim_ops_jobs(int)'::regprocedure)
  and not (select prosecdef from pg_proc where oid = 'complete_ops_job(bigint, text)'::regprocedure)
  and not (select prosecdef from pg_proc
           where oid = 'complete_photo_publication(bigint)'::regprocedure),
  'only the sign-out is definer, because only it writes a table no role holds (§9.1)'
);

set local role service_role;

select throws_ok(
  $$ select claim_ops_jobs(0) $$,
  'P0001',
  'claim_ops_jobs takes a count between 1 and 100',
  'an unbounded claim is refused, because one call would hide the whole queue (§8.4)'
);

-- §5.4's trigger shape: three paths and no buckets, which §17.1 decided the worker resolves.
select pgmq.send('ops', jsonb_build_object(
  'kind', 'delete_media_files', 'media_id', gen_random_uuid(),
  'upload_path', 'gone/one', 'public_path', 'gone/one', 'thumb_path', null));

create temp table deletion as select claim_ops_jobs(10) as jobs;

select is(
  (select jobs #>> '{0,kind}' from deletion),
  'delete_media_files',
  'a file-deletion job is handed out as §5.4''s trigger wrote it'
);

select is(
  (select jobs #>> '{0,upload_path}' from deletion),
  'gone/one',
  'with its paths passed through, because the row they described is already gone'
);

select is(
  complete_ops_job((select (jobs #>> '{0,msg_id}')::bigint from deletion),
    'delete_media_files') ->> 'status',
  'done',
  'and the worker closes it inside §8.4''s 60-second window'
);

select is(
  complete_ops_job(999999, 'delete_media_files') ->> 'error',
  'NOT_FOUND',
  'a msg_id nobody claimed is refused, so the id is a capability (§8.4, §17.1)'
);

-- §8.4 binds a verdict to **what it is about** as well as to when it was claimed, and until review
-- this function had only the second half: a live job of any kind could be closed by any other
-- kind's handler, leaving the work undone and the message in neither the queue nor the archive —
-- which none of §12.5's eleven arms can see. Reproduced on a `delete_account` job.
select pgmq.send('ops', jsonb_build_object(
  'kind', 'delete_account', 'user_id', '11111111-1111-1111-1111-111111111111'));

create temp table erasure as select claim_ops_jobs(10) as jobs;

select is(
  complete_ops_job((select (jobs #>> '{0,msg_id}')::bigint from erasure),
    'delete_media_files') ->> 'error',
  'NOT_FOUND',
  'a live claim cannot be closed by the wrong kind, so a dropped erasure stays visible (§8.4)'
);

select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'kind' = 'delete_account'),
  1,
  'and the job is still in the queue, where §12.5''s waiting-jobs arm can find it'
);

select is(
  complete_ops_job((select (jobs #>> '{0,msg_id}')::bigint from erasure),
    'delete_account') ->> 'status',
  'done',
  'while its own kind closes it'
);

-- The five kinds the allowlist admits that no test claimed. A kind missing from that list is
-- archived in silence, which is the one failure mode §8.4 and §12.5 are written about — so each
-- one is claimed here rather than trusted to the list being right.
select pgmq.send('ops', jsonb_build_object('kind', 'quarantine_file', 'path', 'gone/two'));
select pgmq.send('ops', jsonb_build_object(
  'kind', 'export_account', 'user_id', '11111111-1111-1111-1111-111111111111',
  'export_id', gen_random_uuid()));
select pgmq.send('ops', jsonb_build_object(
  'kind', 'delete_retained_files', 'preserved_id', gen_random_uuid(),
  'paths', to_jsonb(array['gone/three'])));
select pgmq.send('ops', jsonb_build_object(
  'kind', 'delete_export_file', 'export_id', gen_random_uuid(),
  'file_path', 'gone/four.json'));
select pgmq.send('ops', jsonb_build_object(
  'kind', 'sign_out', 'user_id', '11111111-1111-1111-1111-111111111111'));

create temp table rest as select claim_ops_jobs(10) as jobs;

select is(
  (select count(*)::int from jsonb_array_elements((select jobs from rest))),
  5,
  'every kind the allowlist admits is handed out rather than archived (§8.4)'
);

select results_eq(
  $$ select distinct e ->> 'kind' from jsonb_array_elements((select jobs from rest)) e
     order by 1 $$,
  $$ values ('delete_export_file'), ('delete_retained_files'), ('export_account'),
            ('quarantine_file'), ('sign_out') $$,
  'and each by its own name, so the allowlist and the worker''s switch cannot drift apart'
);

-- Closed again, each by its own kind, so the queue is empty for the whole-queue assertion below —
-- which is this file's own fixture rather than a shared table.
select is(
  (select count(*)::int from jsonb_array_elements((select jobs from rest)) e
   where complete_ops_job((e ->> 'msg_id')::bigint, e ->> 'kind') ->> 'status' = 'done'),
  5,
  'and each closes under its own kind, which is the pairing §8.4 asks for'
);

-- §8.3's held → visible for a photo, which §17.1 recorded as having had no writer.
select pgmq.send('ops', jsonb_build_object(
  'kind', 'publish_photo', 'media_id', 'dddd0000-0000-0000-0000-000000000001'));

create temp table publication as select claim_ops_jobs(10) as jobs;

select is(
  (select jobs #>> '{0,upload_path}' from publication),
  '11111111-1111-1111-1111-111111111111/one',
  'a publication job carries the path read off the row, not one the message chose (§8.1)'
);

select is(
  complete_photo_publication((select (jobs #>> '{0,msg_id}')::bigint from publication))
    ->> 'status',
  'ready',
  'and the completion turns the photo ready (§8.3)'
);

select is(
  (select public_path from media where id = 'dddd0000-0000-0000-0000-000000000001'),
  '11111111-1111-1111-1111-111111111111/one',
  'publishing under the same key §8.1 fixes, derived rather than supplied (§17.1)'
);

-- §8's rule that an Act leaves `pending` only when text and every photo have passed.
select is(
  (select status::text from acts where id = 'bbbb0000-0000-0000-0000-000000000001'),
  'visible',
  'and the parent content publishes, because publish_if_screened is called (§8, §8.3)'
);

-- §8.1: "The moderation worker sets `profiles.avatar_path` once the photo passes", and a staff
-- approval is the other way a photo passes.
select pgmq.send('ops', jsonb_build_object(
  'kind', 'publish_photo', 'media_id', 'dddd0000-0000-0000-0000-000000000002'));
create temp table avatar as select claim_ops_jobs(10) as jobs;
select is(
  complete_photo_publication((select (jobs #>> '{0,msg_id}')::bigint from avatar)) ->> 'status',
  'ready',
  'an approved avatar publishes too'
);

select is(
  (select avatar_path from profiles where id = '11111111-1111-1111-1111-111111111111'),
  '11111111-1111-1111-1111-111111111111/avatar',
  'and sets profiles.avatar_path, which §9.2 gives no client a write on (§8.1)'
);

-- §8.4's "after that they are archived and an alarm fires; nothing is silently dropped", and the
-- two-table write inside it, which had no test at all. `read_ct` is pgmq's own counter, so the
-- branch is reached by claiming the same job six times rather than by writing the column.
reset role;
insert into auth.users (id, created_at)
values ('aaaa5555-5555-5555-5555-555555555555', now() - interval '30 days');
insert into profiles (id, display_name)
values ('aaaa5555-5555-5555-5555-555555555555', 'asked to be erased');
insert into account_deletions (user_id) values ('aaaa5555-5555-5555-5555-555555555555');
select pgmq.send('ops', jsonb_build_object(
  'kind', 'delete_account', 'user_id', 'aaaa5555-5555-5555-5555-555555555555'));
set local role service_role;

-- Six claims. `read_ct` is pgmq's own counter and only `pgmq.read` raises it, so each claim has to
-- be made visible again first — which is what a worker dying mid-job does by letting `vt` lapse.
create function pg_temp.claim_six() returns int language plpgsql as $f$
declare
  v_id bigint;
  v_claims int := 0;
begin
  select msg_id into v_id from pgmq.q_ops where message ->> 'kind' = 'delete_account';
  for i in 1 .. 6 loop
    perform pgmq.set_vt('ops', v_id, 0);
    if jsonb_array_length(public.claim_ops_jobs(10)) > 0 then
      v_claims := v_claims + 1;
    end if;
  end loop;
  return v_claims;
end;
$f$;

select is(
  pg_temp.claim_six(),
  5,
  'a job is handed out five times and the sixth claim archives it instead (§8.4)'
);

reset role;
select is(
  (select status::text from account_deletions
   where user_id = 'aaaa5555-5555-5555-5555-555555555555'),
  'failed',
  'an erasure that keeps failing is marked failed, so the person can ask again (§8.4, §5.2.1)'
);

select ok(
  (select attempts >= 1 from account_deletions
   where user_id = 'aaaa5555-5555-5555-5555-555555555555'),
  'with the attempt counted, which §5.2.1 gives the column for'
);

select is(
  (select count(*)::int from pgmq.a_ops where message ->> 'kind' = 'delete_account'),
  1,
  'and the job is archived, which is the one row §12.5''s dead-job arm looks for (§8.4)'
);
set local role service_role;

-- The two starvations review reproduced. A malformed uuid in a message raised inside the claim
-- loop, and the raise rolled back `pgmq.read`'s own visibility update — so the message could never
-- be archived, no alarm could fire, and every later job in the batch went with it. §17.1 measured
-- the same mechanism on the moderation queue on 2 October; these are the same bug in two new places
-- on the queue that carries erasures, takedown file moves and both retention clocks.
--
-- A well-formed job is queued behind each malformed one, because what the defect destroyed was the
-- whole batch and not only the bad message.
select pgmq.send('ops', jsonb_build_object(
  'kind', 'export_account', 'user_id', 'not-a-uuid', 'export_id', 'not-a-uuid'));
select pgmq.send('ops', jsonb_build_object(
  'kind', 'quarantine_file', 'path', 'gone/behind-the-bad-one'));

create temp table after_bad_export as select claim_ops_jobs(10) as jobs;

select is(
  (select count(*)::int from jsonb_array_elements((select jobs from after_bad_export)) e
   where e ->> 'kind' = 'quarantine_file'),
  1,
  'a malformed export message does not take the job behind it down (§8.4, §17.1)'
);

select is(
  (select count(*)::int from pgmq.a_ops where message ->> 'user_id' = 'not-a-uuid'),
  1,
  'and it reaches the archive, which is the one row §12.5''s dead-job arm can see'
);

select is(
  (select count(*)::int from jsonb_array_elements((select jobs from after_bad_export)) e
   where complete_ops_job((e ->> 'msg_id')::bigint, e ->> 'kind') ->> 'status' = 'done'),
  1,
  'and the good job closes normally afterwards'
);

-- The archive branch, which is the harder half: the cast is inside the branch that exists to
-- archive, so a malformed `user_id` raised on the sixth read — exactly when §8.4 wants the archive.
select pgmq.send('ops', jsonb_build_object(
  'kind', 'delete_account', 'user_id', 'also-not-a-uuid'));

create function pg_temp.claim_six_bad() returns int language plpgsql as $f$
declare
  v_id bigint;
  v_claims int := 0;
begin
  select msg_id into v_id from pgmq.q_ops where message ->> 'user_id' = 'also-not-a-uuid';
  for i in 1 .. 6 loop
    perform pgmq.set_vt('ops', v_id, 0);
    if jsonb_array_length(public.claim_ops_jobs(10)) > 0 then
      v_claims := v_claims + 1;
    end if;
  end loop;
  return v_claims;
end;
$f$;

select is(
  pg_temp.claim_six_bad(),
  5,
  'a malformed erasure message is handed out five times and then archived, not re-read for ever'
);

select is(
  (select count(*)::int from pgmq.a_ops where message ->> 'user_id' = 'also-not-a-uuid'),
  1,
  'so §8.4''s "nothing is silently dropped" holds for a message nothing can identify'
);

-- A photo staff took back between the approval and the worker: §17.1's clobber, in this path.
select pgmq.send('ops', jsonb_build_object(
  'kind', 'publish_photo', 'media_id', 'dddd0000-0000-0000-0000-000000000003'));
select is(
  jsonb_array_length(claim_ops_jobs(10)),
  0,
  'a photo no longer processing is not handed out, so no takedown is republished (§11.6)'
);

select is(
  (select count(*)::int from pgmq.q_ops),
  0,
  'and that job is dropped rather than retried, because there is nothing to retry (§8.4)'
);

-- §10.2's sign-out, bound to the job rather than to a user id.
select pgmq.send('ops', jsonb_build_object(
  'kind', 'sign_out', 'user_id', '11111111-1111-1111-1111-111111111111'));
create temp table signout as select claim_ops_jobs(10) as jobs;

select is(
  (select jobs #>> '{0,user_id}' from signout),
  '11111111-1111-1111-1111-111111111111',
  'a sign-out job names the suspended person (§10.2)'
);

select is(
  complete_sign_out((select (jobs #>> '{0,msg_id}')::bigint from signout)) ->> 'revoked',
  '0',
  'and the completion reports a count of sessions, never a session (§9.8)'
);

-- The capability is the job, not the function: a msg_id that is not a sign-out is refused, so a
-- secret key cannot sign out anybody a staff suspension did not queue.
select pgmq.send('ops', jsonb_build_object(
  'kind', 'delete_media_files', 'media_id', gen_random_uuid(),
  'upload_path', 'other/one', 'public_path', null, 'thumb_path', null));
create temp table other as select claim_ops_jobs(10) as jobs;
select is(
  complete_sign_out((select (jobs #>> '{0,msg_id}')::bigint from other)) ->> 'field',
  'msg_id',
  'a job of another kind cannot be used to sign somebody out (§10.2, §9.1)'
);

select is(
  complete_photo_publication((select (jobs #>> '{0,msg_id}')::bigint from other)) ->> 'field',
  'msg_id',
  'nor to publish a photo'
);

-- §8.4's "nothing is silently dropped" for a kind nothing sends.
select pgmq.send('ops', jsonb_build_object('kind', 'invented'));
select is(
  jsonb_array_length(claim_ops_jobs(10)),
  0,
  'a kind no producer writes is not handed to the worker'
);

select is(
  (select count(*)::int from pgmq.a_ops where message ->> 'kind' = 'invented'),
  1,
  'it is archived, which §12.5''s dead-job arm is what sees (§8.4)'
);

reset role;
select * from finish();
rollback;
