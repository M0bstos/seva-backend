begin;
create extension if not exists pgtap with schema extensions;
select plan(60);

insert into auth.users (id, created_at) values
  ('11111111-1111-1111-1111-111111111111', now() - interval '30 days'),
  ('99999999-9999-9999-9999-999999999999', now() - interval '60 days');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'anand'),
  ('99999999-9999-9999-9999-999999999999', 'moderator');
insert into staff (user_id, role) values
  ('99999999-9999-9999-9999-999999999999', 'moderator');

insert into campaigns (id, title, description, goal_metric, goal_value,
                       starts_on, ends_on, status)
values ('cccc0000-0000-0000-0000-000000000001', 'Clean the lake',
        'Volunteers clearing plastic from the lake shore every weekend.',
        'waste_kg', 5000, '2026-10-01', '2026-12-31', 'active');

insert into activities (id, organiser_id, title, description, category, starts_at, ends_at,
                        location, location_label, capacity, campaign_id, status,
                        idempotency_key, request_hash)
values ('aaaa0000-0000-0000-0000-000000000001',
        '99999999-9999-9999-9999-999999999999', 'Lake shore cleanup',
        'Bring gloves and water. We meet at the east gate and finish before noon.',
        'environment', now() - interval '2 days', now() - interval '2 days' + interval '3 hours',
        extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
        'East gate', 40, 'cccc0000-0000-0000-0000-000000000001', 'visible',
        '00000000-0000-0000-0000-0000000000a1', repeat('a', 64));
insert into activity_participants (activity_id, user_id)
values ('aaaa0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111');

-- Four Acts: one published and earning, one held, one pending, one already removed.
insert into acts (id, author_id, activity_id, title, story, category, occurred_on,
                  location_coarse, status, text_checked, idempotency_key, request_hash)
values
  ('bbbb0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'aaaa0000-0000-0000-0000-000000000001', 'Cleared the lake shore',
   'We filled twelve sacks with plastic from the east bank this morning.',
   'environment', '2026-10-12',
   extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
   'pending', true, '00000000-0000-0000-0000-0000000000b1', repeat('b', 64)),
  ('bbbb0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   null, 'Held for review',
   'This act was flagged by screening and waits for a moderator to look at it.',
   'community', '2026-10-13',
   extensions.st_setsrid(extensions.st_makepoint(73.86, 18.53), 4326)::extensions.geography,
   'held', true, '00000000-0000-0000-0000-0000000000b2', repeat('c', 64)),
  ('bbbb0000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   null, 'Still in screening',
   'This act has not had a verdict yet and no moderator may publish it.',
   'health', '2026-10-14',
   extensions.st_setsrid(extensions.st_makepoint(73.87, 18.54), 4326)::extensions.geography,
   'pending', false, '00000000-0000-0000-0000-0000000000b3', repeat('d', 64)),
  ('bbbb0000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111',
   null, 'Already taken down',
   'This act was removed by staff and §8.3 gives removed no outgoing transition.',
   'other', '2026-10-15',
   extensions.st_setsrid(extensions.st_makepoint(73.88, 18.55), 4326)::extensions.geography,
   'removed', true, '00000000-0000-0000-0000-0000000000b4', repeat('e', 64));

insert into act_metrics (act_id, metric, value)
values ('bbbb0000-0000-0000-0000-000000000001', 'waste_kg', 60);

insert into media (id, owner_id, purpose, act_id, upload_path, public_path, status) values
  ('dddd0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'act', 'bbbb0000-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111/one',
   '11111111-1111-1111-1111-111111111111/one', 'ready');
