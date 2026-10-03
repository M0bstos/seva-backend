begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

-- §16 week 3-4's deliverable, driven end to end: an Act created through the route's
-- own function, screened through the three calls the worker makes, and the points,
-- totals and campaign progress that follow. Every piece has its own test; this is the
-- one that proves they compose, and the only place the order of §8.3's two halves is
-- exercised — text first, photo last.
insert into auth.users (id, created_at)
values ('fa000000-0000-4000-8000-000000000001', now() - interval '30 days');
insert into profiles (id, display_name)
values ('fa000000-0000-4000-8000-000000000001', 'Acceptance');

insert into campaigns (id, title, description, goal_metric, goal_value,
                       starts_on, ends_on, status)
values ('fa000000-0000-4000-8000-0000000000c1', 'Clean the Mula-Mutha',
        'Sacks of waste off the riverbank.', 'waste_kg', 5000,
        current_date - 10, current_date + 80, 'active');

insert into activities (id, organiser_id, title, description, category, starts_at,
                        ends_at, location, location_label, capacity, campaign_id,
                        status, text_checked, idempotency_key, request_hash)
values ('fa000000-0000-4000-8000-0000000000a1',
        'fa000000-0000-4000-8000-000000000001', 'Riverbank clean-up',
        'Bring gloves. We meet by the bridge and work upstream until noon.',
        'environment', now() - interval '2 days',
        now() - interval '2 days' + interval '4 hours',
        extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
        'Under the Z bridge', 40, 'fa000000-0000-4000-8000-0000000000c1',
        'visible', true, gen_random_uuid(), repeat('a', 64));

-- §2.1: the author joined it, and it has started.
insert into activity_participants (activity_id, user_id)
values ('fa000000-0000-4000-8000-0000000000a1', 'fa000000-0000-4000-8000-000000000001');

-- §8.1 steps 1-3 are the uploads route's, which is week 4-5. The row it leaves behind
-- is what the worker picks up.
insert into media (id, owner_id, purpose, upload_path, status)
values ('fa000000-0000-4000-8000-0000000000b1',
        'fa000000-0000-4000-8000-000000000001', 'act',
        'fa000000-0000-4000-8000-000000000001/b1.jpg', 'processing');

select pgmq.purge_queue('moderation');

set local role service_role;

select is(
  create_act('fa000000-0000-4000-8000-000000000001', 'A morning at the river',
    'We filled eleven sacks along the bank before the rain came in at noon.',
    'environment', current_date - 1, 73.8567, 18.5204,
    'fa000000-0000-4000-8000-0000000000a1', '{"waste_kg": 12}'::jsonb,
    array['fa000000-0000-4000-8000-0000000000b1']::uuid[],
    gen_random_uuid(), repeat('f', 64), 'acts:fa', null, 10, 30
  ) -> 'act' ->> 'status',
  'pending',
  'an Act arrives pending, whatever its author claims (§8.2)'
);

select is(
  (select count(*)::int from impact_entries
   where user_id = 'fa000000-0000-4000-8000-000000000001'), 0,
  'and has earned nothing: §6.1 pays on publication, not on creation'
);

-- The photo job's producer is `POST /uploads/:id/complete` (§8.1 step 3), week 4-5.
-- Standing in for it is the only part of this chain not yet built.
reset role;
select pgmq.send('moderation', jsonb_build_object(
  'kind', 'photo', 'id', 'fa000000-0000-4000-8000-0000000000b1'));
set local role service_role;

create temporary table claimed as
select jsonb_array_elements(claim_moderation_jobs(10)) as job;

select is(
  (select count(*)::int from claimed), 2,
  'the worker claims both jobs §8.2 and §8.1 queued for one Act'
);

-- What the claim handed over, which the completions are given below rather than
-- recomputing. §8.4's digest handshake is the link this file exists to compose: a
-- verdict keyed on a content id alone landed on text edited since — reproduced, and
-- it published unscreened text.
select is(
  (select job -> 'texts' from claimed where job ->> 'kind' = 'act_text'),
  jsonb_build_array('A morning at the river',
    'We filled eleven sacks along the bank before the rain came in at noon.'),
  'carrying the two strings §8.2 screens'
);

