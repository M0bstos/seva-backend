begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

insert into auth.users (id) values ('d1000000-0000-4000-8000-000000000001');
insert into profiles (id, display_name)
values ('d1000000-0000-4000-8000-000000000001', 'Status probe');
insert into acts (id, author_id, title, story, category, occurred_on, location_coarse,
                  status, text_checked, created_at, status_changed_at,
                  idempotency_key, request_hash)
values ('d1000000-0000-4000-8000-0000000000aa',
        'd1000000-0000-4000-8000-000000000001', 'A morning at the river',
        'We filled eleven sacks along the bank before the rain came in at noon.',
        'environment', current_date,
        extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
        'visible', true, now() - interval '3 days', now() - interval '3 days',
        gen_random_uuid(), repeat('a', 64));

-- No role may write the column, so nothing can antedate a hold to duck §10.4's clock.
select is_empty(
  $$ select r.rolname from (values ('anon'::name), ('authenticated'::name),
                                   ('service_role'::name)) as r (rolname)
     where has_column_privilege(r.rolname, 'public.acts', 'status_changed_at', 'update') $$,
  'no role holds update on status_changed_at, on acts'
);

select is_empty(
  $$ select t.relname from (values ('public.activities'::regclass),
                                   ('public.media'::regclass)) as t (relname)
     cross join (values ('anon'::name), ('authenticated'::name),
                        ('service_role'::name)) as r (rolname)
     where has_column_privilege(r.rolname, t.relname, 'status_changed_at', 'update') $$,
  'nor on activities or media'
);

-- The trigger writes it anyway: a `before update` trigger assigning to NEW runs after
-- the statement's column privileges are checked.
set local role service_role;

update acts set status = 'pending', text_checked = false
where id = 'd1000000-0000-4000-8000-0000000000aa';

select ok(
  (select status_changed_at from acts where id = 'd1000000-0000-4000-8000-0000000000aa')
    > now() - interval '1 minute',
  'a status change stamps the column even though the writer holds no grant on it'
);

-- §8.3's visible → pending is what made this necessary: `created_at` stayed three
-- days old, so the health check read the edit as screening stuck for three days.
select ok(
  (select created_at from acts where id = 'd1000000-0000-4000-8000-0000000000aa')
    < now() - interval '2 days',
  'while created_at is untouched, which is the column that was measuring the wrong thing'
);

-- The owner is the one role no grant can stop, and §9.1 makes it the owner of every
-- `security definer` function too — so week 4-5's staff hold functions run as it. The
-- trigger fires on every update and puts the old value back, which is what makes the
-- column unwritable rather than merely ungranted.
reset role;
update acts set status_changed_at = now() - interval '30 hours'
where id = 'd1000000-0000-4000-8000-0000000000aa';

select ok(
  (select status_changed_at from acts where id = 'd1000000-0000-4000-8000-0000000000aa')
    > now() - interval '1 minute',
  'even the table owner cannot forward- or back-date the clock §10.4 measures'
);

-- Which means a test that needs an aged clock has to say so out loud.
alter table acts disable trigger acts_stamp_status_changed_at;
update acts set status_changed_at = now() - interval '30 hours'
where id = 'd1000000-0000-4000-8000-0000000000aa';
alter table acts enable trigger acts_stamp_status_changed_at;
set local role service_role;

update acts set title = 'A morning at the riverbank'
where id = 'd1000000-0000-4000-8000-0000000000aa';

select ok(
  (select status_changed_at from acts where id = 'd1000000-0000-4000-8000-0000000000aa')
    < now() - interval '29 hours',
  'a write that leaves the status alone does not restart the clock'
);

update acts set status = 'pending' where id = 'd1000000-0000-4000-8000-0000000000aa';

select ok(
  (select status_changed_at from acts where id = 'd1000000-0000-4000-8000-0000000000aa')
    < now() - interval '29 hours',
  'and neither does setting the status to what it already was'
);

update acts set status = 'held' where id = 'd1000000-0000-4000-8000-0000000000aa';

select ok(
  (select status_changed_at from acts where id = 'd1000000-0000-4000-8000-0000000000aa')
    > now() - interval '1 minute',
  'only a real change does, which is what §10.4''s held-at-20-hours alarm counts from'
);

reset role;

-- §10.4's held arm and §12.5's `degraded` rest on all three triggers equally, and a
-- mistyped `create trigger` on either of the other two would leave that table's alarm
-- silent with everything above still green.
insert into activities (id, organiser_id, title, description, category, starts_at,
                        ends_at, location, location_label, capacity, status,
                        idempotency_key, request_hash)
values ('d1000000-0000-4000-8000-0000000000bb',
        'd1000000-0000-4000-8000-000000000001', 'Riverbank clean-up',
        'Bring gloves. We meet by the bridge and work upstream until noon.',
        'environment', now() + interval '2 days', now() + interval '2 days' + interval '4 hours',
        extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
        'Under the Z bridge', 40, 'pending', gen_random_uuid(), repeat('c', 64));
insert into media (id, owner_id, purpose, upload_path, status)
values ('d1000000-0000-4000-8000-0000000000cc',
        'd1000000-0000-4000-8000-000000000001', 'act',
        'uploads/d1000000-0000-4000-8000-000000000001/cc.jpg', 'processing');

alter table activities disable trigger activities_stamp_status_changed_at;
alter table media disable trigger media_stamp_status_changed_at;
update activities set status_changed_at = now() - interval '30 hours'
where id = 'd1000000-0000-4000-8000-0000000000bb';
update media set status_changed_at = now() - interval '30 hours'
where id = 'd1000000-0000-4000-8000-0000000000cc';
alter table activities enable trigger activities_stamp_status_changed_at;
alter table media enable trigger media_stamp_status_changed_at;

set local role service_role;
update activities set status = 'held' where id = 'd1000000-0000-4000-8000-0000000000bb';
update media set status = 'held' where id = 'd1000000-0000-4000-8000-0000000000cc';

select ok(
  (select status_changed_at from activities
   where id = 'd1000000-0000-4000-8000-0000000000bb') > now() - interval '1 minute',
  'the activities trigger stamps a hold too'
);

select ok(
  (select status_changed_at from media
   where id = 'd1000000-0000-4000-8000-0000000000cc') > now() - interval '1 minute',
  'and so does the media one'
);

reset role;
select * from finish();
rollback;