insert into media (id, owner_id, purpose, upload_path, public_path, status) values
  ('dddd0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'avatar', '11111111-1111-1111-1111-111111111111/two', null, 'held'),
  ('dddd0000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   'avatar', '11111111-1111-1111-1111-111111111111/three',
   '11111111-1111-1111-1111-111111111111/three', 'ready');
-- §8.1 has the moderation worker set this to the same key it publishes under, which is
-- the second place a published object key is recorded.
update profiles set avatar_path = '11111111-1111-1111-1111-111111111111/three'
where id = '11111111-1111-1111-1111-111111111111';

select ok(
  not has_function_privilege('anon',
    'set_content_status(audit_actor,uuid,uuid,uuid,uuid,content_status,text)', 'execute')
  and not has_function_privilege('authenticated',
    'set_content_status(audit_actor,uuid,uuid,uuid,uuid,content_status,text)', 'execute'),
  'no client calls the internal status function directly; §10.2 gives them admin_* (gate 3)'
);

-- The grant that matters most here. Every Edge Function key resolves to `service_role`,
-- and the `removed` branch deletes ledger rows §6.1 can never award again — so that role
-- reaches the hold §8.5 needs and nothing else.
select ok(
  not has_function_privilege('service_role',
    'set_content_status(audit_actor,uuid,uuid,uuid,uuid,content_status,text)', 'execute')
  and has_function_privilege('service_role',
    'hold_reported_content(uuid,uuid,text)', 'execute'),
  'a secret key can hold reported content and cannot remove any (§6.2, §8.5, §9.1)'
);

select ok(
  not has_function_privilege('anon', 'hold_reported_content(uuid,uuid,text)', 'execute')
  and not has_function_privilege('authenticated',
    'hold_reported_content(uuid,uuid,text)', 'execute'),
  'and no client reaches the wrapper either (gate 3)'
);

select ok(
  (select prosecdef from pg_proc where oid =
     'set_content_status(audit_actor,uuid,uuid,uuid,uuid,content_status,text)'::regprocedure),
  'it is security definer, because §11.6 gives service_role nothing on preserved_content'
);

-- Publish the earning Act the way screening would, so the ledger has rows to reverse.
update acts set status = 'visible' where id = 'bbbb0000-0000-0000-0000-000000000001';

select is(
  (select points from impact_totals where user_id = '11111111-1111-1111-1111-111111111111'),
  140,
  'the fixture Act earned 10 for publishing, 10 for the activity and 120 for 60 kg (§6.3)'
);

select is(
  (select progress_value from campaigns where id = 'cccc0000-0000-0000-0000-000000000001'),
  60::numeric(12, 2),
  'and 60 kg reached the campaign it documents (§6.1)'
);

-- The calls below run as the owner, which is the only role that may: see above.

-- §8.3's transitions.
select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    'bbbb0000-0000-0000-0000-000000000003', null, null, 'visible', 'looks fine to me')
    ->> 'error',
  'VALIDATION_FAILED',
  'a moderator cannot publish an Act still pending, because §8 screens before publishing'
);

select is(
  (select status::text from acts where id = 'bbbb0000-0000-0000-0000-000000000003'),
  'pending',
  'and the Act is left where screening had it'
);

select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    'bbbb0000-0000-0000-0000-000000000004', null, null, 'visible', 'reinstating this')
    ->> 'error',
  'VALIDATION_FAILED',
  'removed is terminal: §8.3 gives it no outgoing transition and §11.6 keeps it 180 days'
);

select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    'bbbb0000-0000-0000-0000-000000000003', null, null, 'removed', 'court order 41/2026')
    ->> 'status',
  'removed',
  'but a pending Act can be removed, because §11.6 puts a 3-hour clock on a court order'
);

-- §8.3's held → visible, and the two records §6.1 says must agree.
select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    'bbbb0000-0000-0000-0000-000000000002', null, null, 'visible', 'reviewed, no violation')
    ->> 'status',
  'visible',
  'a moderator approves held content (§8.3, §10.2)'
);

select isnt(
  (select published_at from acts where id = 'bbbb0000-0000-0000-0000-000000000002'),
  null,
  'published_at is set on approval: §5.2.1 ties it to first visibility, not to the path'
);

select is(
  (select count(*)::int from impact_entries
   where act_id = 'bbbb0000-0000-0000-0000-000000000002'),
  1,
  'and §6.1 awards it on that transition, once, whichever transition got it there'
);

-- §11.6's removal, on the Act that earned.
select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    'bbbb0000-0000-0000-0000-000000000001', null, null, 'removed', 'fabricated evidence')
    ->> 'status',
  'removed',
  'staff remove a visible Act (§8.3, §10.2)'
);

