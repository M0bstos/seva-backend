begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

insert into auth.users (id, created_at, phone, email) values
  ('11111111-1111-1111-1111-111111111111', now() - interval '200 days',
   '919000000003', 'exporting@seva.test'),
  ('22222222-2222-2222-2222-222222222222', now() - interval '30 days', null, null);
insert into profiles (id, display_name, bio, avatar_path) values
  ('11111111-1111-1111-1111-111111111111', 'anand', 'I clean lakes.',
   '11111111-1111-1111-1111-111111111111/avatar'),
  ('22222222-2222-2222-2222-222222222222', 'somebody else', null, null);
insert into profile_private (user_id, date_of_birth, terms_version, privacy_version)
values ('11111111-1111-1111-1111-111111111111', '1995-04-04', '2026-09-01', '2026-09-15');

insert into acts (id, author_id, title, story, category, occurred_on, location_coarse,
                  status, text_checked, idempotency_key, request_hash)
values ('bbbb0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        'Cleared the lake shore',
        'We filled twelve sacks with plastic from the east bank this morning.',
        'environment', '2026-10-12',
        extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
        'visible', true, '00000000-0000-0000-0000-0000000000b1', repeat('a', 64));
insert into act_metrics (act_id, metric, value)
values ('bbbb0000-0000-0000-0000-000000000001', 'waste_kg', 50);

-- An Activity they organised, whose meeting point §5.4 keeps exact and public. Without this
-- fixture the location assertion below reads an empty list and proves nothing.
insert into activities (id, organiser_id, title, description, category, starts_at, ends_at,
                        location, location_label, capacity, status,
                        idempotency_key, request_hash)
values ('aaaa0000-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'Lake shore cleanup',
        'Bring gloves and water. We meet at the east gate and finish before noon.',
        'environment', now() + interval '2 days', now() + interval '2 days 3 hours',
        extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
        'East gate', 40, 'visible',
        '00000000-0000-0000-0000-0000000000c1', repeat('c', 64));

