begin;
create extension if not exists pgtap with schema extensions;
select plan(32);

insert into auth.users (id, created_at, phone, email) values
  ('11111111-1111-1111-1111-111111111111', now() - interval '200 days',
   '919000000002', 'leaving@seva.test'),
  ('22222222-2222-2222-2222-222222222222', now() - interval '30 days', null, null),
  ('33333333-3333-3333-3333-333333333333', now() - interval '30 days', null, null);
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'leaving'),
  ('22222222-2222-2222-2222-222222222222', 'participant'),
  ('33333333-3333-3333-3333-333333333333', 'reporter');
insert into profile_private (user_id, date_of_birth, terms_version, privacy_version)
values ('11111111-1111-1111-1111-111111111111', '1995-04-04', '2026-09-01', '2026-09-15');

insert into campaigns (id, title, description, goal_metric, goal_value,
                       starts_on, ends_on, status)
values ('cccc0000-0000-0000-0000-000000000001', 'Clean the lake',
        'Volunteers clearing plastic from the lake shore every weekend this season.',
        'waste_kg', 5000, '2026-10-01', '2026-12-31', 'active');

-- One Activity in the future, one in the past: §5.4 cancels the first and lets the second
-- survive with a null organiser.
insert into activities (id, organiser_id, title, description, category, starts_at, ends_at,
                        location, location_label, capacity, campaign_id, status,
                        idempotency_key, request_hash)
values
  ('aaaa0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'Next weekend cleanup',
   'Bring gloves and water. We meet at the east gate and finish before noon.',
   'environment', now() + interval '5 days', now() + interval '5 days 3 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
   'East gate', 40, null, 'visible',
   '00000000-0000-0000-0000-0000000000a1', repeat('a', 64)),
  ('aaaa0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'Last month''s cleanup',
   'Bring gloves and water. We met at the east gate and finished before noon.',
   'environment', now() - interval '30 days', now() - interval '30 days' + interval '3 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.86, 18.53), 4326)::extensions.geography,
   'East gate', 40, 'cccc0000-0000-0000-0000-000000000001', 'visible',
   '00000000-0000-0000-0000-0000000000a2', repeat('b', 64));
insert into activity_participants (activity_id, user_id) values
  ('aaaa0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222'),
  ('aaaa0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111'),
  -- Joined the past one too, which is what §2.1 requires before an Act may document it and
  -- what carries its campaign onto the ledger rows (§6.1).
  ('aaaa0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111');

-- A published Act that earned, and a held one §11.6 must preserve.
insert into acts (id, author_id, activity_id, title, story, category, occurred_on,
                  location_coarse, status, text_checked, idempotency_key, request_hash)
values
  ('bbbb0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'aaaa0000-0000-0000-0000-000000000002', 'Cleared the lake shore',
   'We filled twelve sacks with plastic from the east bank this morning.',
   'environment', '2026-10-12',
   extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
   'pending', true, '00000000-0000-0000-0000-0000000000b1', repeat('c', 64)),
  ('bbbb0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   null, 'Held for review',
   'An act screening flagged, which §11.6 keeps for 180 days after the account goes.',
   'community', '2026-10-13',
   extensions.st_setsrid(extensions.st_makepoint(73.86, 18.53), 4326)::extensions.geography,
   'held', true, '00000000-0000-0000-0000-0000000000b2', repeat('d', 64));
insert into act_metrics (act_id, metric, value)
values ('bbbb0000-0000-0000-0000-000000000001', 'waste_kg', 50);

