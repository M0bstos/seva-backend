begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

insert into auth.users (id) values ('a9000000-0000-4000-8000-000000000001');
insert into profiles (id, display_name)
values ('a9000000-0000-4000-8000-000000000001', 'Deletion probe');
insert into media (id, owner_id, purpose, upload_path, public_path, status)
values ('a9000000-0000-4000-8000-0000000000b1',
        'a9000000-0000-4000-8000-000000000001', 'act',
        'a9000000-0000-4000-8000-000000000001/b1.jpg',
        'a9000000-0000-4000-8000-000000000001/b1.jpg', 'ready');

select pgmq.purge_queue('ops');

select ok(
  (select p.prosecdef and pg_get_userbyid(p.proowner) = 'postgres'
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'queue_media_deletion'),
  'security definer owned by postgres, so an erasure cannot be blocked by who drove it'
);

-- The premise behind that choice: every deletion of a media row arrives by cascade,
-- and the role driving it need not be one `pgmq` admits. Only these two are.
select is_empty(
  $$ select r.rolname from
       (values ('supabase_auth_admin'::name), ('authenticated'), ('anon')) as r (rolname)
     where has_schema_privilege(r.rolname, 'pgmq', 'usage')
        or has_function_privilege(r.rolname, 'pgmq.send(text,jsonb)', 'execute') $$,
  'and the roles that could drive a cascade hold nothing in pgmq (§5.1)'
);

select ok(
  not has_function_privilege('anon', 'queue_media_deletion()', 'execute')
  and not has_function_privilege('authenticated', 'queue_media_deletion()', 'execute')
  and not has_function_privilege('service_role', 'queue_media_deletion()', 'execute'),
  'and nobody may call it directly to queue a deletion of someone else''s file'
);

-- §5.2 gives nobody `delete` on media: every deletion arrives by cascade, which is
-- what the definer choice above is about.
select is_empty(
  $$ select r.rolname from (values ('anon'::name), ('authenticated'::name),
                                   ('service_role'::name)) as r (rolname)
     where has_table_privilege(r.rolname, 'media', 'delete') $$,
  'no role holds delete on media, so the cascade is the only path'
);

-- §5.4: the files are what the job is for, because SQL cannot reach storage.
delete from media where id = 'a9000000-0000-4000-8000-0000000000b1';

select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'media_id' = 'a9000000-0000-4000-8000-0000000000b1'),
  1,
  'deleting a photo queues one ops job (§5.4)'
);

select is(
  (select message ->> 'kind' from pgmq.q_ops
   where message ->> 'media_id' = 'a9000000-0000-4000-8000-0000000000b1'),
  'delete_media_files',
  'naming the work, so the operations worker can branch on it'
);

select is(
  (select message ->> 'public_path' from pgmq.q_ops
   where message ->> 'media_id' = 'a9000000-0000-4000-8000-0000000000b1'),
  'a9000000-0000-4000-8000-000000000001/b1.jpg',
  'and carrying the published copy, which this phase is the first to write'
);

-- §9.8: an object path carries a user id, which logs may hold. The row must not ride
-- out with it — the labels, the bytes and the dimensions stay behind.
select is(
  (select count(*)::int from jsonb_object_keys(
     (select message from pgmq.q_ops
      where message ->> 'media_id' = 'a9000000-0000-4000-8000-0000000000b1')) as k),
  5,
  'the job carries the kind, the id and three paths, and nothing else (§9.8)'
);

-- §5.4's own path: account deletion removes the profile, and the photos go with it.
select pgmq.purge_queue('ops');
insert into media (id, owner_id, purpose, upload_path, status)
values ('a9000000-0000-4000-8000-0000000000b2',
        'a9000000-0000-4000-8000-000000000001', 'avatar',
        'a9000000-0000-4000-8000-000000000001/b2.jpg', 'ready');