select is(
  (select count(*)::int from impact_entries
   where act_id = 'bbbb0000-0000-0000-0000-000000000001'),
  0,
  '§6.2: its ledger rows are deleted'
);

select is(
  (select points from impact_totals where user_id = '11111111-1111-1111-1111-111111111111'),
  10,
  'and the totals trigger subtracted them, leaving only the other Act''s publish row'
);

select is(
  (select progress_value from campaigns where id = 'cccc0000-0000-0000-0000-000000000001'),
  0::numeric(12, 2),
  'and the campaign gave back the 60 kg (§6.2)'
);

-- §11.6's retention, copy-first.
select is(
  (select snapshot ->> 'title' from private.preserved_content
   where source_id = 'bbbb0000-0000-0000-0000-000000000001'),
  'Cleared the lake shore',
  'the snapshot is kept, which rule 3(1)(g) requires for 180 days (§11.6)'
);

select is(
  (select snapshot -> 'metrics' ->> 'waste_kg' from private.preserved_content
   where source_id = 'bbbb0000-0000-0000-0000-000000000001'),
  '60.00',
  'with the claims that fed the ledger, so the record is of what was published'
);

select is(
  (select file_paths from private.preserved_content
   where source_id = 'bbbb0000-0000-0000-0000-000000000001'),
  array['11111111-1111-1111-1111-111111111111/one'],
  'and the object key of its photo, which §11.6 keeps for the same 180 days'
);

-- §11.6: the public bucket must stop serving it immediately.
select is(
  (select status::text from media where id = 'dddd0000-0000-0000-0000-000000000001'),
  'removed',
  'the photo of removed content is removed too, so §5.2''s ready-only policy drops it'
);

select is(
  (select public_path from media where id = 'dddd0000-0000-0000-0000-000000000001'),
  null,
  'and the row stops pointing at a public object (§11.6)'
);

select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'kind' = 'quarantine_file'
     and message ->> 'path' = '11111111-1111-1111-1111-111111111111/one'),
  1,
  'with one ops job to move the file to quarantine, which SQL cannot do (§5.4, §11.6)'
);

-- §8.3's held → visible for a photo: the gap §17.1 recorded as having no writer.
-- Answered with `processing`, which is what the row became: §8.3 leaves an approved photo
-- there until the `ops` job copies the file, and reporting `visible` would tell Appsmith a
-- photo is published while §12.5 is alarming that it is stuck.
select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    null, null, 'dddd0000-0000-0000-0000-000000000002', 'visible', 'fine on review')
    ->> 'status',
  'processing',
  'a moderator approves a held photo, which is answered with the status it reached (§8.3)'
);

select is(
  (select status::text from media where id = 'dddd0000-0000-0000-0000-000000000002'),
  'processing',
  'which waits in processing, so §12.5 sees a publication that never lands'
);

select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'kind' = 'publish_photo'
     and message ->> 'media_id' = 'dddd0000-0000-0000-0000-000000000002'),
  1,
  'and queues the copy §8.3''s held → visible had no writer for (§17.1)'
);

select is(
  (select public_path from media where id = 'dddd0000-0000-0000-0000-000000000002'),
  null,
  'nothing is published from SQL: §8 publishes no bytes before the file is there'
);

-- §11.6's "stop pointing at a public object", on the second column that points at one.
select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    null, null, 'dddd0000-0000-0000-0000-000000000003', 'removed', 'abusive avatar')
    ->> 'status',
  'removed',
  'staff remove a published avatar (§10.2)'
);

select is(
  (select avatar_path from profiles where id = '11111111-1111-1111-1111-111111111111'),
  null,
  'and profiles.avatar_path is nulled with it, or a removed avatar keeps rendering (§11.6)'
);

-- §10: "the audit log records who acted". Checked where the row is written rather than
-- trusted to the callers, because the third caller is the one nobody reviewed.
select throws_ok(
  $$ select set_content_status('staff', '11111111-1111-1111-1111-111111111111',
       'bbbb0000-0000-0000-0000-000000000002', null, null, 'removed', 'forged') $$,
  'P0001',
  'set_content_status attributes a staff action to a staff member',
  'a takedown cannot be attributed to someone who is not staff (§10)'
);

