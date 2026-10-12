begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

insert into auth.users (id) values
  ('88888888-8888-8888-8888-888888888888'),
  ('99999999-9999-9999-9999-999999999999'),
  ('11111111-1111-1111-1111-111111111111');
insert into profiles (id, display_name) values
  ('88888888-8888-8888-8888-888888888888', 'admin'),
  ('99999999-9999-9999-9999-999999999999', 'moderator'),
  ('11111111-1111-1111-1111-111111111111', 'ordinary person');
insert into staff (user_id, role) values
  ('88888888-8888-8888-8888-888888888888', 'admin'),
  ('99999999-9999-9999-9999-999999999999', 'moderator');

-- A campaign that already has progress, which is what the §17.1 guard turns on. The
-- progress is put there the way §6.1 does — through the ledger — so the trigger that
-- maintains it is the one under test alongside the guard.
insert into campaigns (id, title, description, goal_metric, goal_value,
                       starts_on, ends_on, status)
values ('cccc0000-0000-0000-0000-000000000001', 'Clean the lake',
        'Volunteers clearing plastic from the lake shore every weekend this season.',
        'waste_kg', 5000, '2026-10-01', '2026-12-31', 'active'),
       ('cccc0000-0000-0000-0000-000000000002', 'Not started yet',
        'A campaign created this morning that nobody has contributed anything to.',
        'waste_kg', 100, '2026-11-01', '2026-12-31', 'draft');

insert into impact_entries (user_id, kind, metric, value, points, campaign_id,
                            location_coarse)
values ('11111111-1111-1111-1111-111111111111', 'metric', 'waste_kg', 600, 1200,
        'cccc0000-0000-0000-0000-000000000001',
        extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography);

select is(
  (select progress_value from campaigns where id = 'cccc0000-0000-0000-0000-000000000001'),
  600::numeric(12, 2),
  'the fixture has 600 kg of progress against its goal (§6.1)'
);

set local role authenticated;

set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","aal":"aal2"}';
select is(
  admin_upsert_campaign(null, 'Plant trees', 'A new campaign a moderator should not create.',
    'trees_planted', 500, '2026-11-01', '2027-01-31', 'draft',
    'starting a campaign') ->> 'error',
  'FORBIDDEN',
  'a moderator cannot manage campaigns, which §10.1 gives an admin'
);

set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal2"}';

select is(
  admin_upsert_campaign(null, 'Plant trees', 'A description long enough for §5.2.1.',
    'trees_planted', 0, '2026-11-01', '2027-01-31', 'draft',
    'goal of nothing') ->> 'field',
  'goal_value',
  '§5.2.1 wants a goal above zero, named rather than raised'
);

select is(
  admin_upsert_campaign(null, 'Plant trees', 'A description long enough for §5.2.1.',
    'trees_planted', 500, '2027-01-31', '2026-11-01', 'draft',
    'ending before it starts') ->> 'field',
  'ends_on',
  'and an end before its start, which §5.2.1 also checks'
);

select is(
  admin_upsert_campaign(null, 'Four', 'A description long enough for §5.2.1 to accept it.',
    'trees_planted', 500, '2026-11-01', '2027-01-31', 'draft',
    'title under five characters') ->> 'field',
  'title',
  'and a title under §5.2.1''s five characters, caught as the backstop (§9.8)'
);

select is(
  admin_upsert_campaign('cccc0000-0000-0000-0000-0000000000ff', 'Plant trees',
    'A description long enough for §5.2.1 to accept it here.',
    'trees_planted', 500, '2026-11-01', '2027-01-31', 'draft',
    'no such campaign') ->> 'error',
  'NOT_FOUND',
  'a campaign that is not there is NOT_FOUND (§7.4)'
);

-- §17.1's latent defect, now guarded: §6.2's reversal subtracts against the campaign's
-- *current* goal, so a changed goal makes a staff removal raise 23514 and fail.
select is(
  admin_upsert_campaign('cccc0000-0000-0000-0000-000000000001', 'Clean the lake',
    'Volunteers clearing plastic from the lake shore every weekend this season.',
    'trees_planted', 5000, '2026-10-01', '2026-12-31', 'active',
    'switching the goal to trees') ->> 'field',
  'goal_metric',
  'the goal cannot change once progress exists, or §6.2''s removal would fail (§17.1)'
);

reset role;
select is(
  (select goal_metric::text from campaigns where id = 'cccc0000-0000-0000-0000-000000000001'),
  'waste_kg',
  'and the goal is left as it was'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal2"}';

-- The guard is about progress, not about editing: a campaign at zero can still be re-aimed.
select is(
  admin_upsert_campaign('cccc0000-0000-0000-0000-000000000002', 'Not started yet',
    'A campaign created this morning that nobody has contributed anything to.',
    'trees_planted', 100, '2026-11-01', '2026-12-31', 'draft',
    'correcting the goal on the day it was made') ->> 'status',
  'draft',
  'a campaign with no progress can be re-aimed, which a typo on day one needs'
);

-- From the table, for the reason review gave: the answer echoes `p_status`, so this passed with
-- `goal_metric = p_goal_metric` deleted from the update and the campaign still reading `waste_kg`.
-- The re-aim is the whole claim of the assertion above, and nothing observed it.
reset role;
select is(
  (select goal_metric::text from campaigns
   where id = 'cccc0000-0000-0000-0000-000000000002'),
  'trees_planted',
  'and the goal metric really changed, which is what being re-aimed means (§6.2)'
);
set local role authenticated;
set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal2"}';

-- Everything else about a campaign with progress stays editable.
select is(
  admin_upsert_campaign('cccc0000-0000-0000-0000-000000000001', 'Clean the lake, phase two',
    'Volunteers clearing plastic from the lake shore every weekend this season.',
    'waste_kg', 8000, '2026-10-01', '2027-01-31', 'active',
    'extending the drive and raising the target') ->> 'campaign_id',
  'cccc0000-0000-0000-0000-000000000001',
  'the title, the target and the dates stay editable with progress on the board'
);

reset role;
select is(
  (select progress_value from campaigns where id = 'cccc0000-0000-0000-0000-000000000001'),
  600::numeric(12, 2),
  'and no staff call ever moves progress, which §9.2 gives no write path at all'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal2"}';

create temp table made as
  select admin_upsert_campaign(null, 'Plant trees',
    'A description long enough for §5.2.1 to accept it as a real campaign.',
    'trees_planted', 500, '2026-11-01', '2027-01-31', 'draft',
    'new campaign for the winter planting season') as answer;

select isnt(
  (select answer ->> 'campaign_id' from made),
  null,
  'an admin creates a campaign and is given its id (§10.2)'
);

reset role;
select is(
  (select progress_value from campaigns
   where id = (select answer ->> 'campaign_id' from made)::uuid),
  0::numeric(12, 2),
  'which starts at no progress, because §6.1 builds progress from the ledger'
);

select results_eq(
  $$ select action, subject_type, before ->> 'goal_metric', after ->> 'goal_metric'
     from admin_audit_log where reason like 'new campaign for the winter%' $$,
  $$ values ('upsert_campaign', 'campaign', null, 'trees_planted') $$,
  'and a create has a null before, where an edit carries the old values (§10)'
);

select * from finish();
rollback;