insert into media (id, owner_id, purpose, act_id, upload_path, public_path, status) values
  ('dddd0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'act', 'bbbb0000-0000-0000-0000-000000000002',
   '11111111-1111-1111-1111-111111111111/held', null, 'held'),
  ('dddd0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'act', 'bbbb0000-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111/ready',
   '11111111-1111-1111-1111-111111111111/ready', 'ready'),
  -- A photo `held` under an Act that is **not** held, which `admin_set_content_status` on the
  -- photo alone produces and which §8.3 also reaches by a moderator approving the Act and not
  -- the photo. Nothing preserved it, so the cascade destroyed its file on day 0.
  ('dddd0000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   'act', 'bbbb0000-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111/lone-held', null, 'held');

-- Two accounts for the clock cases review reproduced, kept apart from the account above so each
-- file's assertions stay scoped to its own fixtures.
insert into auth.users (id, created_at) values
  ('aaaa7777-7777-7777-7777-777777777777', now() - interval '300 days'),
  ('aaaa8888-8888-8888-8888-888888888888', now() - interval '300 days');
insert into profiles (id, display_name) values
  ('aaaa7777-7777-7777-7777-777777777777', 'old hold'),
  ('aaaa8888-8888-8888-8888-888888888888', 'mid hold');

-- An Act held 190 days ago with a photo of it held 10 days ago. Measured before the fix: the Act
-- was declined on the window floor, the photo was skipped because its parent was held, and the
-- cascade destroyed a file 10 days into its own retention.
insert into acts (id, author_id, title, story, category, occurred_on, location_coarse,
                  status, status_changed_at, text_checked, idempotency_key, request_hash)
values ('bbbb7777-0000-0000-0000-000000000001', 'aaaa7777-7777-7777-7777-777777777777',
        'Held for six months',
        'An allegation nobody adjudicated, which §12.5''s held-content arm should have caught.',
        'community', '2026-03-01',
        extensions.st_setsrid(extensions.st_makepoint(73.9, 18.6), 4326)::extensions.geography,
        'held', now() - interval '190 days', true,
        '00000000-0000-0000-0000-0000000000c7', repeat('7', 64));
insert into media (id, owner_id, purpose, act_id, upload_path, status, status_changed_at) values
  ('dddd7777-0000-0000-0000-000000000001', 'aaaa7777-7777-7777-7777-777777777777',
   'act', 'bbbb7777-0000-0000-0000-000000000001',
   'aaaa7777-7777-7777-7777-777777777777/recent-hold', 'held', now() - interval '10 days');

-- An Act held 100 days ago with a photo held 10 days ago. Measured before the fix: the photo's file
-- was released at day 80 rather than day 170, because the parent's snapshot clock governed it.
insert into acts (id, author_id, title, story, category, occurred_on, location_coarse,
                  status, status_changed_at, text_checked, idempotency_key, request_hash)
values ('bbbb8888-0000-0000-0000-000000000001', 'aaaa8888-8888-8888-8888-888888888888',
        'Held three months ago',
        'A hold whose photo was held much later, so the two clocks are nowhere near each other.',
        'community', '2026-06-01',
        extensions.st_setsrid(extensions.st_makepoint(73.9, 18.6), 4326)::extensions.geography,
        'held', now() - interval '100 days', true,
        '00000000-0000-0000-0000-0000000000c8', repeat('8', 64));
insert into media (id, owner_id, purpose, act_id, upload_path, status, status_changed_at) values
  ('dddd8888-0000-0000-0000-000000000001', 'aaaa8888-8888-8888-8888-888888888888',
   'act', 'bbbb8888-0000-0000-0000-000000000001',
   'aaaa8888-8888-8888-8888-888888888888/later-hold', 'held', now() - interval '10 days');
-- And a photo of that same held Act that is `ready` and published. Measured before the fix: the
-- Act's snapshot named its path with no status filter, `queue_media_deletion` found a live
-- retention row and suppressed the deletion, and the photo kept being served from the public bucket
-- for 180 days after the account was erased — content that was never held or removed at all.
insert into media (id, owner_id, purpose, act_id, upload_path, public_path, status,
                   status_changed_at)
values ('dddd8888-0000-0000-0000-000000000002', 'aaaa8888-8888-8888-8888-888888888888',
        'act', 'bbbb8888-0000-0000-0000-000000000001',
        'aaaa8888-8888-8888-8888-888888888888/published',
        'aaaa8888-8888-8888-8888-888888888888/published', 'ready', now() - interval '20 days');

insert into account_deletions (user_id) values
  ('aaaa7777-7777-7777-7777-777777777777'),
  ('aaaa8888-8888-8888-8888-888888888888');

-- A removal §11.6 is already retaining, 10 days in. Erasure must not copy it again with a fresh
-- `purge_after`: the clock runs from the removal, not from the deletion.
insert into acts (id, author_id, title, story, category, occurred_on, location_coarse,
                  status, text_checked, idempotency_key, request_hash)
values ('bbbb0000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
        'Removed ten days ago',
        'Content a moderator took down, whose 180 days started then and not at the erasure.',
        'community', '2026-09-20',
        extensions.st_setsrid(extensions.st_makepoint(73.87, 18.54), 4326)::extensions.geography,
        'removed', true, '00000000-0000-0000-0000-0000000000b3', repeat('f', 64));
-- `created_at` stands in for the removal: §11.6 stamps `purge_after` at the snapshot, so a row
-- 10 days old has 170 left.
insert into private.preserved_content (source_kind, source_id, snapshot, file_paths,
                                       created_at, purge_after)
values ('act', 'bbbb0000-0000-0000-0000-000000000003',
        jsonb_build_object('title', 'Removed ten days ago'), null,
        now() - interval '10 days', now() + interval '170 days');

-- An open report about their Act, which the cascade would otherwise leave naming nothing.
insert into reports (id, reporter_id, subject_type, act_id, reason,
                     idempotency_key, request_hash)
values ('eeee0000-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333',
        'act', 'bbbb0000-0000-0000-0000-000000000002', 'spam',
        '00000000-0000-0000-0000-0000000000e1', repeat('e', 64));

-- And one about a future Activity they organise. `activities.organiser_id` is
-- `on delete set null`, so that Activity survives the erasure and stays fetchable: dismissing
-- this report would discharge a §11.6 deadline while the reported content was still being served.
insert into reports (id, reporter_id, subject_type, activity_id, reason,
                     idempotency_key, request_hash)
values ('eeee0000-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333',
        'activity', 'aaaa0000-0000-0000-0000-000000000001', 'misleading',
        '00000000-0000-0000-0000-0000000000e2', repeat('b', 64));

-- Publish the earning Act so the ledger has rows §5.4 keeps.
update acts set status = 'visible' where id = 'bbbb0000-0000-0000-0000-000000000001';

select ok(
  not has_function_privilege('anon', 'delete_account(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'delete_account(uuid)', 'execute')
  and has_function_privilege('service_role', 'delete_account(uuid)', 'execute'),
  'the worker may call it and no client can, which CLAUDE.md fixes for §11.6''s two functions'
);

select ok(
  (select prosecdef from pg_proc where oid = 'delete_account(uuid)'::regprocedure),
  'and it is definer, because service_role holds nothing on either retention table (§11.6)'
);

-- §5.2.1's request row is what authorises the work.
select is(
  delete_account('11111111-1111-1111-1111-111111111111') ->> 'error',
  'NOT_FOUND',
  'nothing happens without a deletion request, so §8.4''s retry stops rather than loops'
);

select is(
  (select count(*)::int from profiles where id = '11111111-1111-1111-1111-111111111111'),
  1,
  'and the account is untouched'
);

insert into account_deletions (user_id) values ('11111111-1111-1111-1111-111111111111');

select is(
  delete_account('11111111-1111-1111-1111-111111111111') ->> 'status',
  'completed',
  'with a request on file the erasure runs (§5.4, §7.3)'
);

-- §11.6's copy-first ordering.
-- **One row per held or removed item, each with its own clock.** Two review rounds landed here:
-- first the condition was "has no parent", which left a photo held under a live Act preserved by
-- nothing; then it was "no parent snapshot covers it", which was true of the paths and false of the
-- clocks — measured, a photo held 10 days ago under an Act held 190 days ago was destroyed on day 0,
-- and under an Act held 100 days ago had its file released 90 days early. So no snapshot stands in
-- for another: the held photo under the held Act now gets a row of its own, and the duplicate path
-- reference is safe because the purge will not release a path another live row still names.
select results_eq(
  $$ select source_kind, source_id::text from private.preserved_content
     where source_id in ('bbbb0000-0000-0000-0000-000000000001',
                         'bbbb0000-0000-0000-0000-000000000002',
                         'bbbb0000-0000-0000-0000-000000000003',
                         'dddd0000-0000-0000-0000-000000000001',
                         'dddd0000-0000-0000-0000-000000000002',
                         'dddd0000-0000-0000-0000-000000000003')
     order by source_kind, source_id $$,
  $$ values ('act', 'bbbb0000-0000-0000-0000-000000000002'),
            ('act', 'bbbb0000-0000-0000-0000-000000000003'),
            ('media', 'dddd0000-0000-0000-0000-000000000001'),
            ('media', 'dddd0000-0000-0000-0000-000000000003') $$,
  'every held or removed item is preserved exactly once, on its own merits (§5.4, §11.6)'
);

-- The clock a hold gets is the erasure's, not `status_changed_at` + 180: a hold has never been
-- adjudicated, so rule 3(1)(g) has no takedown moment to run from, and §11.6's preamble says to
-- take the strict reading. Measured before this: a six-month-held item was dropped with no record.
select ok(
  (select purge_after > now() + interval '179 days' from private.preserved_content
   where source_id = 'bbbb0000-0000-0000-0000-000000000002'),
  'a held item gets 180 days from the erasure, which §11.6 calls the strict reading'
);

select ok(
  (select purge_after < now() + interval '171 days' from private.preserved_content
   where source_id = 'bbbb0000-0000-0000-0000-000000000003'),
  'and a removal keeps the clock that started when it was removed (§11.6, rule 3(1)(g))'
);

-- §11.6's 180 days run from the removal. A second snapshot with a fresh `purge_after` would have
-- retained content removed on day 170 until about day 351, against DPDP storage limitation.
select is(
  (select count(*)::int from private.preserved_content
   where source_id = 'bbbb0000-0000-0000-0000-000000000003'),
  1,
  'content already inside its 180 days is not copied again (§11.6, O7)'
);

select ok(
  (select purge_after < now() + interval '171 days' from private.preserved_content
   where source_id = 'bbbb0000-0000-0000-0000-000000000003'),
  'and it keeps the clock it already had, which started at the removal'
);

-- The defect this file could not see before: the held photo's file was named by no retention row,
-- so `queue_media_deletion` let the cascade destroy it on day 0.
select ok(
  (select file_paths @> array['11111111-1111-1111-1111-111111111111/lone-held']
   from private.preserved_content
   where source_id = 'dddd0000-0000-0000-0000-000000000003'),
  'a photo held under a live parent keeps its file for the 180 days (§11.6)'
);

select is(
  (select snapshot ->> 'title' from private.preserved_content
   where source_id = 'bbbb0000-0000-0000-0000-000000000002'),
  'Held for review',
  'with the content itself, which rule 3(1)(g) keeps for 180 days'
);

select ok(
  (select file_paths @> array['11111111-1111-1111-1111-111111111111/held']
   from private.preserved_content
   where source_id = 'bbbb0000-0000-0000-0000-000000000002'),
  'and the object key of its photo, which §11.6 keeps for the same 180 days'
);

-- §17.1's own defect: the cascade must not queue deletion of a file §11.6 is retaining.
select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'kind' = 'delete_media_files'
     and message ->> 'upload_path' = '11111111-1111-1111-1111-111111111111/held'),
  0,
  'the cascade queues no deletion for a retained file, which §11.6''s ordering is for (§17.1)'
);

