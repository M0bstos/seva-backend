begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

insert into auth.users (id, created_at)
select ('00000000-0000-0000-0000-00000000000' || n)::uuid, now() - interval '30 days'
from generate_series(1, 4) n;
insert into profiles (id, display_name)
select ('00000000-0000-0000-0000-00000000000' || n)::uuid, 'person ' || n
from generate_series(1, 4) n;

insert into activities
  (id, organiser_id, title, description, category, starts_at, ends_at, location,
   location_label, capacity, status, idempotency_key, request_hash)
values
  ('aaaa0000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001',
   'Lake shore cleanup', 'Bring gloves and water. We meet at the east gate at dawn.',
   'environment', now() + interval '10 days', now() + interval '10 days 3 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'East gate', 40, 'visible', '00000000-0000-0000-0000-0000000000f1', repeat('f', 64));

select ok(
  not has_function_privilege('anon', 'leave_activity(uuid,uuid,text,int,int,int)', 'execute')
  and not has_function_privilege('anon', 'cancel_activity(uuid,uuid,text,int,int,int)', 'execute')
  and not has_function_privilege('authenticated',
        'cancel_activity(uuid,uuid,text,int,int,int)', 'execute'),
  'no client can leave or cancel directly (§9.1)'
);

set local role service_role;

select is(
  (join_activity('00000000-0000-0000-0000-000000000002',
    'aaaa0000-0000-0000-0000-000000000001', 'join:u2', null, 30, null)
   ->> 'participant_count'),
  '1',
  'someone joins'
);

-- §7.3: "Frees the place", and the leave shares the join limit.
select is(
  (leave_activity('00000000-0000-0000-0000-000000000002',
    'aaaa0000-0000-0000-0000-000000000001', 'join:u2', null, 30, null)
   ->> 'participant_count'),
  '0',
  'and leaving frees the place (§7.3)'
);

select is(
  (select status::text from activity_participants
   where user_id = '00000000-0000-0000-0000-000000000002'),
  'left',
  'the row is kept and marked left, not deleted'
);

select ok(
  (select left_at is not null from activity_participants
   where user_id = '00000000-0000-0000-0000-000000000002'),
  'with left_at set, which §5.2.1 ties to the status'
);

-- Leaving twice has nothing left to free, and §7.3 describes an outcome not an event.
select is(
  (leave_activity('00000000-0000-0000-0000-000000000002',
    'aaaa0000-0000-0000-0000-000000000001', 'join:u2', null, 30, null)
   ->> 'participant_count'),
  '0',
  'leaving twice is not an error, and does not count down twice'
);

select is(
  leave_activity('00000000-0000-0000-0000-000000000003',
    'aaaa0000-0000-0000-0000-000000000001', 'join:u3', null, 30, null) ->> 'error',
  'NOT_FOUND',
  'someone who never joined has nothing to leave'
);

-- §7.3: rejoining is allowed while there is room.
select is(
  (join_activity('00000000-0000-0000-0000-000000000002',
    'aaaa0000-0000-0000-0000-000000000001', 'join:u2', null, 30, null)
   ->> 'participant_count'),
  '1',
  'and they can rejoin afterwards'
);

select is(
  (select count(*)::int from activity_participants
   where user_id = '00000000-0000-0000-0000-000000000002'),
  1,
  'reusing the one row the primary key allows'
);

-- §7.3 scopes cancelling to the organiser.
select is(
  cancel_activity('00000000-0000-0000-0000-000000000002',
    'aaaa0000-0000-0000-0000-000000000001', 'cancel:u2', null, null, 5) ->> 'error',
  'FORBIDDEN',
  'a participant cannot cancel someone else''s activity (§7.3)'
);

select is(
  cancel_activity('00000000-0000-0000-0000-000000000001',
    'aaaa0000-0000-0000-0000-00000000dead', 'cancel:u1', null, null, 5) ->> 'error',
  'NOT_FOUND',
  'nor can the organiser cancel one that does not exist'
);

-- §7.3: "Cancels and emails participants". The mail is queued for the worker (§4).
select is(
  (cancel_activity('00000000-0000-0000-0000-000000000001',
    'aaaa0000-0000-0000-0000-000000000001', 'cancel:u1', null, null, 5)
   ->> 'notified'),
  '1',
  'the organiser cancels, and every joined participant is queued a message'
);

select ok(
  (select cancelled_at is not null from activities
   where id = 'aaaa0000-0000-0000-0000-000000000001'),
  'and the activity is marked cancelled (§5.2.1)'
);

select is(
  (select count(*)::int from pgmq.q_email),
  1,
  'exactly one job reached the email queue, one per joined participant'
);

-- §5.4 keeps an address out of the profile tables, and §9.8 out of anything logged,
-- so the job carries ids and the worker resolves the address from Auth.
select is_empty(
  $$ select msg_id from pgmq.q_email
     where message ? 'email' or message ? 'phone' or message ? 'display_name' $$,
  'the queued job carries ids only, never an address (§5.4, §9.8)'
);

-- Cancelling is one-way (§5.2.1 has no uncancel), so it cannot be a mail channel.
select is(
  (cancel_activity('00000000-0000-0000-0000-000000000001',
    'aaaa0000-0000-0000-0000-000000000001', 'cancel:u1', null, null, 5)
   ->> 'notified'),
  '0',
  'cancelling again queues nothing, so it is not a way to mail people repeatedly'
);

select is(
  (select count(*)::int from pgmq.q_email),
  1,
  'and the queue is unchanged'
);

-- §17 O33 deliberately does NOT reach leave or cancel: holding a place a suspended
-- person cannot give up penalises the organiser, and participants turning up to an
-- event nobody will run are punished for someone else's suspension. Pinned here so a
-- later pass making the write functions uniform cannot undo a reasoned decision as if
-- it were a typo.
reset role;
insert into activities
  (id, organiser_id, title, description, category, starts_at, ends_at, location,
   location_label, capacity, status, idempotency_key, request_hash)
values
  ('aaaa0000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000004',
   'Second cleanup', 'Bring gloves and water. We meet at the east gate at dawn.',
   'environment', now() + interval '10 days', now() + interval '10 days 3 hours',
   extensions.st_setsrid(extensions.st_makepoint(73.8567, 18.5204), 4326)::extensions.geography,
   'East gate', 40, 'visible', '00000000-0000-0000-0000-0000000000f2', repeat('e', 64));
set local role service_role;
select is(
  (join_activity('00000000-0000-0000-0000-000000000003',
    'aaaa0000-0000-0000-0000-000000000002', 'join:u3', null, 30, null)
   ->> 'participant_count'),
  '1',
  'someone joins the second activity'
);
reset role;
update profiles set status = 'suspended'
where id in ('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000004');
set local role service_role;

select is(
  (leave_activity('00000000-0000-0000-0000-000000000003',
    'aaaa0000-0000-0000-0000-000000000002', 'join:u3', null, 30, null)
   ->> 'participant_count'),
  '0',
  'a suspended participant may still leave (§17 O33 carve-out)'
);

select ok(
  (cancel_activity('00000000-0000-0000-0000-000000000004',
    'aaaa0000-0000-0000-0000-000000000002', 'cancel:u4', null, null, 5)
   ->> 'cancelled_at') is not null,
  'and a suspended organiser may still cancel, so nobody is left expecting an event'
);

reset role;
update profiles set status = 'active'
where id in ('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000004');
select * from finish();
rollback;
