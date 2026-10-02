begin;
create extension if not exists pgtap with schema extensions;
select plan(25);

insert into auth.users (id, created_at)
values ('f3000000-0000-4000-8000-000000000001', now() - interval '30 days');
insert into profiles (id, display_name, bio)
values ('f3000000-0000-4000-8000-000000000001', 'Asha from Kothrud',
        'I clean up the riverbank on Sundays.');

create function pg_temp.new_act(p_id uuid) returns void
language sql as $$
  insert into acts (id, author_id, title, story, category, occurred_on,
                    location_coarse, status, idempotency_key, request_hash)
  values (p_id, 'f3000000-0000-4000-8000-000000000001', 'A morning at the river',
          'We filled eleven sacks along the bank before the rain came in at noon.',
          'environment', current_date - 1,
          extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
          'pending', gen_random_uuid(), repeat('2', 64));
$$;

create function pg_temp.queue(p_kind text, p_id uuid) returns bigint
language sql as $$
  select pgmq.send('moderation', jsonb_build_object('kind', p_kind, 'id', p_id));
$$;

select is_empty(
  $$ select r.rolname || ' -> ' || f.fn from
       (values ('anon'::name), ('authenticated'::name)) as r (rolname)
     cross join (values
       ('complete_text_screening(bigint,boolean,text)'),
       ('complete_photo_screening(bigint,media_status,jsonb,int,int,int)'),
       ('claim_moderation_jobs(int)')) as f (fn)
     where has_function_privilege(r.rolname, f.fn, 'execute') $$,
  'no client may claim a job or declare their own content screened (§9.1, §9.2)'
);

-- §8.3's pending → visible, with the text as the last thing to arrive.
select pg_temp.new_act('f3000000-0000-4000-8000-0000000000a1');
select pgmq.purge_queue('moderation');

set local role service_role;
select is(
  complete_text_screening(
  pg_temp.queue('act_text', 'f3000000-0000-4000-8000-0000000000a1'), false,
  private.text_digest('act_text', 'f3000000-0000-4000-8000-0000000000a1')) ->> 'kind',
  'act_text',
  'a passed Act reports the kind it screened'
);

select is(
  (select status::text from acts where id = 'f3000000-0000-4000-8000-0000000000a1'),
  'visible',
  'and an Act with no photos publishes on its text alone (§8.3)'
);

select is(
  (select points from impact_entries
   where act_id = 'f3000000-0000-4000-8000-0000000000a1' and kind = 'act_published'),
  10,
  'with §6.1''s points awarded by the same transaction'
);

select is(
  (select count(*)::int from pgmq.q_moderation), 0,
  'and the job is gone from the queue, not retried'
);

-- §8.3's pending → held.
reset role;
select pg_temp.new_act('f3000000-0000-4000-8000-0000000000a2');
set local role service_role;
select complete_text_screening(
  pg_temp.queue('act_text', 'f3000000-0000-4000-8000-0000000000a2'), true,
  private.text_digest('act_text', 'f3000000-0000-4000-8000-0000000000a2'));

select results_eq(
  $$ select status::text, text_checked from acts
     where id = 'f3000000-0000-4000-8000-0000000000a2' $$,
  $$ values ('held', true) $$,
  'a flagged Act is held, and records that screening happened (§8.3)'
);

select is(
  (select count(*)::int from impact_entries
   where act_id = 'f3000000-0000-4000-8000-0000000000a2'),
  0,
  'held content never earned points, so there is nothing to reverse (§6.2)'
);

-- §8.2: a flagged profile has its text hidden; the worker never clears the flag.
select complete_text_screening(
  pg_temp.queue('profile_text', 'f3000000-0000-4000-8000-000000000001'), true,
  private.text_digest('profile_text', 'f3000000-0000-4000-8000-000000000001'));

select ok(
  (select text_hidden from profiles where id = 'f3000000-0000-4000-8000-000000000001'),
  'a flagged display name or bio is hidden pending staff review (§8.2)'
);

select complete_text_screening(
  pg_temp.queue('profile_text', 'f3000000-0000-4000-8000-000000000001'), false,
  private.text_digest('profile_text', 'f3000000-0000-4000-8000-000000000001'));

select ok(
  (select text_hidden from profiles where id = 'f3000000-0000-4000-8000-000000000001'),
  'and a later pass does not lift it: that is a staff decision (§8.2, `O14`)'
);