select is(
  (select job ->> 'upload_path' from claimed where job ->> 'kind' = 'photo'),
  'fa000000-0000-4000-8000-000000000001/b1.jpg',
  'and the object §8.1 step 1 wrote'
);

-- §8's rule, from the text side: passing the text alone is not enough.
select is(
  complete_text_screening(
    (select (job ->> 'msg_id')::bigint from claimed where job ->> 'kind' = 'act_text'),
    false,
    (select job ->> 'digest' from claimed where job ->> 'kind' = 'act_text')
  ) ->> 'kind',
  'act_text',
  'the text passes, on the digest the claim handed over rather than a fresh one'
);

select is(
  (select status::text from acts where author_id = 'fa000000-0000-4000-8000-000000000001'),
  'pending',
  'and the Act stays pending, because a photo is still processing (§8.3)'
);

-- §8.4's 80%-in-four-categories rule is the worker's `holdsPhoto`, not this
-- function's: the outcome arrives as an argument. The labels are the shape the worker
-- sends, so §10.3's screen has something of the right form to read.
select is(
  complete_photo_screening(
    (select (job ->> 'msg_id')::bigint from claimed where job ->> 'kind' = 'photo'),
    'ready',
    '{"model_version": "7.0", "labels": [{"Name": "Alcohol", "Confidence": 61}]}'::jsonb,
    204800, 1600, 1200
  ) ->> 'status',
  'ready',
  'the worker''s verdict for the photo is recorded as ready'
);

reset role;

select is(
  (select status::text from acts where author_id = 'fa000000-0000-4000-8000-000000000001'),
  'visible',
  'and now the Act publishes: text and every photo have passed (§8.3)'
);

-- §6.3's table, summed: 10 for publishing, 10 for documenting the Activity the author
-- joined, and 12 kg of waste at 2 a kg.
select results_eq(
  $$ select points, acts_count, waste_kg, activities_joined from impact_totals
     where user_id = 'fa000000-0000-4000-8000-000000000001' $$,
  $$ values (10 + 10 + 24, 1, 12.00::numeric(12,2), 1) $$,
  '§6.3''s values land in the totals, and joining earned none of them'
);

-- §6.1: the campaign is reached through the Activity the Act documents, and advances
-- by the kilograms claimed rather than by the points earned.
select results_eq(
  $$ select (select progress_value from campaigns
             where id = 'fa000000-0000-4000-8000-0000000000c1'),
            (select count(*)::int from impact_entries),
            (select public_path from media
             where id = 'fa000000-0000-4000-8000-0000000000b1') $$,
  $$ values (12.00::numeric(12,2), 3,
             'fa000000-0000-4000-8000-000000000001/b1.jpg'::text) $$,
  'the campaign advances, three ledger rows exist, and the copy is published'
);

-- §6.2's other half, on the Act this file actually published rather than on a
-- hand-made ledger row: "When staff remove an Act, its ledger rows are deleted and
-- the totals triggers subtract them." §6.4: "removing fraudulent content subtracts
-- exactly what it added." Week 4-5's `admin_set_content_status` is what will do the
-- deleting; this is the guarantee it rests on.
delete from impact_entries where act_id = (select id from acts where author_id = 'fa000000-0000-4000-8000-000000000001');

select results_eq(
  $$ select points, acts_count, waste_kg from impact_totals
     where user_id = 'fa000000-0000-4000-8000-000000000001' $$,
  $$ values (0, 0, 0.00::numeric(12,2)) $$,
  'removing the ledger takes the totals back to exactly zero (§6.2, §6.4)'
);

select is(
  (select progress_value from campaigns
   where id = 'fa000000-0000-4000-8000-0000000000c1'),
  0.00::numeric(12,2),
  'and the campaign with them, so a reversal cannot leave progress overstated'
);

-- §6.2: "Because the ledger is the source of truth, totals can always be rebuilt from
-- it." The one column that cannot is `activities_joined`, which §6.1 keeps out of the
-- ledger deliberately — so it survives a reversal, as §17.1 records.
select is(
  (select activities_joined from impact_totals
   where user_id = 'fa000000-0000-4000-8000-000000000001'),
  1,
  'while the joined count stands, rebuilding from activity_participants instead'
);

select * from finish();
rollback;
