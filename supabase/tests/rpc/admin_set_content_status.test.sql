begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (id, created_at) values
  ('aaaa1111-1111-1111-1111-111111111111', now() - interval '60 days'),
  ('99999999-9999-9999-9999-999999999999', now() - interval '60 days'),
  ('11111111-1111-1111-1111-111111111111', now() - interval '30 days');
insert into profiles (id, display_name) values
  ('aaaa1111-1111-1111-1111-111111111111', 'author'),
  ('99999999-9999-9999-9999-999999999999', 'moderator'),
  ('11111111-1111-1111-1111-111111111111', 'ordinary person');
insert into staff (user_id, role) values
  ('99999999-9999-9999-9999-999999999999', 'moderator');

insert into acts (id, author_id, title, story, category, occurred_on, location_coarse,
                  status, text_checked, idempotency_key, request_hash)
values
  ('bbbb0000-0000-0000-0000-000000000001', 'aaaa1111-1111-1111-1111-111111111111',
   'Up for review', 'An act a moderator is about to look at and decide something about.',
   'environment', '2026-10-12',
   extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
   'visible', true, '00000000-0000-0000-0000-0000000000b1', repeat('a', 64)),
  ('bbbb0000-0000-0000-0000-000000000002', 'aaaa1111-1111-1111-1111-111111111111',
   'Held for review', 'An act screening flagged, waiting for a person to approve or remove it.',
   'community', '2026-10-13',
   extensions.st_setsrid(extensions.st_makepoint(73.86, 18.53), 4326)::extensions.geography,
   'held', true, '00000000-0000-0000-0000-0000000000b2', repeat('b', 64));

-- §9.1: only `admin_*` is callable by a signed-in client, and §10.3 has every call run as
-- the staff member rather than as a key.
select ok(
  has_function_privilege('authenticated',
    'admin_set_content_status(uuid,uuid,uuid,content_status,text)', 'execute')
  and not has_function_privilege('anon',
    'admin_set_content_status(uuid,uuid,uuid,content_status,text)', 'execute')
  and not has_function_privilege('service_role',
    'admin_set_content_status(uuid,uuid,uuid,content_status,text)', 'execute'),
  'staff reach it as authenticated; anon and the secret key cannot (§9.1, §10.3)'
);

select ok(
  (select prosecdef from pg_proc where oid =
     'admin_set_content_status(uuid,uuid,uuid,content_status,text)'::regprocedure),
  'it is security definer: §5.2 gives authenticated no write on acts, activities or media'
);

set local role authenticated;

-- §10 and §9.3's first line, which §9.7 calls the only control on an admin_* function.
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","aal":"aal2"}';
select is(
  admin_set_content_status('bbbb0000-0000-0000-0000-000000000001', null, null,
    'removed', 'I do not like it') ->> 'error',
  'FORBIDDEN',
  'a signed-in person who is not staff cannot touch content (§10, §9.1)'
);

set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","aal":"aal1"}';
select is(
  admin_set_content_status('bbbb0000-0000-0000-0000-000000000001', null, null,
    'removed', 'without MFA') ->> 'error',
  'FORBIDDEN',
  'and neither can a moderator who has not completed MFA (§9.3)'
);

reset role;
select is(
  (select status::text from acts where id = 'bbbb0000-0000-0000-0000-000000000001'),
  'visible',
  'neither refusal moved the content'
);

-- Scoped to this file's own fixtures (§13.1): the count runs as the table's owner and
-- would otherwise see whatever any other session had left behind.
select is(
  (select count(*)::int from admin_audit_log
   where subject_id in ('bbbb0000-0000-0000-0000-000000000001',
                        'bbbb0000-0000-0000-0000-000000000002')),
  0,
  'and neither wrote an audit row, so the log is of actions rather than attempts'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","aal":"aal2"}';

-- §10: "requires a reason", bounded 3–500 by §5.2.1.
select is(
  admin_set_content_status('bbbb0000-0000-0000-0000-000000000001', null, null,
    'removed', 'no') ->> 'field',
  'reason',
  'a reason under §5.2.1''s three characters names the field rather than raising (§10)'
);

select is(
  admin_set_content_status('bbbb0000-0000-0000-0000-000000000001', null, null,
    'removed', repeat('x', 501)) ->> 'field',
  'reason',
  'and so does one over 500'
);

-- §5.1's shape: one subject per call, never a kind and an id.
select is(
  admin_set_content_status(null, null, null, 'removed', 'nothing named') ->> 'field',
  'subject',
  'a call naming no subject is refused by name'
);

select is(
  admin_set_content_status('bbbb0000-0000-0000-0000-000000000001',
    'aaaa0000-0000-0000-0000-000000000001', null, 'removed', 'two at once') ->> 'field',
  'subject',
  'and so is one naming two'
);

-- §10.2 gives this function three verbs; §5.3's fourth value is not one of them.
select is(
  admin_set_content_status('bbbb0000-0000-0000-0000-000000000002', null, null,
    'pending', 'back to screening') ->> 'field',
  'status',
  'putting content back into screening is refused by the shared transition rule (§8.3, §10.2)'
);

-- The happy path, which §8.5 has this function share with submit_report.
select is(
  admin_set_content_status('bbbb0000-0000-0000-0000-000000000002', null, null,
    'visible', 'reviewed, no violation found') ->> 'status',
  'visible',
  'a moderator approves held content (§10.2, §8.3)'
);

select is(
  admin_set_content_status('bbbb0000-0000-0000-0000-000000000001', null, null,
    'removed', 'court order 41 of 2026') ->> 'status',
  'removed',
  'and removes visible content (§10.2)'
);

reset role;

-- §10: "the audit log records who acted, not 'the admin tool'".
select results_eq(
  $$ select staff_id, action, subject_type, reason from admin_audit_log
     where subject_id = 'bbbb0000-0000-0000-0000-000000000001' $$,
  $$ values ('99999999-9999-9999-9999-999999999999'::uuid, 'set_content_status',
             'act', 'court order 41 of 2026') $$,
  'the audit row names the moderator who acted and the reason they gave (§10, §12.6)'
);

select * from finish();
rollback;
