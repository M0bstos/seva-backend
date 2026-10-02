begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

insert into auth.users (id) values ('f1000000-0000-4000-8000-000000000001');
insert into profiles (id, display_name, bio)
values ('f1000000-0000-4000-8000-000000000001', 'Asha from Kothrud',
        'I clean up the riverbank on Sundays.');

insert into acts (id, author_id, title, story, category, occurred_on, location_coarse,
                  status, idempotency_key, request_hash)
values ('f1000000-0000-4000-8000-0000000000a1',
        'f1000000-0000-4000-8000-000000000001', 'A morning at the river',
        'We filled eleven sacks along the bank before the rain came in at noon.',
        'environment', current_date - 1,
        extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
        'pending', gen_random_uuid(), repeat('f', 64));

insert into media (id, owner_id, purpose, upload_path, status)
values ('f1000000-0000-4000-8000-0000000000b1',
        'f1000000-0000-4000-8000-000000000001', 'act',
        'uploads/f1000000-0000-4000-8000-000000000001/b1.jpg', 'processing');

-- §8.2's triggers have already queued the Act's text and the profile's. Everything
-- below is scoped to this file's own fixtures (§13.1), so the queue is drained first.
select pgmq.purge_queue('moderation');

select ok(
  not has_function_privilege('anon', 'claim_moderation_jobs(int)', 'execute')
  and not has_function_privilege('authenticated', 'claim_moderation_jobs(int)', 'execute'),
  'no client may claim a moderation job and read unscreened text (§9.1)'
);

select ok(
  has_function_privilege('service_role', 'claim_moderation_jobs(int)', 'execute'),
  'the worker reaches it on its own secret key (§9.5)'
);

set local role service_role;

select is(claim_moderation_jobs(10), '[]'::jsonb, 'an empty queue claims nothing');

-- §8.2: Act title and story.
select pgmq.send('moderation', jsonb_build_object(
  'kind', 'act_text', 'id', 'f1000000-0000-4000-8000-0000000000a1'));

select is(
  (claim_moderation_jobs(10) -> 0) - 'msg_id' - 'digest',
  jsonb_build_object(
    'kind', 'act_text',
    'texts', jsonb_build_array(
      'A morning at the river',
      'We filled eleven sacks along the bank before the rain came in at noon.')),
  'an act_text job arrives with the two strings §8.2 screens'
);

-- §8.4: hidden for 60 seconds while processing, so a second worker sees nothing.
select is(claim_moderation_jobs(10), '[]'::jsonb, 'and is invisible to the next claim');

-- §8.2: profile display name and bio. §8.2 makes profiles visible straight away, so
-- there is no status to check.
reset role;
select pgmq.purge_queue('moderation');
select pgmq.send('moderation', jsonb_build_object(
  'kind', 'profile_text', 'id', 'f1000000-0000-4000-8000-000000000001'));
set local role service_role;

select is(
  claim_moderation_jobs(10) -> 0 -> 'texts',
  jsonb_build_array('Asha from Kothrud', 'I clean up the riverbank on Sundays.'),
  'a profile_text job carries the display name and the bio'
);

-- §8.1 step 4: the worker needs the object it wrote in step 1, and nothing else.
reset role;
select pgmq.purge_queue('moderation');
select pgmq.send('moderation', jsonb_build_object(
  'kind', 'photo', 'id', 'f1000000-0000-4000-8000-0000000000b1'));
set local role service_role;

select is(
  (claim_moderation_jobs(10) -> 0) - 'msg_id',
  jsonb_build_object(
    'kind', 'photo',
    'upload_path', 'uploads/f1000000-0000-4000-8000-000000000001/b1.jpg',
    'purpose', 'act'),
  'a photo job carries its upload path and purpose'
);

-- Content removed by staff has nothing left to screen, and §8.4's quotas are the
-- reason that matters: the job goes rather than spending a call on it.
reset role;
select pgmq.purge_queue('moderation');
update acts set status = 'removed' where id = 'f1000000-0000-4000-8000-0000000000a1';
select pgmq.send('moderation', jsonb_build_object(
  'kind', 'act_text', 'id', 'f1000000-0000-4000-8000-0000000000a1'));
set local role service_role;

select is(
  claim_moderation_jobs(10), '[]'::jsonb,
  'a job for removed content is dropped rather than screened'
);

reset role;

select is(
  (select count(*)::int from pgmq.q_moderation), 0,
  'and it leaves the queue rather than being retried five times'
);

-- §8.4: "retried up to 5 times. After that they are archived and an alarm fires;
-- nothing is silently dropped." The alarm is `/discover/health` counting the archive.
select pgmq.purge_queue('moderation');
select pgmq.send('moderation', jsonb_build_object(
  'kind', 'act_text', 'id', 'f1000000-0000-4000-8000-0000000000a1'));
update pgmq.q_moderation set read_ct = 6, vt = now() - interval '1 minute';
set local role service_role;

select is(claim_moderation_jobs(10), '[]'::jsonb, 'a sixth delivery claims nothing');

reset role;

select is(
  (select count(*)::int from pgmq.a_moderation), 1,
  'the job is archived, which is what §12.5''s dead-job alarm reads'
);

select * from finish();
rollback;