select throws_ok(
  $$ select set_content_status('staff', null,
       'bbbb0000-0000-0000-0000-000000000002', null, null, 'removed', 'no actor') $$,
  'P0001',
  'set_content_status takes a staff id exactly when the actor is staff',
  'nor left unattributed, which §5.2.1''s own check also pairs'
);

select throws_ok(
  $$ select set_content_status('system', '99999999-9999-9999-9999-999999999999',
       'bbbb0000-0000-0000-0000-000000000002', null, null, 'removed', 'wrong actor') $$,
  'P0001',
  'set_content_status takes a staff id exactly when the actor is staff',
  'and §8.5''s system path carries no staff id at all'
);

-- §10 and §8.5's audit rows. Read as the owner: §5.2 gives `admin_audit_log` no role
-- any privilege at all — "no role may update or delete" it, and nothing may read it
-- either — so it is written inside the definer frame and read here as its owner.
select is(
  (select count(*)::int from admin_audit_log
   where action = 'set_content_status'
     and actor = 'staff'
     and staff_id = '99999999-9999-9999-9999-999999999999'),
  5,
  'every staff action wrote its audit row in the same transaction (§10)'
);

select is(
  (select before ->> 'status' || '->' || (after ->> 'status') from admin_audit_log
   where subject_id = 'bbbb0000-0000-0000-0000-000000000001'),
  'visible->removed',
  'carrying the status either side and, per §9.8, nothing of the content itself'
);

-- The Activity branch, which nothing above reaches: no ledger, no `published_at`, and
-- the snapshot §17.1 records as carrying an exact meeting point.
select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    null, 'aaaa0000-0000-0000-0000-000000000001', null, 'held',
    'meeting point looks unsafe') ->> 'status',
  'held',
  'a moderator holds an Activity (§8.3, §10.2)'
);

select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    null, 'aaaa0000-0000-0000-0000-000000000001', null, 'removed',
    'organiser asked people to bring weapons') ->> 'status',
  'removed',
  'and removes one'
);

select is(
  (select snapshot ->> 'title' from private.preserved_content
   where source_id = 'aaaa0000-0000-0000-0000-000000000001'),
  'Lake shore cleanup',
  'whose snapshot is kept under source_kind activity (§11.6)'
);

select is(
  (select count(*)::int from impact_entries
   where act_id in ('bbbb0000-0000-0000-0000-000000000002')),
  1,
  'and no ledger row moved: §6.1 awards nothing for an Activity, so there is none to reverse'
);

-- A media subject gets a preserved_content row of its own, and its served key a job.
select is(
  (select source_kind from private.preserved_content
   where source_id = 'dddd0000-0000-0000-0000-000000000003'),
  'media',
  'a photo removed on its own is preserved under its own source_kind (§11.6)'
);

select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'kind' = 'quarantine_file'
     and message ->> 'path' = '11111111-1111-1111-1111-111111111111/three'),
  1,
  'and its public object is queued for quarantine, the other half of the avatar fix'
);

-- §8.3's visible → held, which is the transition §8.5's automatic hold depends on.
select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    'bbbb0000-0000-0000-0000-000000000002', null, null, 'held',
    'a report came in after it published') ->> 'status',
  'held',
  'visible content can be held, which is what §8.5 reaches through (§8.3)'
);

-- The held → held no-op §17.1 records as a decision, and the clock it must not restamp.
create temp table clock as
  select status_changed_at from acts where id = 'bbbb0000-0000-0000-0000-000000000002';

select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    'bbbb0000-0000-0000-0000-000000000002', null, null, 'held',
    'confirmed on review, leaving it held') ->> 'status',
  'held',
  'a moderator may confirm a hold, which §8.5 also does on a second report'
);

select is(
  (select status_changed_at from acts where id = 'bbbb0000-0000-0000-0000-000000000002'),
  (select status_changed_at from clock),
  'without restamping §10.4''s 20-hour clock, which would hide an unreviewed hold'
);

