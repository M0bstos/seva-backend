begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

insert into auth.users (id, created_at) values
  ('11111111-1111-1111-1111-111111111111', now() - interval '30 days'),
  ('22222222-2222-2222-2222-222222222222', now() - interval '30 days');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'anand'),
  ('22222222-2222-2222-2222-222222222222', 'bina');

insert into acts
  (id, author_id, title, story, category, occurred_on, location_coarse, status,
   text_checked, idempotency_key, request_hash)
values
  ('dddd0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'Mine and visible',
   'A story long enough to pass the twenty character minimum the table checks.',
   'community', '2026-09-20',
   extensions.st_setsrid(extensions.st_makepoint(73.85, 18.5), 4326)::extensions.geography,
   'visible', true, '00000000-0000-0000-0000-0000000000d1', repeat('a', 64)),
  ('dddd0000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222',
   'Theirs and visible',
   'A story long enough to pass the twenty character minimum the table checks.',
   'community', '2026-09-20',
   extensions.st_setsrid(extensions.st_makepoint(73.85, 18.5), 4326)::extensions.geography,
   'visible', true, '00000000-0000-0000-0000-0000000000d2', repeat('b', 64)),
  ('dddd0000-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222',
   'Theirs and pending',
   'A story long enough to pass the twenty character minimum the table checks.',
   'community', '2026-09-20',
   extensions.st_setsrid(extensions.st_makepoint(73.85, 18.5), 4326)::extensions.geography,
   'pending', false, '00000000-0000-0000-0000-0000000000d3', repeat('c', 64)),
  ('dddd0000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111',
   'Mine and removed',
   'A story long enough to pass the twenty character minimum the table checks.',
   'community', '2026-09-20',
   extensions.st_setsrid(extensions.st_makepoint(73.85, 18.5), 4326)::extensions.geography,
   'removed', true, '00000000-0000-0000-0000-0000000000d4', repeat('d', 64));

select ok(
  not has_function_privilege('anon', 'update_act(uuid,uuid,text,text,text,int,int,int)', 'execute')
  and not has_function_privilege('authenticated',
        'update_act(uuid,uuid,text,text,text,int,int,int)', 'execute'),
  'no client can call the edit function directly and skip its rate limit (§9.1)'
);

set local role service_role;

select is(
  update_act('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000001', 'A better title', null,
    'acts.update:u1', null, 30, null) #>> '{act,title}',
  'A better title',
  'the author edits the title (§7.3)'
);

select is(
  (select story from acts where id = 'dddd0000-0000-0000-0000-000000000001'),
  'A story long enough to pass the twenty character minimum the table checks.',
  'and a field left out is left alone'
);

-- §7.3: "Edits title and story; re-screens".
select is(
  (select text_checked from acts where id = 'dddd0000-0000-0000-0000-000000000001'),
  false,
  'an edit sends the act back for screening'
);

-- §8.3 as amended: an edit to visible content returns it to pending. Without this,
-- publishing something benign and then editing the text is a publish path that no
-- screening ever sees.
select is(
  (select status::text from acts where id = 'dddd0000-0000-0000-0000-000000000001'),
  'pending',
  'and a visible act is unpublished until it is screened again (§8.2, §8.3)'
);

-- §8.2: "Triggers on create and edit queue a text job" — two jobs for this act, one
-- from the fixture insert and one from the edit above.
select is(
  (select count(*)::int from pgmq.q_moderation
   where message ->> 'id' = 'dddd0000-0000-0000-0000-000000000001'),
  2,
  'both the create and the edit queued a screening job (§8.2)'
);

select is(
  (select distinct message ->> 'kind' from pgmq.q_moderation
   where message ->> 'id' = 'dddd0000-0000-0000-0000-000000000001'),
  'act_text',
  'naming the kind of text to screen, and carrying no text itself (§9.8)'
);

-- The worker sets text_checked, and that must not queue another job for itself.
update acts set text_checked = true where id = 'dddd0000-0000-0000-0000-000000000001';
select is(
  (select count(*)::int from pgmq.q_moderation
   where message ->> 'id' = 'dddd0000-0000-0000-0000-000000000001'),
  2,
  'and a write that touches no screened column queues nothing, so it cannot loop'
);

select is(
  update_act('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000002', 'Not mine', null,
    'acts.update:u1', null, 30, null) ->> 'error',
  'FORBIDDEN',
  'an act the caller can see but does not own is "Not yours" (§7.4)'
);

select is(
  update_act('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000003', 'Not mine either', null,
    'acts.update:u1', null, 30, null) ->> 'error',
  'NOT_FOUND',
  'and one they cannot see is missing as far as they are concerned (§7.4)'
);

select is(
  update_act('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-00000000dead', 'Nothing there', null,
    'acts.update:u1', null, 30, null) ->> 'error',
  'NOT_FOUND',
  'as is one that does not exist'
);

-- §11.6 keeps removed content for its retention period; it is not edited back.
select is(
  update_act('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000004', 'Rehabilitated', null,
    'acts.update:u1', null, 30, null) ->> 'error',
  'FORBIDDEN',
  'removed content cannot be edited back into circulation (§8.3)'
);

select is(
  update_act('33333333-3333-3333-3333-333333333333',
    'dddd0000-0000-0000-0000-000000000001', 'No profile', null,
    'acts.update:u3', null, 30, null) ->> 'error',
  'ONBOARDING_REQUIRED',
  'someone without a profile row cannot edit (§5.4)'
);

select is(
  update_act('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000001', 'Over the limit', null,
    'acts.update:capped', null, 0, null) ->> 'error',
  'RATE_LIMITED',
  'the limiter refuses before the act is read'
);

reset role;
update profiles set status = 'suspended' where id = '11111111-1111-1111-1111-111111111111';
set local role service_role;
select is(
  update_act('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000001', 'Suspended edit', null,
    'acts.update:u1', null, 30, null) ->> 'error',
  'FORBIDDEN',
  'a suspended author cannot edit either (§17 O33)'
);
reset role;
update profiles set status = 'active' where id = '11111111-1111-1111-1111-111111111111';
update app_flags set engaged = true where key = 'read_only';
set local role service_role;
select is(
  update_act('11111111-1111-1111-1111-111111111111',
    'dddd0000-0000-0000-0000-000000000001', 'Read only', null,
    'acts.update:u1', null, 30, null) ->> 'error',
  'FEATURE_DISABLED',
  'read_only stops an edit, and §5.3 has no switch of its own for editing'
);
reset role;
update app_flags set engaged = false where key = 'read_only';

select * from finish();
rollback;
