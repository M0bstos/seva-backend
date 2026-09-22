begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222'),
  ('33333333-3333-3333-3333-333333333333');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'anand'),
  ('22222222-2222-2222-2222-222222222222', 'bina'),
  ('33333333-3333-3333-3333-333333333333', 'chandra');

insert into acts
  (id, author_id, title, story, category, occurred_on, location_coarse,
   status, idempotency_key, request_hash)
values
  ('bbbb0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
   'Cleared the lake shore', 'We filled twelve sacks with plastic from the east bank this morning.',
   'environment', '2026-10-12',
   extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
   'visible', '00000000-0000-0000-0000-0000000000b1', repeat('a', 64)),
  ('bbbb0000-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333',
   'Fed the street dogs', 'Took food to the colony behind the market every evening this week.',
   'animals', '2026-10-13',
   extensions.st_setsrid(extensions.st_makepoint(73.86, 18.53), 4326)::extensions.geography,
   'visible', '00000000-0000-0000-0000-0000000000b2', repeat('b', 64)),
  ('bbbb0000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   'Planted saplings', 'Put in twenty saplings along the ridge path with help from neighbours.',
   'environment', '2026-10-14',
   extensions.st_setsrid(extensions.st_makepoint(73.87, 18.54), 4326)::extensions.geography,
   'pending', '00000000-0000-0000-0000-0000000000b3', repeat('c', 64));

insert into blocks (blocker_id, blocked_id) values
  ('11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333');

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.acts'::regclass and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'public.acts', a.attname, 'insert')
       and a.attname not in ('author_id', 'activity_id', 'title', 'story', 'category', 'occurred_on',
                            'location_coarse', 'idempotency_key', 'request_hash') $$,
  'the create function supplies only its own columns; screening state and counters take their defaults'
);

select ok(
  has_table_privilege('authenticated', 'acts', 'SELECT')
  and not has_table_privilege('authenticated', 'acts',
    'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'acts', 'INSERT, UPDATE, REFERENCES'),
  'acts are created by functions, so no client writes one directly'
);

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'public.acts'::regclass and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'public.acts', a.attname, 'update')
       and a.attname not in ('title', 'story', 'status', 'text_checked', 'published_at') $$,
  'the backend updates the edited text and screening state, never the author or the location'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select results_eq(
  $$ select title from acts order by occurred_on $$,
  $$ values ('Cleared the lake shore'::text), ('Planted saplings'::text) $$,
  'a signed-in user reads visible acts and their own, minus authors they blocked'
);

select is_empty(
  $$ select 1 from acts where author_id = '33333333-3333-3333-3333-333333333333' $$,
  'a blocked authors act is hidden even though it is visible'
);

select throws_ok(
  $$ update acts set status = 'visible'
     where id = 'bbbb0000-0000-0000-0000-000000000003' $$,
  '42501',
  null,
  'an author cannot publish their own act past screening'
);

select throws_ok(
  $$ delete from acts where id = 'bbbb0000-0000-0000-0000-000000000003' $$,
  '42501',
  null,
  'content is never hard-deleted by a client'
);

reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';

select results_eq(
  $$ select count(*)::int from acts $$,
  $$ values (2) $$,
  'someone who blocked nobody sees both visible acts and not the pending one'
);

reset role;

select throws_ok(
  $$ insert into acts (author_id, title, story, category, occurred_on, location_coarse,
                       idempotency_key, request_hash)
     values ('22222222-2222-2222-2222-222222222222', 'Duplicate',
       'Same author and the same idempotency key, which the unique constraint must refuse.',
       'community', '2026-10-15',
       extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
       '00000000-0000-0000-0000-0000000000b1', repeat('d', 64)) $$,
  '23505',
  null,
  'the same idempotency key cannot create a second act for one author'
);

select throws_ok(
  $$ insert into acts (author_id, title, story, category, occurred_on, location_coarse,
                       idempotency_key, request_hash)
     values ('22222222-2222-2222-2222-222222222222', 'Short hash',
       'The request hash must be a sixty-four character hex digest, and this one is not.',
       'community', '2026-10-15',
       extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
       '00000000-0000-0000-0000-0000000000b4', 'tooshort') $$,
  '23514',
  null,
  'the request hash is a fixed sixty-four characters'
);

set local role service_role;

select lives_ok(
  $$ insert into acts (author_id, title, story, category, occurred_on, location_coarse,
                       idempotency_key, request_hash)
     values ('11111111-1111-1111-1111-111111111111', 'Swept the temple steps',
       'Cleared leaves and litter from the steps and the path leading up to them.',
       'community', '2026-10-20',
       extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
       '00000000-0000-0000-0000-0000000000b9', repeat('f', 64)) $$,
  'the create function can create an act, which arrives pending'
);

select results_eq(
  $$ select status::text, published_at from acts
     where idempotency_key = '00000000-0000-0000-0000-0000000000b9' $$,
  $$ values ('pending'::text, null::timestamptz) $$,
  'and it cannot arrive visible, which is what would award points'
);

select lives_ok(
  $$ update acts set status = 'visible', text_checked = true, published_at = now()
     where id = 'bbbb0000-0000-0000-0000-000000000003' $$,
  'the moderation worker publishes an act once it passes screening'
);

reset role;

select lives_ok(
  $$ delete from profiles where id = '22222222-2222-2222-2222-222222222222' $$,
  'an author profile can be deleted'
);

select is_empty(
  $$ select 1 from acts where author_id = '22222222-2222-2222-2222-222222222222' $$,
  'and their acts cascade away with them'
);

select results_eq(
  $$ select count(*)::int from acts $$,
  $$ values (3) $$,
  'while everyone elses acts survive, including the one just created'
);

select * from finish();
rollback;