select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'kind' = 'delete_media_files'
     and message ->> 'upload_path' = '11111111-1111-1111-1111-111111111111/ready'),
  1,
  'while the published photo of content nobody is retaining is queued for deletion (§5.4)'
);

-- §11.6's rule 3(1)(h), with `O23`'s three columns.
select ok(
  (select phone = '919000000002' and email = 'leaving@seva.test'
     and terms_version = '2026-09-01' and privacy_version = '2026-09-15'
     and accepted_at is not null
     and (purge_after::date - now()::date) = 180
   from private.retained_registrations
   where user_id = '11111111-1111-1111-1111-111111111111'),
  'the registration details and the consent evidence are kept 180 days (§11.6, O23)'
);

-- §5.4's Activities.
select ok(
  (select cancelled_at is not null
   from activities where id = 'aaaa0000-0000-0000-0000-000000000001'),
  'a future Activity they organised is cancelled (§5.4)'
);

select is(
  (select count(*)::int from pgmq.q_email
   where message ->> 'kind' = 'activity_cancelled'
     and message ->> 'activity_id' = 'aaaa0000-0000-0000-0000-000000000001'
     and message ->> 'user_id' = '22222222-2222-2222-2222-222222222222'),
  1,
  'and its participants are emailed, which §2.1 and §5.4 both require'
);

