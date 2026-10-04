begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

insert into auth.users (id, created_at) values
  ('11111111-1111-1111-1111-111111111111', now() - interval '30 days'),
  ('22222222-2222-2222-2222-222222222222', now() - interval '30 days'),
  ('33333333-3333-3333-3333-333333333333', now() - interval '30 days');
insert into profiles (id, display_name, status, suspended_until) values
  ('11111111-1111-1111-1111-111111111111', 'anand', 'active', null),
  ('22222222-2222-2222-2222-222222222222', 'bina', 'suspended', now() + interval '2 days');
-- 33333333 has an auth row and no profile: §5.4's onboarding gate.

select ok(
  not has_function_privilege('anon',
    'create_upload(uuid,media_purpose,text,int,int,int)', 'execute')
  and not has_function_privilege('authenticated',
    'create_upload(uuid,media_purpose,text,int,int,int)', 'execute'),
  'no client can call the uploads function directly (§9.1, gate 3)'
);

set local role service_role;

-- §5.4's gate, above the limiter so the barred caller is not billed (§17.1).
select is(
  create_upload('33333333-3333-3333-3333-333333333333', 'act',
    'uploads.create:u3', null, 30, 100) ->> 'error',
  'ONBOARDING_REQUIRED',
  'an account with no profile row cannot ask for an upload URL (§5.4)'
);

select is_empty(
  $$ select bucket from private.rate_limit_hits where bucket like 'uploads.create:u3%' $$,
  'and is not billed for it, because onboarding sits above the count (§17.1)'
);

-- §17 O33: suspension sits below the limiter, so it is billed.
select is(
  create_upload('22222222-2222-2222-2222-222222222222', 'act',
    'uploads.create:u2', null, 30, 100) ->> 'error',
  'FORBIDDEN',
  'a suspended account cannot upload (§17 O33)'
);

select isnt_empty(
  $$ select bucket from private.rate_limit_hits where bucket like 'uploads.create:u2%' $$,
  'and is billed, because an account already judged abusive gets no free path (§17.1)'
);

select is(
  (select count(*)::int from media where owner_id = '22222222-2222-2222-2222-222222222222'),
  0,
  'and no row is written for it'
);

-- The happy path. §8.1 step 1: a photo ID and the object key the route signs. The
-- answer is captured in its own statement, because a subquery beside the call reads
-- the statement's own snapshot and cannot see the row the call is inserting.
create temp table made as
  select create_upload('11111111-1111-1111-1111-111111111111', 'act',
    'uploads.create:u1', null, 30, 100) as answer;

select is(
  (select answer ->> 'media_id' from made),
  (select id::text from media where owner_id = '11111111-1111-1111-1111-111111111111'),
  'the photo ID the route hands back is the row it wrote (§8.1 step 1)'
);

select is(
  (select answer ->> 'upload_path' from made),
  (select owner_id::text || '/' || id::text from media
   where owner_id = '11111111-1111-1111-1111-111111111111'),
  'the object key is {owner_id}/{media_id}, which §8.1 signs and the worker reads'
);

select is(
  (select status::text from media where owner_id = '11111111-1111-1111-1111-111111111111'),
  'uploading',
  'the row arrives in uploading, which §8.1 sweeps after 24 hours if nothing follows'
);

select is(
  (select public_path from media where owner_id = '11111111-1111-1111-1111-111111111111'),
  null,
  'and nothing is published, because §8 publishes nothing unscreened'
);

-- §7.3's 100/day. The caps arrive as arguments, so this asserts the wiring rather
-- than the number (§12.2 keeps the number in _shared/limits.ts).
select is(
  create_upload('11111111-1111-1111-1111-111111111111', 'act',
    'uploads.create:cap', null, null, 1) ->> 'error',
  null,
  'the first call against a cap of one succeeds'
);

select is(
  create_upload('11111111-1111-1111-1111-111111111111', 'act',
    'uploads.create:cap', null, null, 1) ->> 'error',
  'DAILY_LIMIT_REACHED',
  'and the second is refused with §7.4 daily code, not the per-minute one'
);

-- §10.2's kill switches, checked before anything else. Engaged as the owner: §5.2
-- gives `app_flags` only `admin_set_flag` as a writer, so `service_role` holds select
-- alone and a test that could flip one would be asserting the wrong schema.
reset role;
update app_flags set engaged = true where key = 'uploads';
set local role service_role;
select is(
  create_upload('11111111-1111-1111-1111-111111111111', 'avatar',
    'uploads.create:flag', null, 30, 100) ->> 'error',
  'FEATURE_DISABLED',
  'the uploads kill switch stops the route (§10.2)'
);

-- Pinned the way onboarding is, because §17.1's reason for putting the switch first is
-- that a caller barred by a rule they cannot see is not billed for it. Without this the
-- switch could be moved below the limiter and every other assertion here would stay
-- green while callers were charged for a route staff had switched off.
select is_empty(
  $$ select bucket from private.rate_limit_hits
     where bucket like 'uploads.create:flag:%' $$,
  'and bills nothing, because the switch is checked above the count (§17.1)'
);

reset role;
update app_flags set engaged = false where key = 'uploads';
update app_flags set engaged = true where key = 'read_only';
set local role service_role;
select is(
  create_upload('11111111-1111-1111-1111-111111111111', 'avatar',
    'uploads.create:flag2', null, 30, 100) ->> 'error',
  'FEATURE_DISABLED',
  'and so does read_only, which stops every write (§10.2)'
);

reset role;
select * from finish();
rollback;