-- One published photo and one still in screening: §7.3 gives the first a URL and the second
-- none.
insert into media (id, owner_id, purpose, act_id, upload_path, public_path, status) values
  ('dddd0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'act', 'bbbb0000-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111/one',
   '11111111-1111-1111-1111-111111111111/one', 'ready'),
  ('dddd0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'act', 'bbbb0000-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111/two', null, 'processing');

insert into blocks (blocker_id, blocked_id)
values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');

insert into reports (reporter_id, subject_type, reported_user_id, reason, details,
                     idempotency_key, request_hash)
values ('11111111-1111-1111-1111-111111111111', 'profile',
        '22222222-2222-2222-2222-222222222222', 'harassment', 'they keep messaging me',
        '00000000-0000-0000-0000-0000000000e1', repeat('e', 64));

-- A report somebody else filed about them, which the export must not carry.
insert into reports (reporter_id, subject_type, reported_user_id, reason, details,
                     idempotency_key, request_hash)
values ('22222222-2222-2222-2222-222222222222', 'profile',
        '11111111-1111-1111-1111-111111111111', 'spam', 'they posted the same act twice',
        '00000000-0000-0000-0000-0000000000e2', repeat('f', 64));

select ok(
  not has_function_privilege('anon', 'export_account(uuid,text)', 'execute')
  and not has_function_privilege('authenticated', 'export_account(uuid,text)', 'execute')
  and has_function_privilege('service_role', 'export_account(uuid,text)', 'execute'),
  'the worker may call it and no client can (§9.1, §7.3)'
);

select ok(
  not (select prosecdef from pg_proc where oid = 'export_account(uuid,text)'::regprocedure),
  'and it is invoker: §5.2 grants service_role select on everything it reads (§9.1)'
);

set local role service_role;

create temp table dump as
  select export_account('11111111-1111-1111-1111-111111111111',
    'https://seva.test/storage/v1/object/public/media') as answer;

select is(
  (select answer #>> '{profile,display_name}' from dump),
  'anand',
  'the export carries the public profile (§11.2''s access right)'
);

select is(
  (select answer #>> '{profile,avatar_url}' from dump),
  'https://seva.test/storage/v1/object/public/media/11111111-1111-1111-1111-111111111111/avatar',
  'with the avatar as a URL rather than a path (§7.3)'
);

select is(
  (select answer #>> '{private,date_of_birth}' from dump),
  '1995-04-04',
  'and the private record, which §11.2 stores at onboarding'
);

select is(
  (select answer #>> '{acts,0,metrics,waste_kg}' from dump),
  '50.00',
  'every Act with the claims that fed §6''s ledger'
);

-- §7.3: "Published photos appear as public URLs; unpublished ones are listed without a URL."
select is(
  (select answer #>> '{acts,0,photos,0,url}' from dump),
  'https://seva.test/storage/v1/object/public/media/11111111-1111-1111-1111-111111111111/one',
  'a published photo appears as a public URL (§7.3)'
);

select is(
  (select answer #>> '{acts,0,photos,1,url}' from dump),
  null,
  'and one still in screening is listed without one (§7.3)'
);

-- Reversed on a compliance finding: the export carried no location at all, including the
-- organiser's own public meeting point. What it must not carry is PostGIS's hex — §11.2's access
-- right is answered by a coordinate a person can read, and `0101000020` is the WKB prefix every
-- geography column serialises to through `to_jsonb`.
select ok(
  (select answer::text not like '%0101000020%' from dump),
  'no raw PostGIS hex reaches the file, which is unreadable rather than private (§11.2)'
);

select is(
  (select answer #>> '{acts,0,location_coarse,lon}' from dump),
  '73.85',
  'an Act carries the coarse grid §5.4 stored, as coordinates the person can read'
);

select is(
  (select answer #>> '{activities_organised,0,location,lat}' from dump),
  '18.52',
  'and an Activity its exact meeting point, which §5.4 makes public for that purpose'
);

-- The export is of the person's own data. A report about them is somebody else's text.
select is(
  (select jsonb_array_length(answer -> 'reports_filed') from dump),
  1,
  'reports they filed are theirs to see (§11.2)'
);

select ok(
  (select answer::text not like '%posted the same act twice%' from dump),
  'and a report filed about them is not, because it is another person''s words (§7.2)'
);

-- §5.4 keeps the phone and the email in Supabase Auth, and this body never reads auth.
select ok(
  (select answer::text not like '%919000000003%'
     and answer::text not like '%exporting@seva.test%'
   from dump),
  'neither the phone number nor the email is in the export, which §5.4 keeps in Auth'
);

reset role;
-- §11.2's access right is answered with `to_jsonb(pp)` — the whole `profile_private` row minus
-- nothing. That is deliberate: it is the person's own data and withholding it is what needed the
-- argument, not including it. But a denylist shape means a column added later lands in the document
-- with no test failing, and this is the table holding the date of birth and `guardian_consent`. So
-- the column set is pinned: adding one fails here, which forces the decision rather than making it
-- by default.
select is(
  (select array_agg(a.attname::text order by a.attname::text) from pg_attribute a
   where a.attrelid = 'public.profile_private'::regclass
     and a.attnum > 0 and not a.attisdropped),
  array['accepted_at', 'date_of_birth', 'email_opt_in', 'guardian_consent', 'locale',
        'privacy_version', 'terms_version', 'updated_at', 'user_id'],
  'the export dumps every profile_private column, so the column set is pinned (§11.2, §9.2)'
);

-- The subject ids the review found missing, which is what makes the list readable by its subject.
select is(
  (select answer #>> '{reports_filed,0,reported_user_id}' from dump),
  '22222222-2222-2222-2222-222222222222',
  'a filed report names the subject it was about, which the review found missing (§11.2)'
);

select * from finish();
rollback;

