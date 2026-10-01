begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

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

-- With a grant option, anyone holding the secret key could widen this read to
-- authenticated permanently. Only the table-level form is reachable: Postgres refuses
-- a column-level one here with "grant options cannot be granted back to your own
-- grantor", because postgres holds its own r* by grant from supabase_auth_admin. So
-- this reads relacl, where the reachable state would actually land.
select is_empty(
  $$ select 'auth.users' from pg_class
     where oid = 'auth.users'::regclass
       and array_to_string(relacl, ',') like '%service_role=r*%' $$,
  'and service_role cannot pass the read on: it holds no grant option'
);

-- `O16` chose the grant over a definer helper to keep three reads "out of a definer
-- body CI cannot inspect". One of the three moved into one anyway: §6.1's 100-point
-- cap is awarded by a trigger, and §9.2 gives the ledger no write path at all, so
-- there is nowhere else for the award to happen. That frame runs as the function's
-- owner, which holds the whole `auth` schema — measured, `select phone, email,
-- encrypted_password from auth.users` succeeds there and fails as `service_role`.
--
-- **This is a text lint, not a boundary.** The privilege boundary is genuinely gone
-- inside that frame; nothing below restores it. What this catches is an accidental
-- `select u.phone` in a definer body, and it is worth having for that alone. What it
-- cannot catch, each one tried: a whole-row read (`to_jsonb(u)`) then a key built by
-- concatenation, and a column Supabase adds later that no pattern here names. A
-- `service_role`-owned definer would have been the real boundary, but ownership needs
-- `create` on the schema and granting that opens far more than it closes — measured.
--
-- Over **every** definer function in `public` rather than one by name, because the
-- next one is the one nobody reviewed. Comments are stripped first: a body saying
-- "never log the author's email here (§9.8)" is better code, and a check that failed
-- on it is a check someone would weaken.
select is_empty(
  $$ with definer as (
       select p.oid::regprocedure::text as fn,
              regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g') as body
       from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.prosecdef
     )
     select d.fn from definer d
     where d.body ~ 'auth\.'
       and (
         d.body ~* '(phone|email|password|token|meta_data|identity_data)'
         or d.body ~* 'to_jsonb[[:space:]]*\([[:space:]]*[a-z_]+[[:space:]]*\)'
         or d.body ~* 'row_to_json'
       ) $$,
  'no definer body in public reads the auth schema for anything §9.8 protects'
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