-- §7.4's NOT_FOUND on each branch, which no assertion above reaches.
select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    'bbbb0000-0000-0000-0000-00000000ffff', null, null, 'held', 'no such act') ->> 'error',
  'NOT_FOUND',
  'an act that is not there is NOT_FOUND (§7.4)'
);

select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    null, null, 'dddd0000-0000-0000-0000-0000000000ff', 'held', 'no such photo') ->> 'error',
  'NOT_FOUND',
  'and so is a photo'
);

select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    null, 'aaaa0000-0000-0000-0000-0000000000ff', null, 'held', 'no such activity')
    ->> 'error',
  'NOT_FOUND',
  'and an activity, so all three branches answer the same way'
);

-- The audit row reports what was written, not what was asked for: §8.3 leaves an approved
-- photo in `processing` until the copy lands, and §10.3 renders this log on screen.
select is(
  (select after ->> 'status' from admin_audit_log
   where subject_id = 'dddd0000-0000-0000-0000-000000000002'),
  'processing',
  'approving a photo is logged as the processing it actually became (§8.3, §10.3)'
);

-- The defect the `seam-qa` agent found on 13 October 2026, reproduced here. §8.1: "**A held photo
-- gets no published copy**." Holding a photo that was *already* published left `public_path` set and
-- queued no file move, so the public bucket went on serving it — and an erasure then gave that live
-- path a 180-day retention clock, which `queue_media_deletion` honoured by suppressing the deletion.
--
-- With its own fixtures, because the tests above have already moved this file's original photos
-- through takedowns and `removed` is terminal. Every held fixture in this file *starts* held, which
-- is why three rounds of review never produced a held photo that had been published.
set local role postgres;
insert into acts (id, author_id, title, story, category, occurred_on, location_coarse,
                  status, text_checked, idempotency_key, request_hash)
values ('bbbb5555-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        'Published then held',
        'An Act whose photo was published and then held, which is the case that had no fixture.',
        'environment', '2026-10-11',
        extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
        'visible', true, '00000000-0000-0000-0000-0000000055a1', repeat('5', 64));
insert into media (id, owner_id, purpose, act_id, upload_path, public_path, status) values
  ('dddd5555-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'act', 'bbbb5555-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111/five',
   '11111111-1111-1111-1111-111111111111/five', 'ready'),
  ('dddd5555-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'avatar', null,
   '11111111-1111-1111-1111-111111111111/six',
   '11111111-1111-1111-1111-111111111111/six', 'ready');
update profiles set avatar_path = '11111111-1111-1111-1111-111111111111/six'
where id = '11111111-1111-1111-1111-111111111111';
select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    null, null, 'dddd5555-0000-0000-0000-000000000001', 'held',
    'held after publication, which is the case that had no test') ->> 'status',
  'held',
  'a published photo can be held (§8.3 visible -> held)'
);

select ok(
  (select public_path is null and thumb_path is null and status = 'held'
   from media where id = 'dddd5555-0000-0000-0000-000000000001'),
  'and the hold clears its published path, because §8.1 gives a held photo no published copy'
);

select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'kind' = 'unpublish_file'
     and message ->> 'path' = '11111111-1111-1111-1111-111111111111/five'),
  1,
  'with a job to take the file out of the public bucket (§5.4 keeps file moves out of SQL)'
);

-- Back to `uploads`, not `quarantine`: §11.6 attaches the quarantine move to a removal and its
-- 180-day clock, and a hold is reviewable. The destination lives in the worker, so what is asserted
-- here is that this is *not* the removal's job kind.
select is_empty(
  $$ select 1 from pgmq.q_ops
     where message ->> 'kind' = 'quarantine_file'
       and message ->> 'path' = '11111111-1111-1111-1111-111111111111/five' $$,
  'and not the quarantine move, which §11.6 reserves for a takedown'
);

-- The avatar half, which the removal branch has always done and the hold branch did not: a held
-- avatar kept rendering on the profile. `dddd0000-…-0003` is this person's published avatar.
select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    null, null, 'dddd5555-0000-0000-0000-000000000002', 'held',
    'holding a published avatar') ->> 'status',
  'held',
  'a published avatar can be held too'
);

