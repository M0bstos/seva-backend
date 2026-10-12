begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

insert into auth.users (id, created_at) values
  ('88888888-8888-8888-8888-888888888888', now() - interval '60 days'),
  ('99999999-9999-9999-9999-999999999999', now() - interval '60 days'),
  ('11111111-1111-1111-1111-111111111111', now() - interval '30 days');
insert into profiles (id, display_name) values
  ('88888888-8888-8888-8888-888888888888', 'admin'),
  ('99999999-9999-9999-9999-999999999999', 'moderator'),
  ('11111111-1111-1111-1111-111111111111', 'author');
insert into staff (user_id, role) values
  ('88888888-8888-8888-8888-888888888888', 'admin'),
  ('99999999-9999-9999-9999-999999999999', 'moderator');

-- An Act already published under the current rules, whose ledger row must not move when
-- the rule changes: §6.3 says "Changes apply to new entries only; history keeps the points
-- awarded at the time."
insert into acts (id, author_id, title, story, category, occurred_on, location_coarse,
                  status, text_checked, idempotency_key, request_hash)
values ('bbbb0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        'Cleared the shore', 'An act published before the scoring rule was changed by staff.',
        'environment', '2026-10-12',
        extensions.st_setsrid(extensions.st_makepoint(73.85, 18.52), 4326)::extensions.geography,
        'pending', true, '00000000-0000-0000-0000-0000000000b1', repeat('a', 64));
insert into act_metrics (act_id, metric, value)
values ('bbbb0000-0000-0000-0000-000000000001', 'waste_kg', 10);
update acts set status = 'visible' where id = 'bbbb0000-0000-0000-0000-000000000001';

select is(
  (select points from impact_totals where user_id = '11111111-1111-1111-1111-111111111111'),
  30,
  'the Act earned 10 for publishing and 20 for 10 kg at §6.3''s two per kg'
);

select ok(
  has_function_privilege('authenticated',
    'admin_set_points_rule(text,numeric,numeric,boolean,text)', 'execute')
  and not has_function_privilege('anon',
    'admin_set_points_rule(text,numeric,numeric,boolean,text)', 'execute')
  and not has_function_privilege('service_role',
    'admin_set_points_rule(text,numeric,numeric,boolean,text)', 'execute'),
  'staff reach it as authenticated; anon and the secret key cannot (§9.1, §10.3)'
);

set local role authenticated;

set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","aal":"aal2"}';
select is(
  admin_set_points_rule('waste_kg', 5, 200, true, 'raising the rate') ->> 'error',
  'FORBIDDEN',
  'a moderator cannot change scoring, which §10.1 gives an admin'
);

set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal1"}';
select is(
  admin_set_points_rule('waste_kg', 5, 200, true, 'without MFA') ->> 'error',
  'FORBIDDEN',
  'and neither can an admin who has not completed MFA (§9.3)'
);

set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal2"}';

select is(
  admin_set_points_rule('waste_kg', 5, 200, true, 'no') ->> 'field',
  'reason',
  'a reason under §5.2.1''s three characters names the field (§10)'
);

select is(
  admin_set_points_rule('waste_kg', -1, 200, true, 'a negative rate') ->> 'field',
  'points_per_unit',
  '§5.2.1 wants a rate at or above zero, named rather than raised'
);

-- §5.2.1 fixes the key space: act_published, activity_documented, or a metric name.
select is(
  admin_set_points_rule('litter_bags', 2, 200, true, 'a rule nothing reads') ->> 'field',
  'rule',
  'a rule outside §5.2.1''s key space is refused, not silently inserted'
);

select is(
  admin_set_points_rule('act_published', 15, null, true,
    'raising the publishing award for the beta') ->> 'rule',
  'act_published',
  'an admin changes a rule (§10.2, §6.3)'
);

-- §6.3's own words: "Changes apply to new entries only; history keeps the points awarded
-- at the time." Nothing in this function touches the ledger, which is the whole of it.
reset role;
select is(
  (select points from impact_totals where user_id = '11111111-1111-1111-1111-111111111111'),
  30,
  'and no ledger row or total moves, so history keeps what it earned (§6.3, §6.4)'
);

select is(
  (select points_per_unit from points_rules where rule = 'act_published'),
  15::numeric(8, 2),
  'while the rule itself is what the next award will read'
);

-- §17.1: `max_per_act` binds whether or not the rule is active, so switching a rule off
-- must not remove the only guard on `act_metrics`.
set local role authenticated;
set local request.jwt.claims = '{"sub":"88888888-8888-8888-8888-888888888888","aal":"aal2"}';
select is(
  admin_set_points_rule('trees_planted', 5, 200, false,
    'pausing tree scoring while the rate is reviewed') ->> 'active',
  'false',
  'a rule can be switched off (§6.3)'
);

reset role;
-- From the table. The assertion above reads the answer, which is `jsonb_build_object('active',
-- p_active)` — the argument handed straight back, so it passed with `active = excluded.active`
-- deleted from the upsert. Review reproduced that; this is the half that observes the write.
select is(
  (select active from points_rules where rule = 'trees_planted'),
  false,
  'and the row itself says so, which the answer alone cannot prove (§6.3)'
);
select is(
  (select max_per_act from points_rules where rule = 'trees_planted'),
  200::numeric(10, 2),
  'and keeps its maximum, which §17.1 says binds whether or not the rule is active'
);

select * from finish();
rollback;