-- Deleting the account through Auth, which is the cascade an invoker trigger would
-- have run as `supabase_auth_admin` for — a role with nothing in `pgmq` (§5.1).
delete from auth.users where id = 'a9000000-0000-4000-8000-000000000001';

select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'media_id' = 'a9000000-0000-4000-8000-0000000000b2'),
  1,
  'an account deletion cascading through profiles queues the photo''s job too (§5.4)'
);

select is(
  (select count(*)::int from media
   where id = 'a9000000-0000-4000-8000-0000000000b2'),
  0,
  'and the deletion itself is not blocked by the trigger'
);

-- §11.6's 180-day retention, which this trigger must not cut short. §5.4: a removed
-- or held row keeps "its database row, its snapshot and **its files** for 180 days",
-- and §11.6 writes the snapshot *before* deleting anything else, "so a user cannot
-- erase the record of their own violation by deleting their account". Reproduced
-- before the predicate existed: the job named the same object `file_paths` recorded.
select pgmq.purge_queue('ops');
insert into auth.users (id) values ('a9000000-0000-4000-8000-00000000d001');
insert into profiles (id, display_name)
values ('a9000000-0000-4000-8000-00000000d001', 'Retention probe');
insert into acts (id, author_id, title, story, category, occurred_on, location_coarse,
                  status, idempotency_key, request_hash)
values ('a9000000-0000-4000-8000-00000000dac1',
        'a9000000-0000-4000-8000-00000000d001', 'A morning at the river',
        'We filled eleven sacks along the bank before the rain came in at noon.',
        'environment', current_date - 1,
        extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
        'removed', gen_random_uuid(), repeat('d', 64));
insert into media (id, owner_id, purpose, act_id, upload_path, public_path, status)
values ('a9000000-0000-4000-8000-00000000d0d1',
        'a9000000-0000-4000-8000-00000000d001', 'act',
        'a9000000-0000-4000-8000-00000000dac1',
        'a9000000-0000-4000-8000-00000000d001/d1.jpg',
        'a9000000-0000-4000-8000-00000000d001/d1.jpg', 'ready');
insert into private.preserved_content (source_kind, source_id, snapshot, file_paths)
values ('act', 'a9000000-0000-4000-8000-00000000dac1',
        '{"title": "A morning at the river"}'::jsonb,
        array['a9000000-0000-4000-8000-00000000d001/d1.jpg']);

delete from auth.users where id = 'a9000000-0000-4000-8000-00000000d001';

select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'media_id' = 'a9000000-0000-4000-8000-00000000d0d1'),
  0,
  'a file §11.6 is retaining is not queued for deletion by the account going (§5.4)'
);

select is(
  (select count(*)::int from private.preserved_content
   where source_id = 'a9000000-0000-4000-8000-00000000dac1' and purge_after > now()),
  1,
  'and the record claiming to retain it is still there, for its 180 days'
);

-- Past the 180 days the retention row no longer holds the file, so the deletion the
-- §11.6 purge performs is queued like any other.
select pgmq.purge_queue('ops');
update private.preserved_content set purge_after = now() - interval '1 day'
where source_id = 'a9000000-0000-4000-8000-00000000dac1';
insert into auth.users (id) values ('a9000000-0000-4000-8000-00000000d002');
insert into profiles (id, display_name)
values ('a9000000-0000-4000-8000-00000000d002', 'Expired retention');
insert into media (id, owner_id, purpose, upload_path, status)
values ('a9000000-0000-4000-8000-00000000d0d2',
        'a9000000-0000-4000-8000-00000000d002', 'act',
        'a9000000-0000-4000-8000-00000000d001/d1.jpg', 'ready');
delete from media where id = 'a9000000-0000-4000-8000-00000000d0d2';

select is(
  (select count(*)::int from pgmq.q_ops
   where message ->> 'media_id' = 'a9000000-0000-4000-8000-00000000d0d2'),
  1,
  'while an expired retention row holds nothing back (§11.6)'
);

select * from finish();
rollback;