-- §8.4 hides a job for 60 seconds; past that another worker may have finished it.
select is(
  complete_text_screening(999999999, false, 'whatever') ->> 'error',
  'NOT_FOUND',
  'a job that is already gone is work done, not an error to retry'
);

-- §8.1 step 4, and §8.3's pending → visible with a photo as the last to arrive.
reset role;
select pg_temp.new_act('f3000000-0000-4000-8000-0000000000a3');
update acts set text_checked = true where id = 'f3000000-0000-4000-8000-0000000000a3';
insert into media (id, owner_id, purpose, act_id, upload_path, status)
values ('f3000000-0000-4000-8000-0000000000b1',
        'f3000000-0000-4000-8000-000000000001', 'act',
        'f3000000-0000-4000-8000-0000000000a3', 'uploads/f3/b1.jpg', 'processing');
set local role service_role;

select is(
  complete_photo_screening(
    pg_temp.queue('photo', 'f3000000-0000-4000-8000-0000000000b1'),
    'ready', '{"Alcohol": 62}'::jsonb, 204800, 1600, 1200
  ) ->> 'status',
  'ready',
  'a passed photo is ready'
);

select results_eq(
  $$ select status::text, public_path, width from media
     where id = 'f3000000-0000-4000-8000-0000000000b1' $$,
  $$ values ('ready', 'uploads/f3/b1.jpg', 1600) $$,
  'with the published copy and its dimensions on the row'
);

select is(
  (select status::text from acts where id = 'f3000000-0000-4000-8000-0000000000a3'),
  'visible',
  'and the Act it belongs to publishes, text and every photo having passed (§8.3)'
);

-- `O21`: the verdict goes to its own table, for a passed photo as much as a held one,
-- because §8.4 tunes the threshold on real uploads during the beta.
reset role;
select is(
  (select labels ->> 'Alcohol' from media_labels
   where media_id = 'f3000000-0000-4000-8000-0000000000b1'),
  '62',
  'the screening verdict is kept where no client can read it'
);

-- §8.3: "pending → held | Any check flags", for a photo as much as for text.
select pg_temp.new_act('f3000000-0000-4000-8000-0000000000a4');
update acts set text_checked = true where id = 'f3000000-0000-4000-8000-0000000000a4';
insert into media (id, owner_id, purpose, act_id, upload_path, status)
values ('f3000000-0000-4000-8000-0000000000b2',
        'f3000000-0000-4000-8000-000000000001', 'act',
        'f3000000-0000-4000-8000-0000000000a4', 'uploads/f3/b2.jpg', 'processing');
set local role service_role;
select complete_photo_screening(
  pg_temp.queue('photo', 'f3000000-0000-4000-8000-0000000000b2'),
  'held', '{"Explicit": 91}'::jsonb, null, null, null);

select results_eq(
  $$ select (select status::text from media
             where id = 'f3000000-0000-4000-8000-0000000000b2'),
            (select status::text from acts
             where id = 'f3000000-0000-4000-8000-0000000000a4') $$,
  $$ values ('held', 'held') $$,
  'a flagged photo holds itself and the Act it was attached to'
);

-- §8.1: an avatar that passes is the only way `profiles.avatar_path` is ever written.
reset role;
insert into media (id, owner_id, purpose, upload_path, status)
values ('f3000000-0000-4000-8000-0000000000b3',
        'f3000000-0000-4000-8000-000000000001', 'avatar',
        'uploads/f3/b3.jpg', 'processing');
set local role service_role;
select complete_photo_screening(
  pg_temp.queue('photo', 'f3000000-0000-4000-8000-0000000000b3'),
  'ready', null, 102400, 480, 480);

select is(
  (select avatar_path from profiles where id = 'f3000000-0000-4000-8000-000000000001'),
  'uploads/f3/b3.jpg',
  'an avatar reaches the profile only once its photo has passed (§8.1, §9.2)'
);

-- §5.3's `uploading` and `processing` are states, not verdicts: a photo parked in one
-- would sit where §12.5's stuck-screening arm can never clear it.
select throws_ok(
  $$ select complete_photo_screening(1, 'processing', null, 1, 1, 1) $$,
  'complete_photo_screening takes ready, held or rejected',
  'a state rather than a verdict is refused'
);

reset role;