select ok(
  (select organiser_id is null and cancelled_at is null and status = 'visible'
   from activities where id = 'aaaa0000-0000-0000-0000-000000000002'),
  'while a past Activity survives with a null organiser (§5.4)'
);

-- The open report that would otherwise have named nothing for ever.
select ok(
  (select status = 'dismissed' and resolved_at is not null and resolved_by is null
   from reports where id = 'eeee0000-0000-0000-0000-000000000001'),
  'an open report about their content is resolved, so §12.5''s arms stay clearable'
);

-- And the review finding: a report about a future Activity is **not** dismissed, because
-- `organiser_id on delete set null` leaves that Activity in place and `discover_activity` still
-- serves it to a logged-out caller. Dismissing it discharged a §11.6 deadline on content still
-- being served, decided by nobody.
select is(
  (select status::text from reports where id = 'eeee0000-0000-0000-0000-000000000002'),
  'open',
  'a report about an Activity that survives the erasure stays open (§11.6, §12.5)'
);

select ok(
  (select count(*) = 1 from activities
   where id = 'aaaa0000-0000-0000-0000-000000000001' and organiser_id is null),
  'which is the reason: the Activity itself is still there, with no organiser'
);

-- Review's first reproduction: an Act held 190 days ago keeps its record, because rule 3(1)(g)'s
-- clock runs from a takedown and a hold has had none — and its recently-held photo keeps its own.
set local role service_role;
select is(
  delete_account('aaaa7777-7777-7777-7777-777777777777') ->> 'preserved',
  '2',
  'a six-month hold and its ten-day-old photo are both preserved (§11.6, strict reading)'
);
reset role;

