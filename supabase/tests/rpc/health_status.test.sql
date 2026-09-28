begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

insert into auth.users (id, created_at)
select ('00000000-0000-0000-0000-00000000000' || n)::uuid, now() - interval '30 days'
from generate_series(1, 2) n;
insert into profiles (id, display_name)
select ('00000000-0000-0000-0000-00000000000' || n)::uuid, 'person ' || n
from generate_series(1, 2) n;

select ok(
  not has_function_privilege('anon', 'health_status()', 'execute')
  and not has_function_privilege('authenticated', 'health_status()', 'execute'),
  'the health check is reached through the route, not directly (§9.1)'
);

set local role service_role;

select is(health_status(), 'ok', 'an empty database is ok');

-- §10.4: "Any item pending 15 minutes". §8.3 calls this pending → pending.
-- §12.5 caches for 30 seconds, and now() is frozen inside this transaction, so every
-- condition below clears the entry first — the cache itself is asserted at the end.
reset role;
delete from private.discover_cache;
insert into acts
  (id, author_id, title, story, category, occurred_on, location_coarse, status,
   idempotency_key, request_hash, created_at)
values
  ('dddd0000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001',
   'Just filed', 'We filled eleven sacks along the bank before the rain came in.',
   'environment', current_date - 1,
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'pending', '00000000-0000-0000-0000-0000000000f1', repeat('1', 64),
   now() - interval '5 minutes');
set local role service_role;

select is(
  health_status(), 'ok',
  'an Act waiting five minutes is screening running, not screening stuck'
);

reset role;
delete from private.discover_cache;
update acts set created_at = now() - interval '16 minutes'
where id = 'dddd0000-0000-0000-0000-000000000001';
set local role service_role;

select is(
  health_status(), 'degraded',
  'one past fifteen minutes is the §10.4 stuck-screening condition'
);

reset role;
delete from private.discover_cache;
update acts set status = 'visible' where id = 'dddd0000-0000-0000-0000-000000000001';
insert into reports
  (id, reporter_id, subject_type, act_id, reason, status, idempotency_key, request_hash,
   created_at)
values
  ('eeee0000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002',
   'act', 'dddd0000-0000-0000-0000-000000000001', 'intimate_imagery', 'open',
   '00000000-0000-0000-0000-0000000000e1', repeat('a', 64), now() - interval '10 minutes');
set local role service_role;

select is(
  health_status(), 'ok',
  'an intimate imagery report ten minutes old is inside the 45-minute alarm (§10.4)'
);

reset role;
delete from private.discover_cache;
update reports set created_at = now() - interval '46 minutes'
where id = 'eeee0000-0000-0000-0000-000000000001';
set local role service_role;

select is(
  health_status(), 'degraded',
  'and past it the two-hour deadline is at risk (§10.4)'
);

-- §11.6 gives `impersonation` 60 minutes where §10.4 gives intimate imagery 45.
-- Owner decision, 28 September 2026: each section keeps its own number.
reset role;
delete from private.discover_cache;
update reports set reason = 'impersonation', created_at = now() - interval '50 minutes'
where id = 'eeee0000-0000-0000-0000-000000000001';
set local role service_role;

select is(
  health_status(), 'ok',
  'an impersonation report at 50 minutes is inside §11.6''s 60, not §10.4''s 45'
);

reset role;
delete from private.discover_cache;
update reports set created_at = now() - interval '61 minutes'
where id = 'eeee0000-0000-0000-0000-000000000001';
set local role service_role;

select is(
  health_status(), 'degraded',
  'and past 60 minutes it is the §11.6 condition'
);

reset role;
delete from private.discover_cache;
update reports
set status = 'actioned', resolved_at = now(), resolved_by = '00000000-0000-0000-0000-000000000001'
where id = 'eeee0000-0000-0000-0000-000000000001';
insert into reports
  (id, reporter_id, subject_type, act_id, reason, status, idempotency_key, request_hash,
   created_at)
values
  ('eeee0000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000002',
   'act', 'dddd0000-0000-0000-0000-000000000001', 'spam', 'open',
   '00000000-0000-0000-0000-0000000000e2', repeat('b', 64), now() - interval '21 hours');
set local role service_role;

select is(
  health_status(), 'degraded',
  'any report open twenty hours is the review-queue condition (§10.4)'
);

-- §8.1's photo worker is the other thing that can stick, and §10.4 gives it the same
-- fifteen minutes as the text it screens.
reset role;
delete from private.discover_cache;
update reports set status = 'dismissed', resolved_at = now(),
  resolved_by = '00000000-0000-0000-0000-000000000001' where status = 'open';
insert into media (id, owner_id, purpose, upload_path, status, created_at)
values ('bbbb0000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001',
        'act', 'uploads/p1/stuck.jpg', 'processing', now() - interval '16 minutes');
set local role service_role;

select is(
  health_status(), 'degraded',
  'a photo stuck in processing is the same stuck-screening condition (§8.1, §10.4)'
);

-- §12.5: "Results are cached for 30 seconds". The call above left `degraded` in the
-- entry; clearing the condition it was computed from must not change the answer until
-- the entry itself goes.
reset role;
update media set status = 'ready' where id = 'bbbb0000-0000-0000-0000-000000000001';
set local role service_role;

select is(
  health_status(), 'degraded',
  'the answer is served from the 30-second entry, not recomputed (§12.5)'
);

reset role;
delete from private.discover_cache;
set local role service_role;

select is(health_status(), 'ok', 'and is recomputed once that entry is gone');

select * from finish();
rollback;
