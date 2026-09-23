begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

-- The gates in §9.7 cover public, private, pgmq and cron. This one grant lives in
-- auth, which no gate reaches, so its blast radius is measured here instead.

select ok(
  has_column_privilege('service_role', 'auth.users', 'id', 'select')
  and has_column_privilege('service_role', 'auth.users', 'created_at', 'select'),
  'an invoker function running as service_role can read an account and its age'
);

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'auth.users'::regclass and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'auth.users', a.attname, 'select')
       and a.attname not in ('id', 'created_at') $$,
  'and no other column of auth.users, so phone and email stay where §5.4 puts them'
);

select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'auth.users'::regclass and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('service_role', 'auth.users', a.attname,
                                'INSERT, UPDATE, REFERENCES') $$,
  'the grant is a read: service_role cannot write or reference any column'
);

select ok(
  not has_table_privilege('service_role', 'auth.users',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN'),
  'the grant is column-scoped, so no table-wide privilege comes with it'
);

select is_empty(
  $$ select r.rolname from (values ('anon'::name), ('authenticated'::name)) as r (rolname)
     where has_any_column_privilege(r.rolname, 'auth.users',
             'SELECT, INSERT, UPDATE, REFERENCES')
        or has_table_privilege(r.rolname, 'auth.users',
             'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN') $$,
  'and the client roles gain nothing: the Data API never exposes auth anyway'
);

-- grant all is eight privileges and a column grant is invisible to has_table_privilege;
-- the grant-option dimension is invisible to both. With it, anyone holding the secret
-- key could widen this read to authenticated permanently.
select is_empty(
  $$ select a.attname from pg_attribute a
     where a.attrelid = 'auth.users'::regclass and a.attnum > 0 and not a.attisdropped
       and array_to_string(a.attacl, ',') like '%service_role=r*%' $$,
  'and service_role cannot pass the read on: it holds no grant option'
);

set local role service_role;
select throws_ok(
  $$ select phone from auth.users $$,
  '42501',
  null,
  'reading a phone number through the secret key is refused, not empty'
);
reset role;

select * from finish();
rollback;