-- The defect `private.text_digest` exists for, reproduced and then kept closed. §8's
-- rule: content leaves `pending` only when its text has passed.
select pg_temp.new_act('f3000000-0000-4000-8000-0000000000a5');
select pgmq.purge_queue('moderation');
select pg_temp.queue('act_text', 'f3000000-0000-4000-8000-0000000000a5');

-- A job is claimed and the benign title passes, but the verdict is still in flight.
set local role service_role;
create temporary table in_flight as
select claim_moderation_jobs(10) -> 0 ->> 'digest' as digest;
reset role;

-- Meanwhile the author edits the title to something abusive. §8.2's trigger queues a
-- job of its own for the new text.
update acts set title = 'Abusive unscreened headline', text_checked = false
where id = 'f3000000-0000-4000-8000-0000000000a5';

set local role service_role;

select is(
  complete_text_screening(
    (select min(msg_id) from pgmq.q_moderation
     where message ->> 'id' = 'f3000000-0000-4000-8000-0000000000a5'),
    false,
    (select digest from in_flight)
  ) ->> 'error',
  'NOT_FOUND',
  'a pass for text the author has since replaced is refused, not applied'
);

select is(
  (select status::text from acts where id = 'f3000000-0000-4000-8000-0000000000a5'),
  'pending',
  'so the abusive title does not publish on the old verdict (§8)'
);

select is(
  (select count(*)::int from impact_entries
   where act_id = 'f3000000-0000-4000-8000-0000000000a5'),
  0,
  'and §6.1 pays nothing for it'
);

-- The verdict for the text that is actually live does apply.
select is(
  complete_text_screening(
    (select max(msg_id) from pgmq.q_moderation
     where message ->> 'id' = 'f3000000-0000-4000-8000-0000000000a5'),
    true,
    private.text_digest('act_text', 'f3000000-0000-4000-8000-0000000000a5')
  ) ->> 'kind',
  'act_text',
  'while the verdict for the text that is live is accepted'
);

select is(
  (select status::text from acts where id = 'f3000000-0000-4000-8000-0000000000a5'),
  'held',
  'and holds it (§8.3)'
);

-- §8.4 hid the job for 60 seconds; a result produced against a lapsed claim is one to
-- discard, because another worker may already have taken it.
reset role;
select pg_temp.new_act('f3000000-0000-4000-8000-0000000000a6');
update acts set text_checked = true where id = 'f3000000-0000-4000-8000-0000000000a6';
select pgmq.purge_queue('moderation');
select pg_temp.queue('act_text', 'f3000000-0000-4000-8000-0000000000a6');
set local role service_role;
select claim_moderation_jobs(10);
reset role;
update pgmq.q_moderation set vt = now() - interval '1 second';
set local role service_role;

select is(
  complete_text_screening(
    (select min(msg_id) from pgmq.q_moderation), false,
    private.text_digest('act_text', 'f3000000-0000-4000-8000-0000000000a6')
  ) ->> 'error',
  'NOT_FOUND',
  'a verdict produced after the claim lapsed is discarded (§8.4)'
);

-- The two mismatch branches: a photo job sent to the text completion and the reverse.
-- Both messages are claimed first, because a completion only acts on a message that is
-- still hidden — which is the §8.4 window, and is itself the assertion above.
reset role;
select pgmq.purge_queue('moderation');
insert into media (id, owner_id, purpose, upload_path, status)
values ('f3000000-0000-4000-8000-0000000000b4',
        'f3000000-0000-4000-8000-000000000001', 'act',
        'uploads/f3/b4.jpg', 'processing');
select pg_temp.queue('photo', 'f3000000-0000-4000-8000-0000000000b4');
select pg_temp.queue('act_text', 'f3000000-0000-4000-8000-0000000000a6');
set local role service_role;
select claim_moderation_jobs(10);

select is(
  complete_text_screening(
    (select min(msg_id) from pgmq.q_moderation
     where message ->> 'kind' = 'photo'), false, 'x'
  ) ->> 'field',
  'msg_id',
  'a photo job sent to the text completion names the argument that was wrong'
);

select is(
  complete_photo_screening(
    (select min(msg_id) from pgmq.q_moderation
     where message ->> 'kind' = 'act_text'), 'ready', null, 1, 1, 1
  ) ->> 'field',
  'msg_id',
  'and a text job sent to the photo completion does the same'
);

reset role;
select * from finish();
rollback;
