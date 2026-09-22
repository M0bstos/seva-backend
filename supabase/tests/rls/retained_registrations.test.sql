begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into private.retained_registrations
  (user_id, phone, email, account_created_at)
values ('11111111-1111-1111-1111-111111111111', '+919999999999',
        'someone@example.com', now() - interval '400 days');

select ok(
  not has_table_privilege('authenticated', 'private.retained_registrations',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'private.retained_registrations',
    'SELECT, INSERT, UPDATE, REFERENCES')
  and not has_table_privilege('anon', 'private.retained_registrations',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN'),
  'no client reaches this table, which gates 6 and 7 also assert'
);

select ok(
  not has_table_privilege('service_role', 'private.retained_registrations',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('service_role', 'private.retained_registrations',
    'SELECT, INSERT, UPDATE, REFERENCES'),
  'and neither does the backend: it is written only inside definer functions, per 11.6'
);

select is_empty(
  $$ select policyname from pg_policies
     where schemaname = 'private' and tablename = 'retained_registrations' $$,
  'it carries no policy, because no role can reach it to be policed'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'private.retained_registrations'::regclass),
  'row level security is on regardless, so a later grant cannot open it by itself'
);

select results_eq(
  $$ select (purge_after::date - now()::date) from private.retained_registrations $$,
  $$ values (180) $$,
  'a row is kept for 180 days, which is what rule 3(1)(h) requires'
);

select * from finish();
rollback;
