begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, created_at)
values ('e2000000-0000-4000-8000-000000000001', now() - interval '30 days');
insert into profiles (id, display_name)
values ('e2000000-0000-4000-8000-000000000001', 'Totals author');

insert into acts (id, author_id, title, story, category, occurred_on, location_coarse,
                  status, text_checked, idempotency_key, request_hash)
values ('e2000000-0000-4000-8000-0000000000f1',
        'e2000000-0000-4000-8000-000000000001', 'A morning at the river',
        'We filled eleven sacks along the bank before the rain came in at noon.',
        'environment', current_date - 1,
        extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
        'pending', true, gen_random_uuid(), repeat('c', 64));
insert into act_metrics (act_id, metric, value) values
  ('e2000000-0000-4000-8000-0000000000f1', 'waste_kg', 12.5),
  ('e2000000-0000-4000-8000-0000000000f1', 'trees_planted', 3);

select is_empty(
  $$ select r.rolname from (values ('anon'::name), ('authenticated'::name),
                                   ('service_role'::name)) as r (rolname)
     where has_table_privilege(r.rolname, 'impact_totals', 'insert, update, delete') $$,
  'no role may write a total, which is why the trigger is security definer (§9.2)'
);

select ok(
  not has_function_privilege('anon', 'update_impact_totals()', 'execute')
  and not has_function_privilege('authenticated', 'update_impact_totals()', 'execute')
  and not has_function_privilege('service_role', 'update_impact_totals()', 'execute'),
  'and nobody may call it directly'
);

select is(
  (select count(*)::int from impact_totals
   where user_id = 'e2000000-0000-4000-8000-000000000001'),
  0,
  'an author with no published Act has no totals row yet'
);

-- §6.1: the ledger rows land, and these triggers move the totals in the same
-- transaction rather than anything being recomputed on read (§5.4).
update acts set status = 'visible', published_at = now()
where id = 'e2000000-0000-4000-8000-0000000000f1';

select results_eq(
  $$ select points, acts_count, trees_planted, waste_kg from impact_totals
     where user_id = 'e2000000-0000-4000-8000-000000000001' $$,
  $$ values (10 + 25 + 15, 1, 3, 12.5::numeric(12,2)) $$,
  'publishing creates the row and fills it from the ledger'
);

select is(
  (select volunteer_hours from impact_totals
   where user_id = 'e2000000-0000-4000-8000-000000000001'),
  0::numeric(12,2),
  'and a metric the Act never claimed stays at zero'
);

-- §6.4: "Reversible: removing fraudulent content subtracts exactly what it added."
-- §6.2 has staff removal delete the ledger rows; the totals follow.
delete from impact_entries where act_id = 'e2000000-0000-4000-8000-0000000000f1'
  and kind = 'metric' and metric = 'trees_planted';

select results_eq(
  $$ select points, acts_count, trees_planted, waste_kg from impact_totals
     where user_id = 'e2000000-0000-4000-8000-000000000001' $$,
  $$ values (10 + 25, 1, 0, 12.5::numeric(12,2)) $$,
  'deleting one ledger row subtracts exactly what that row added'
);

delete from impact_entries where act_id = 'e2000000-0000-4000-8000-0000000000f1';

select results_eq(
  $$ select points, acts_count, trees_planted, waste_kg from impact_totals
     where user_id = 'e2000000-0000-4000-8000-000000000001' $$,
  $$ values (0, 0, 0, 0::numeric(12,2)) $$,
  'and removing the Act''s whole ledger leaves the author back at zero (§6.2)'
);

-- §5.4: account deletion nulls `user_id` by the foreign key rather than deleting the
-- row, so campaign totals stay correct. A row with no author has no total to move.
insert into impact_entries (user_id, act_id, kind, points, location_coarse)
values (null, null, 'act_published', 10,
        extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography);

select is(
  (select points from impact_totals
   where user_id = 'e2000000-0000-4000-8000-000000000001'),
  0,
  'an orphaned ledger row moves nobody''s total'
);

-- The check constraints are the backstop: a reversal that subtracted more than was
-- added would raise here rather than leave a negative total on a public profile.
select throws_ok(
  $$ insert into impact_entries (user_id, act_id, kind, points, location_coarse)
     values ('e2000000-0000-4000-8000-000000000001', null, 'act_published', -1,
             extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography) $$,
  '23514',
  null,
  'and the ledger itself refuses a negative award (§5.2.1)'
);

select * from finish();
rollback;
