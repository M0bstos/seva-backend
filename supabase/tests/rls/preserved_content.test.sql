begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into private.preserved_content (source_kind, source_id, snapshot)
values ('act', '11111111-1111-1111-1111-111111111111', '{"title":"removed"}'::jsonb);

select ok(
  not has_table_privilege('authenticated', 'private.preserved_content',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'private.preserved_content',
    'SELECT, INSERT, UPDATE, REFERENCES')
  and not has_table_privilege('anon', 'private.preserved_content',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN'),
  'no client reaches this table, which gates 6 and 7 also assert'
);

select ok(
  not has_table_privilege('service_role', 'private.preserved_content',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('service_role', 'private.preserved_content',
    'SELECT, INSERT, UPDATE, REFERENCES'),
  'and neither does the backend: it is written only inside definer functions, per 11.6'
);

select is_empty(
  $$ select policyname from pg_policies
     where schemaname = 'private' and tablename = 'preserved_content' $$,
  'it carries no policy, because no role can reach it to be policed'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'private.preserved_content'::regclass),
  'row level security is on regardless, so a later grant cannot open it by itself'
);

select results_eq(
  $$ select (purge_after::date - now()::date) from private.preserved_content $$,
  $$ values (180) $$,
  'a row is kept for 180 days, which is what rule 3(1)(g) requires'
);

select * from finish();
rollback;
