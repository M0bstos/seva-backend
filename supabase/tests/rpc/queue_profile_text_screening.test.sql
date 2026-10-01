begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

insert into auth.users (id) values ('c1000000-0000-4000-8000-000000000001');

select is(
  (select prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'queue_profile_text_screening'),
  true,
  'security definer, because §7.2 has this trigger fire as authenticated (§5.1)'
);

-- What the definer frame actually rests on: `postgres` holds `usage` on `pgmq` and
-- `execute` on `pgmq.send`, and `authenticated` holds neither. If migrations ever ran
-- as a role without those, this trigger would fail on every profile write at runtime
-- rather than at migrate time.
select is(
  (select pg_get_userbyid(p.proowner) from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'queue_profile_text_screening'),
  'postgres',
  'owned by the role whose pgmq grants are what make the definer frame work'
);

-- A no-op PATCH must queue nothing: §7.2 puts profile edits on the Data API, which
-- §9.1 says carries no rate limit, and each job is a Bedrock call (§8.4).
select ok(
  (select count(*)::int from pg_trigger
   where tgrelid = 'profiles'::regclass and tgname = 'profiles_queue_text_screening_on_update'
     and tgqual is not null) = 1,
  'and the update trigger carries a when clause, so a no-op PATCH queues nothing'
);

select ok(
  not has_function_privilege('anon', 'queue_profile_text_screening()', 'execute')
  and not has_function_privilege('authenticated', 'queue_profile_text_screening()', 'execute')
  and not has_function_privilege('service_role', 'queue_profile_text_screening()', 'execute'),
  'and nobody may call it directly to queue a job about a profile they do not own'
);

-- §8.2 screens a profile on create. Onboarding runs as service_role.
set local role service_role;
insert into profiles (id, display_name)
values ('c1000000-0000-4000-8000-000000000001', 'Ravi from Kothrud');
reset role;

select is(
  (select count(*)::int from pgmq.q_moderation
   where message ->> 'id' = 'c1000000-0000-4000-8000-000000000001'),
  1,
  'creating a profile queues one text job (§8.2)'
);

select is(
  (select message ->> 'kind' from pgmq.q_moderation
   where message ->> 'id' = 'c1000000-0000-4000-8000-000000000001'),
  'profile_text',
  'and names the kind the worker branches on'
);

-- The assertion this file exists for. `authenticated` holds nothing in `pgmq`, so an
-- invoker trigger would raise `permission denied for schema pgmq` here and every
-- profile edit through §7.2's Data API would fail.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"c1000000-0000-4000-8000-000000000001","role":"authenticated"}';

select lives_ok(
  $$update profiles set bio = 'I clean up the riverbank on Sundays.'
    where id = 'c1000000-0000-4000-8000-000000000001'$$,
  'a person editing their own bio queues a job rather than being refused'
);

-- §9.2 and `O14`: the worker writes `text_hidden`, the person never does.
select throws_ok(
  $$update profiles set text_hidden = true
    where id = 'c1000000-0000-4000-8000-000000000001'$$,
  '42501',
  null,
  'and cannot clear or set the hide §8.2 puts on flagged text'
);

reset role;

select is(
  (select count(*)::int from pgmq.q_moderation
   where message ->> 'id' = 'c1000000-0000-4000-8000-000000000001'),
  2,
  'the edit queued a second job, so §8.3''s re-screen has something to act on'
);

-- The worker writing its own answer back must not queue another job about it, or the
-- queue never drains.
set local role service_role;
update profiles set text_hidden = true, avatar_path = 'media/c1/avatar.jpg'
where id = 'c1000000-0000-4000-8000-000000000001';
reset role;

select is(
  (select count(*)::int from pgmq.q_moderation
   where message ->> 'id' = 'c1000000-0000-4000-8000-000000000001'),
  2,
  'and the worker''s own write queues nothing, so the trigger cannot loop'
);

-- Measured before the when clause existed: three `set display_name = display_name`
-- no-ops as `authenticated` queued three Bedrock calls.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"c1000000-0000-4000-8000-000000000001","role":"authenticated"}';
update profiles set display_name = display_name, bio = bio
where id = 'c1000000-0000-4000-8000-000000000001';
update profiles set display_name = display_name
where id = 'c1000000-0000-4000-8000-000000000001';
reset role;

select is(
  (select count(*)::int from pgmq.q_moderation
   where message ->> 'id' = 'c1000000-0000-4000-8000-000000000001'),
  2,
  'a PATCH that changes neither value queues nothing, whatever it names in its SET'
);

select * from finish();
rollback;
