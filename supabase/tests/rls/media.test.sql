begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'anand'),
  ('22222222-2222-2222-2222-222222222222', 'bina');

insert into acts (id, author_id, title, story, category, occurred_on, location_coarse,
                  status, idempotency_key, request_hash)
values
  ('bbbb0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
   'Cleared the lake shore', 'We filled twelve sacks with plastic from the east bank this morning.',
   'environment', '2026-10-12',
   extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
   'visible', '00000000-0000-0000-0000-0000000000b1', repeat('a', 64)),
  ('bbbb0000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222',
   'Taken down', 'This act was removed by staff and must not show its photos to anyone else.',
   'environment', '2026-10-13',
   extensions.st_setsrid(extensions.st_makepoint(73.86, 18.53), 4326)::extensions.geography,
   'removed', '00000000-0000-0000-0000-0000000000b2', repeat('b', 64)),
  ('bbbb0000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   'Still in screening', 'My own act, not yet published, whose photo I should still be able to see.',
   'environment', '2026-10-14',
   extensions.st_setsrid(extensions.st_makepoint(73.87, 18.54), 4326)::extensions.geography,
   'pending', '00000000-0000-0000-0000-0000000000b3', repeat('c', 64));

insert into media (id, owner_id, purpose, act_id, upload_path, status) values
  ('dddd0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
   'act', 'bbbb0000-0000-0000-0000-000000000001', 'uploads/bina/ready-visible.jpg', 'ready'),
  ('dddd0000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222',
   'act', 'bbbb0000-0000-0000-0000-000000000001', 'uploads/bina/held-visible.jpg', 'held'),
  ('dddd0000-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222',
   'act', 'bbbb0000-0000-0000-0000-000000000002', 'uploads/bina/ready-removed.jpg', 'ready'),
  ('dddd0000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111',
   'act', 'bbbb0000-0000-0000-0000-000000000003', 'uploads/anand/own-pending.jpg', 'uploading');
insert into media (id, owner_id, purpose, upload_path, status) values
  ('dddd0000-0000-0000-0000-000000000004', '22222222-2222-2222-2222-222222222222',
   'avatar', 'uploads/bina/avatar.jpg', 'ready');

select ok(
  has_table_privilege('authenticated', 'media', 'SELECT')
  and not has_table_privilege('authenticated', 'media',
    'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'media', 'INSERT, UPDATE, REFERENCES'),
  'photos are written by the uploads function and the moderation worker, never by a client'
);

select ok(
  has_table_privilege('service_role', 'media', 'SELECT'),
  'the backend reads every photo, which the worker needs to screen one'
);

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.media'::regclass and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'public.media', a.attname, 'insert')
       and a.attname not in ('id', 'owner_id', 'purpose', 'upload_path') $$,
  'an upload arrives with only its own path; screening state and dimensions take defaults'
);

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.media'::regclass and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'public.media', a.attname, 'update')
       and a.attname not in ('act_id', 'activity_id', 'position', 'public_path',
                             'thumb_path', 'bytes', 'width', 'height', 'status', 'labels') $$,
  'attaching and publishing never rewrite who owns a photo or where it was uploaded'
);

select throws_ok(
  $$ insert into media (owner_id, purpose, act_id, activity_id, upload_path)
     values ('22222222-2222-2222-2222-222222222222', 'act',
             'bbbb0000-0000-0000-0000-000000000001',
             'aaaa0000-0000-0000-0000-000000000009', 'uploads/bina/two-parents.jpg') $$,
  '23514',
  null,
  'a photo belongs to at most one piece of content'
);

select throws_ok(
  $$ insert into media (owner_id, purpose, act_id, upload_path)
     values ('22222222-2222-2222-2222-222222222222', 'avatar',
             'bbbb0000-0000-0000-0000-000000000001', 'uploads/bina/wrong-purpose.jpg') $$,
  '23514',
  null,
  'and a parent that disagrees with the purpose is refused'
);

select lives_ok(
  $$ insert into media (owner_id, purpose, upload_path)
     values ('22222222-2222-2222-2222-222222222222', 'act', 'uploads/bina/not-yet-attached.jpg') $$,
  'while a photo uploaded before its act exists is allowed, which is the order 8.1 uses'
);

select throws_ok(
  $$ insert into media (owner_id, purpose, upload_path, bytes)
     values ('22222222-2222-2222-2222-222222222222', 'avatar',
             'uploads/bina/toobig.jpg', 5242881) $$,
  '23514',
  null,
  'a photo cannot exceed five megabytes'
);

select throws_ok(
  $$ insert into media (owner_id, purpose, upload_path)
     values ('22222222-2222-2222-2222-222222222222', 'avatar',
             'uploads/bina/avatar.jpg') $$,
  '23505',
  null,
  'two photos cannot claim the same upload path'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select results_eq(
  $$ select upload_path from media order by upload_path $$,
  $$ values ('uploads/anand/own-pending.jpg'::text),
            ('uploads/bina/ready-visible.jpg'::text) $$,
  'a signed-in user reads ready photos on visible content, and their own in any state'
);

select is_empty(
  $$ select 1 from media where id = 'dddd0000-0000-0000-0000-000000000002' $$,
  'a held photo on a visible act is not readable, so unscreened imagery never leaks'
);

select is_empty(
  $$ select 1 from media where id = 'dddd0000-0000-0000-0000-000000000003' $$,
  'a ready photo on a removed act is not readable either'
);

select is_empty(
  $$ select 1 from media where id = 'dddd0000-0000-0000-0000-000000000004' $$,
  'and someone elses avatar is not readable, since it hangs off no visible content'
);

reset role;
insert into blocks (blocker_id, blocked_id) values
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select results_eq(
  $$ select count(*)::int from media $$,
  $$ values (1) $$,
  'blocking an author hides their photos too, inherited from the act policy'
);

reset role;
set local role service_role;

select lives_ok(
  $$ insert into media (id, owner_id, purpose, upload_path)
     values ('dddd0000-0000-0000-0000-00000000000f',
             '22222222-2222-2222-2222-222222222222', 'act',
             'uploads/22222222-2222-2222-2222-222222222222/dddd0000-0000-0000-0000-00000000000f') $$,
  'the uploads function creates a row whose path embeds its own id, per 8.1 step 1'
);

select results_eq(
  $$ select status::text, act_id from media
     where id = 'dddd0000-0000-0000-0000-00000000000f' $$,
  $$ values ('uploading'::text, null::uuid) $$,
  'which starts as uploading and attached to nothing'
);

select lives_ok(
  $$ update media set act_id = 'bbbb0000-0000-0000-0000-000000000001', position = 1
     where id = 'dddd0000-0000-0000-0000-00000000000f' $$,
  'and the act create function attaches it afterwards'
);

reset role;
select * from finish();
rollback;
