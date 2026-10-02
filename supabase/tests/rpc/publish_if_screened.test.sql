begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

insert into auth.users (id, created_at)
values ('f2000000-0000-4000-8000-000000000001', now() - interval '30 days');
insert into profiles (id, display_name)
values ('f2000000-0000-4000-8000-000000000001', 'Screening author');

create function pg_temp.new_act(p_id uuid) returns void
language sql as $$
  insert into acts (id, author_id, title, story, category, occurred_on,
                    location_coarse, status, idempotency_key, request_hash)
  values (p_id, 'f2000000-0000-4000-8000-000000000001', 'A morning at the river',
          'We filled eleven sacks along the bank before the rain came in at noon.',
          'environment', current_date - 1,
          extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
          'pending', gen_random_uuid(), repeat('1', 64));
$$;

select ok(
  not has_function_privilege('anon', 'private.publish_if_screened(uuid,uuid)', 'execute')
  and not has_function_privilege('authenticated',
        'private.publish_if_screened(uuid,uuid)', 'execute'),
  'no client may publish their own unscreened content (§9.1, gate 6)'
);

select ok(
  has_function_privilege('service_role', 'private.publish_if_screened(uuid,uuid)', 'execute'),
  'the worker reaches it through the completion functions (§9.5)'
);

-- §8.3: an Act whose text has not passed stays pending however many photos are ready.
select pg_temp.new_act('f2000000-0000-4000-8000-0000000000a1');
set local role service_role;
select private.publish_if_screened('f2000000-0000-4000-8000-0000000000a1', null);

select is(
  (select status::text from acts where id = 'f2000000-0000-4000-8000-0000000000a1'),
  'pending',
  'text that has not passed keeps an Act pending'
);

-- With the text passed and no photos at all, there is nothing left to wait for.
reset role;
update acts set text_checked = true where id = 'f2000000-0000-4000-8000-0000000000a1';
set local role service_role;
select private.publish_if_screened('f2000000-0000-4000-8000-0000000000a1', null);

select is(
  (select status::text from acts where id = 'f2000000-0000-4000-8000-0000000000a1'),
  'visible',
  'and an Act with no photos publishes on its text alone'
);

select ok(
  (select published_at from acts where id = 'f2000000-0000-4000-8000-0000000000a1')
    is not null,
  'with published_at set, which §6.1''s award trigger fires alongside'
);

-- §5.2.1: `published_at` records *first* publication, and §8.3 sends an edited Act
-- back through pending.
reset role;
update acts set published_at = now() - interval '5 days'
where id = 'f2000000-0000-4000-8000-0000000000a1';
update acts set status = 'pending', text_checked = true
where id = 'f2000000-0000-4000-8000-0000000000a1';
set local role service_role;
select private.publish_if_screened('f2000000-0000-4000-8000-0000000000a1', null);

select ok(
  (select published_at from acts where id = 'f2000000-0000-4000-8000-0000000000a1')
    < now() - interval '4 days',
  'republishing after an edit keeps the original published_at (§5.2.1)'
);

-- §8: "An Act or Activity leaves `pending` only when its text and every one of its
-- photos have passed."
reset role;
select pg_temp.new_act('f2000000-0000-4000-8000-0000000000a2');
update acts set text_checked = true where id = 'f2000000-0000-4000-8000-0000000000a2';
insert into media (id, owner_id, purpose, act_id, upload_path, status) values
  ('f2000000-0000-4000-8000-0000000000b1', 'f2000000-0000-4000-8000-000000000001',
   'act', 'f2000000-0000-4000-8000-0000000000a2', 'uploads/f2/b1.jpg', 'ready'),
  ('f2000000-0000-4000-8000-0000000000b2', 'f2000000-0000-4000-8000-000000000001',
   'act', 'f2000000-0000-4000-8000-0000000000a2', 'uploads/f2/b2.jpg', 'processing');
set local role service_role;
select private.publish_if_screened('f2000000-0000-4000-8000-0000000000a2', null);

select is(
  (select status::text from acts where id = 'f2000000-0000-4000-8000-0000000000a2'),
  'pending',
  'one photo still in processing keeps the Act pending, even with the text passed'
);

reset role;
update media set status = 'held' where id = 'f2000000-0000-4000-8000-0000000000b2';
set local role service_role;
select private.publish_if_screened('f2000000-0000-4000-8000-0000000000a2', null);

select is(
  (select status::text from acts where id = 'f2000000-0000-4000-8000-0000000000a2'),
  'pending',
  'and a held photo is not a passed one either'
);

reset role;
update media set status = 'ready' where id = 'f2000000-0000-4000-8000-0000000000b2';
set local role service_role;
select private.publish_if_screened('f2000000-0000-4000-8000-0000000000a2', null);

select is(
  (select status::text from acts where id = 'f2000000-0000-4000-8000-0000000000a2'),
  'visible',
  'with every photo ready it publishes'
);

-- §8.3's held → visible is "a moderator approves", never this function.
reset role;
update acts set status = 'held' where id = 'f2000000-0000-4000-8000-0000000000a2';
set local role service_role;
select private.publish_if_screened('f2000000-0000-4000-8000-0000000000a2', null);

select is(
  (select status::text from acts where id = 'f2000000-0000-4000-8000-0000000000a2'),
  'held',
  'held content is a moderator''s to release, not screening''s (§8.3)'
);

reset role;
select * from finish();
rollback;