select ok(
  (select file_paths @> array['aaaa7777-7777-7777-7777-777777777777/recent-hold']
   from private.preserved_content
   where source_id = 'dddd7777-0000-0000-0000-000000000001'),
  'the photo''s file is named by its own row, not only by a parent that may expire first'
);

-- Review's second: the photo's clock is its own, so its file is not released 90 days early.
set local role service_role;
select is(
  delete_account('aaaa8888-8888-8888-8888-888888888888') ->> 'preserved',
  '2',
  'and a photo held long after its Act gets a row of its own too (§11.6)'
);
reset role;

select ok(
  (select purge_after > now() + interval '179 days' from private.preserved_content
   where source_id = 'dddd8888-0000-0000-0000-000000000001'),
  'with its own 180 days, where the parent''s snapshot would have released it at day 80'
);

-- And the published photo of that held Act is not named by any snapshot, so the cascade's job is
-- not suppressed and the public bucket stops serving it.
select ok(
  not exists (
    select 1 from private.preserved_content
    where file_paths @> array['aaaa8888-8888-8888-8888-888888888888/published']
  ),
  'a published photo of a held Act is retained by nothing, because it is not retained content'
);

select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'kind' = 'delete_media_files'
     and message ->> 'public_path' = 'aaaa8888-8888-8888-8888-888888888888/published'),
  1,
  'so its file is deleted rather than served from the public bucket for 180 days (§11.2, §11.6)'
);

-- §5.4's ledger rule, which the foreign keys perform.
-- §6.1 writes one row for publishing, one for documenting the Activity and one per metric,
-- each carrying the documented Activity's campaign.
select is(
  (select count(*)::int from impact_entries
   where user_id is null and campaign_id = 'cccc0000-0000-0000-0000-000000000001'),
  3,
  'ledger rows survive with a null author, so campaign totals stay correct (§5.4)'
);

select is(
  (select progress_value from campaigns where id = 'cccc0000-0000-0000-0000-000000000001'),
  50::numeric(12, 2),
  'and the campaign keeps the progress a since-deleted person contributed (§5.4)'
);

-- The erasure itself.
select is(
  (select count(*)::int from auth.users where id = '11111111-1111-1111-1111-111111111111'),
  0,
  'the Auth row is gone, which is what cascades the profile and everything under it (§5.4)'
);

select ok(
  (select status = 'completed' and completed_at is not null
   from account_deletions where user_id = '11111111-1111-1111-1111-111111111111'),
  'and the request is marked completed, so the worker stops retrying it (§5.2.1)'
);

select * from finish();
rollback;