select ok(
  (select avatar_path is null from profiles
   where id = '11111111-1111-1111-1111-111111111111'),
  'and the profile stops pointing at it, so a held avatar stops rendering (§9.2)'
);
reset role;

-- The collapse the `seam-qa` agent found on 15 October 2026, reproduced here. §17.1 recorded the
-- `media_status` mapping as leaving "a never-screened or malformed photo … removable by staff but
-- not approvable, which is the right way round". It was not: `uploading`, `processing` and
-- `rejected` all read as `pending`, §8.3 allows `pending -> held`, and §8.3 allows `held ->
-- visible` — so two ordinary moderator calls walked a photo whose bytes §8.1 had deleted into
-- `processing` with an `ops` job to copy it into the public `media` bucket.
--
-- With its own fixtures: every media fixture above is `ready` or `held`, which is why no round of
-- review produced a photo in either of the two states §8.1 leaves without a file.
set local role postgres;
insert into media (id, owner_id, purpose, upload_path, status) values
  ('dddd7777-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'avatar', '11111111-1111-1111-1111-111111111111/seven', 'rejected'),
  ('dddd7777-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'avatar', '11111111-1111-1111-1111-111111111111/eight', 'uploading'),
  ('dddd7777-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   'avatar', '11111111-1111-1111-1111-111111111111/nine', 'processing');

-- The hold is where it has to be refused: once the row says `held` it no longer says what it was
-- held from, which is the collapse itself.
select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    null, null, 'dddd7777-0000-0000-0000-000000000001', 'held',
    'holding a photo whose bytes failed'),
  jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'status'),
  'a rejected photo cannot be held: §8.1 deleted its original, so there is nothing to review'
);

-- The whole object rather than one key: §7.4 fixes the code as well as the field, and an
-- assertion on `field` alone would pass if a later change answered `FORBIDDEN` instead.
select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    null, null, 'dddd7777-0000-0000-0000-000000000002', 'held',
    'holding a photo that never completed'),
  jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'status'),
  'nor an uploading one, whose object no complete call has confirmed (§8.1)'
);

-- The walk, not just the first step: with no `held` to approve from, the second call has nothing to
-- reach, and the public bucket gets no job either way.
select ok(
  (select count(*)::int from media
   where id in ('dddd7777-0000-0000-0000-000000000001',
                'dddd7777-0000-0000-0000-000000000002')
     and status in ('rejected', 'uploading')) = 2
  and (select count(*)::int from pgmq.q_ops
       where message ->> 'kind' = 'publish_photo'
         and message ->> 'media_id' in ('dddd7777-0000-0000-0000-000000000001',
                                        'dddd7777-0000-0000-0000-000000000002')) = 0,
  'both rows stay where screening left them, and no bytes are queued for the public bucket (§8)'
);

-- §11.6's court-order clock "does not care whether a file was ever screened", so the one verb that
-- still works from these two states is removal.
select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    null, null, 'dddd7777-0000-0000-0000-000000000001', 'removed',
    'court order 52 of 2026') ->> 'status',
  'removed',
  'but staff still remove it, which §11.6 puts a 3-hour clock on whatever screening did (§8.3)'
);

select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    null, null, 'dddd7777-0000-0000-0000-000000000002', 'removed',
    'court order 53 of 2026') ->> 'status',
  'removed',
  'and from an uploading one, which has no public_path for the quarantine loop to find'
);

select is(
  (select source_kind from private.preserved_content
   where source_id = 'dddd7777-0000-0000-0000-000000000002'),
  'media',
  'with §11.6''s snapshot written even though the object may never have existed'
);

-- `processing` is deliberately not in the guard. Its object exists and §8.1 has handed it to the
-- worker, so whether a moderator may approve one is `O54`'s question for the owner — and the
-- no-AWS lifecycle §17.1 measured on 12 October runs through exactly this state.
select is(
  set_content_status('staff', '99999999-9999-9999-9999-999999999999',
    null, null, 'dddd7777-0000-0000-0000-000000000003', 'held',
    'a report arrived while it was being screened') ->> 'status',
  'held',
  'a photo still in screening can be held, which this guard leaves alone (`O54`)'
);
reset role;

select * from finish();
rollback;
