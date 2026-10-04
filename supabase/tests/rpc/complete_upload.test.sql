begin;
create extension if not exists pgtap with schema extensions;
select plan(27);

insert into auth.users (id, created_at) values
  ('11111111-1111-1111-1111-111111111111', now() - interval '30 days'),
  ('22222222-2222-2222-2222-222222222222', now() - interval '30 days'),
  ('33333333-3333-3333-3333-333333333333', now() - interval '30 days'),
  ('44444444-4444-4444-4444-444444444444', now() - interval '30 days');
insert into profiles (id, display_name, status, suspended_until) values
  ('11111111-1111-1111-1111-111111111111', 'anand', 'active', null),
  ('22222222-2222-2222-2222-222222222222', 'bina', 'active', null),
  ('44444444-4444-4444-4444-444444444444', 'chandra', 'suspended', now() + interval '2 days');
-- 33333333 has an auth row and no profile: §5.4's onboarding gate.

insert into media (id, owner_id, purpose, upload_path, status) values
  ('dddd0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'act', '11111111-1111-1111-1111-111111111111/one', 'uploading'),
  ('dddd0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'act', '11111111-1111-1111-1111-111111111111/two', 'ready'),
  ('dddd0000-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222',
   'avatar', '22222222-2222-2222-2222-222222222222/three', 'uploading'),
  ('dddd0000-0000-0000-0000-000000000004', '44444444-4444-4444-4444-444444444444',
   'act', '44444444-4444-4444-4444-444444444444/four', 'uploading');

select ok(
  not has_function_privilege('anon',
    'confirm_upload_target(uuid,uuid,text,int,int,int)', 'execute')
  and not has_function_privilege('authenticated',
    'confirm_upload_target(uuid,uuid,text,int,int,int)', 'execute')
  and not has_function_privilege('anon', 'queue_photo_screening(uuid,uuid)', 'execute')
  and not has_function_privilege('authenticated',
    'queue_photo_screening(uuid,uuid)', 'execute'),
  'no client can call either half directly (§9.1, gate 3)'
);

set local role service_role;

-- §5.4's gate, above the limiter so the barred caller is not billed (§17.1).
select is(
  confirm_upload_target('33333333-3333-3333-3333-333333333333',
    'dddd0000-0000-0000-0000-000000000001', 'uploads.complete:u3', null, 60, null)
    ->> 'error',
  'ONBOARDING_REQUIRED',
  'an account with no profile row cannot complete an upload (§5.4)'
);

select is_empty(
  $$ select bucket from private.rate_limit_hits where bucket like 'uploads.complete:u3%' $$,
  'and is not billed for it (§17.1)'
);

-- §17.1's fold: another person's photo and a photo that does not exist answer the same
-- code, so neither tells a caller which ids exist.
select is(
  confirm_upload_target('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000003', 'uploads.complete:u1', null, 60, null)
    ->> 'error',
  'FORBIDDEN',
  'another person''s photo is refused (§7.4, §17.1)'
);

select is(
  confirm_upload_target('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-00000000ffff', 'uploads.complete:u1', null, 60, null)
    ->> 'error',
  'FORBIDDEN',
  'and so is a photo id that does not exist, with the same code (§17.1)'
);

-- The hits, not merely a row: both refusals share one bucket, so an existence check
-- would pass just as well if only the first of them had been billed.
select results_eq(
  $$ select sum(hits)::int from private.rate_limit_hits
     where bucket like 'uploads.complete:u1:%' $$,
  $$ values (2) $$,
  'both are billed in every window: a photo id is per-request content (§17.1)'
);

-- The happy path: the first call hands back the object key and mutates nothing.
select is(
  confirm_upload_target('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000001', 'uploads.complete:ok', null, 60, null)
    ->> 'upload_path',
  '11111111-1111-1111-1111-111111111111/one',
  'the confirmation hands back the object key the route is to check (§8.1 step 3)'
);

select is(
  (select status::text from media where id = 'dddd0000-0000-0000-0000-000000000001'),
  'uploading',
  'and nothing has moved yet, so a failed Storage check leaves a row for the sweep'
);

-- The second call: §8.1 step 3's two writes.
select is(
  queue_photo_screening('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000001') ->> 'status',
  'processing',
  'the photo is set to processing (§8.1 step 3)'
);

select is(
  (select status::text from media where id = 'dddd0000-0000-0000-0000-000000000001'),
  'processing',
  'on the row itself, which is what §12.5 measures a stuck photo from'
);

select is(
  (select count(*)::int from pgmq.q_moderation
   where message ->> 'kind' = 'photo'
     and message ->> 'id' = 'dddd0000-0000-0000-0000-000000000001'),
  1,
  'and a moderation job is queued, the photo producer §8.3 had none of'
);

-- The idempotent second call. Not §7.1.1's replay — §5.2.1 gives `media` no idempotency
-- key, because this route is a transition on a resource the URL already names, which a
-- repeat cannot change (§17.1).
select is(
  confirm_upload_target('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000001', 'uploads.complete:again', null, 60, null)
    ->> 'upload_path',
  null,
  'a second completion gets no object key back, so the route makes no Storage call'
);

select is(
  confirm_upload_target('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000001', 'uploads.complete:again', null, 60, null)
    ->> 'status',
  'processing',
  'it is answered with the status the photo already has, not a refusal'
);

select is(
  queue_photo_screening('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000001') ->> 'status',
  'processing',
  'and the write half is idempotent too, for two completions that race'
);

select is(
  (select count(*)::int from pgmq.q_moderation
   where message ->> 'id' = 'dddd0000-0000-0000-0000-000000000001'),
  1,
  'so one photo never queues two screening jobs, and §8.4 pays for one verdict'
);

-- §17 O33, the control that matters most on this route: these functions run as
-- `service_role` and bypass the `status = 'active'` policy that governs clients, so
-- without this check an account §10.2 has already suspended could drive a photo to
-- `processing` and spend a Rekognition call per call (§8.4).
select is(
  confirm_upload_target('44444444-4444-4444-4444-444444444444',
    'dddd0000-0000-0000-0000-000000000004', 'uploads.complete:u4', null, 60, null)
    ->> 'error',
  'FORBIDDEN',
  'a suspended account cannot complete an upload (§17 O33)'
);

select isnt_empty(
  $$ select bucket from private.rate_limit_hits where bucket like 'uploads.complete:u4%' $$,
  'and is billed, because an account already judged abusive gets no free path (§17.1)'
);

select is(
  (select status::text from media where id = 'dddd0000-0000-0000-0000-000000000004'),
  'uploading',
  'and its photo has not moved'
);

-- The write half refuses on its own, rather than trusting the confirmation that ran
-- before it: nothing about the function's grant stops another caller reaching it.
select is(
  queue_photo_screening('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000003') ->> 'error',
  'FORBIDDEN',
  'the write half refuses another person''s photo too (§7.4, §17.1)'
);

select is(
  (select status::text from media where id = 'dddd0000-0000-0000-0000-000000000003'),
  'uploading',
  'and queues nothing for it'
);

-- §17 O33 again, on the half that writes: the route reaches it only through the
-- confirmation, but §10.2 and O33 are written about the function that acts, and a
-- suspension landing during the Storage round trip between the two calls would
-- otherwise still spend a screening call (§8.4).
select is(
  queue_photo_screening('44444444-4444-4444-4444-444444444444',
    'dddd0000-0000-0000-0000-000000000004') ->> 'error',
  'FORBIDDEN',
  'the write half refuses a suspended account on its own (§17 O33)'
);

-- §10.2's kill switches, which §10.2 requires a function to check "before doing
-- anything". Engaged as the owner: §5.2 gives `app_flags` only `admin_set_flag` as a
-- writer, so `service_role` holds select alone.
reset role;
update app_flags set engaged = true where key = 'uploads';
set local role service_role;
select is(
  confirm_upload_target('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000001', 'uploads.complete:flag', null, 60, null)
    ->> 'error',
  'FEATURE_DISABLED',
  'the uploads kill switch stops the completion too (§10.2)'
);

select is(
  queue_photo_screening('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000001') ->> 'error',
  'FEATURE_DISABLED',
  'and stops the half that writes, which is the half §10.2 is written about'
);

select is_empty(
  $$ select bucket from private.rate_limit_hits
     where bucket like 'uploads.complete:flag:%' $$,
  'and bills nothing, because the switch is checked above the count (§17.1)'
);

reset role;
update app_flags set engaged = false where key = 'uploads';
update app_flags set engaged = true where key = 'read_only';
set local role service_role;
select is(
  confirm_upload_target('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000001', 'uploads.complete:flag2', null, 60, null)
    ->> 'error',
  'FEATURE_DISABLED',
  'and so does read_only, which stops every write (§10.2)'
);
select is(
  queue_photo_screening('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000001') ->> 'error',
  'FEATURE_DISABLED',
  'and the half that writes checks them itself, which is what §10.2 asks of it'
);

reset role;
update app_flags set engaged = false where key = 'read_only';
set local role service_role;

-- An already-screened photo. Nothing re-queues it: §8.4's verdict is final until a
-- staff function moves it (§10.2).
select is(
  confirm_upload_target('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000002', 'uploads.complete:done', null, 60, null)
    ->> 'status',
  'ready',
  'a photo that has already passed screening is answered with its verdict'
);

reset role;
select * from finish();
rollback;
