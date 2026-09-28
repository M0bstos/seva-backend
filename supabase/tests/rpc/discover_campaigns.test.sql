begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

insert into campaigns
  (id, title, description, goal_metric, goal_value, progress_value, starts_on, ends_on,
   status, created_at)
values
  ('cccc0000-0000-0000-0000-000000000001', 'Clean the river',
   'A city-wide push to clear the riverbank before the monsoon.',
   'waste_kg', 10000, 2500, current_date - 10, current_date + 20, 'active',
   now() - interval '3 days'),
  ('cccc0000-0000-0000-0000-000000000002', 'Plant ten thousand',
   'Ten thousand trees across the district, one ward at a time.',
   'trees_planted', 10000, 400, current_date - 5, current_date + 40, 'active',
   now() - interval '2 days'),
  ('cccc0000-0000-0000-0000-000000000003', 'Shelter week',
   'A week of help for the district animal shelters.',
   'animals_helped', 500, 120, current_date - 1, current_date + 6, 'active',
   now() - interval '1 day'),
  ('cccc0000-0000-0000-0000-000000000004', 'Last winter',
   'A campaign that has already finished and is kept for the record.',
   'people_reached', 1000, 1000, current_date - 200, current_date - 100, 'ended',
   now() - interval '200 days'),
  ('cccc0000-0000-0000-0000-000000000005', 'Not announced yet',
   'A campaign staff are still writing, not yet announced to anyone.',
   'acts', 100, 0, current_date + 10, current_date + 40, 'draft',
   now() - interval '1 hour');

select ok(
  not has_function_privilege('anon',
    'discover_campaigns(uuid,text,int,text,int,int,int)', 'execute')
  and not has_function_privilege('authenticated',
    'discover_campaigns(uuid,text,int,text,int,int,int)', 'execute')
  and not has_function_privilege('anon',
    'discover_campaign(uuid,uuid,text,int,int,int)', 'execute')
  and not has_function_privilege('authenticated',
    'discover_campaign(uuid,uuid,text,int,int,int)', 'execute'),
  'no client reaches either campaign route past its rate limit (§9.1, §7.3)'
);

set local role service_role;

-- §17 O17: active only, and the function filters it rather than leaning on the policy.
select is(
  (select jsonb_agg(e->>'title')
   from jsonb_array_elements(
     discover_campaigns(null, null, 10, 'discover.campaigns:a', 60, null, null)
     -> 'campaigns') e),
  '["Shelter week", "Plant ten thousand", "Clean the river"]'::jsonb,
  'active campaigns only, newest first (§17 O17, §7.2)'
);

select is(
  (discover_campaigns(null, null, 10, 'discover.campaigns:b', 60, null, null)
   #>> '{campaigns,0,progress_value}'),
  '120.00',
  'each one carries the progress the trigger wrote (§5.4, §7.2)'
);

select is(
  (discover_campaigns(null, null, 10, 'discover.campaigns:c', 60, null, null)
   ->> 'next_cursor'),
  null::text,
  'a short page ends the walk (§7.1)'
);

select is(
  (select jsonb_agg(e->>'title')
   from jsonb_array_elements(
     discover_campaigns(null,
       (discover_campaigns(null, null, 2, 'discover.campaigns:d', 60, null, null)
        ->> 'next_cursor'), 2, 'discover.campaigns:e', 60, null, null)
     -> 'campaigns') e),
  '["Clean the river"]'::jsonb,
  'and the cursor carries on from where the first page ended (§7.1)'
);

select is(
  (discover_campaigns(null, 'not a cursor', 10, 'discover.campaigns:f', 60, null, null)
   ->> 'field'),
  'cursor',
  'a cursor that cannot be decoded is VALIDATION_FAILED, not INTERNAL (§7.4)'
);

-- §7.1 caps a page at 50 and the route names the field to a caller who asks for
-- more; the clamp behind it is what keeps the query bounded either way.
select is(
  jsonb_array_length(
    discover_campaigns(null, null, 0, 'discover.campaigns:g', 60, null, null)
    -> 'campaigns'),
  1,
  'a page length outside 1 to 50 is clamped rather than let through (§7.1)'
);

select is(
  (discover_campaign(null, 'cccc0000-0000-0000-0000-000000000001',
     'discover.campaign:a', 60, null, null) #>> '{campaign,title}'),
  'Clean the river',
  'one campaign is served for a shared link (§7.3)'
);

select is(
  (discover_campaign(null, 'cccc0000-0000-0000-0000-000000000004',
     'discover.campaign:b', 60, null, null) ->> 'error'),
  'NOT_FOUND',
  'an ended campaign is not readable anywhere (§17 O17, §7.4)'
);

select is(
  (discover_campaign(null, 'cccc0000-0000-0000-0000-000000000005',
     'discover.campaign:c', 60, null, null) ->> 'error'),
  'NOT_FOUND',
  'and neither is a draft'
);

select is(
  (select count(*)::int from (
     select discover_campaigns(null, null, 10, 'discover.campaigns:h', 1, null, null) as r
     from generate_series(1, 2)) s
   where s.r ->> 'error' = 'RATE_LIMITED'),
  1,
  'the limiter runs inside the same call (§12.2)'
);

select * from finish();
rollback;
