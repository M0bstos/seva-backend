begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

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
       )
       -- **One exception, and §11.6 compels it.** "`private.retained_registrations` is the one
       -- place a phone number exists outside Supabase Auth", and rule 3(1)(h) requires the
       -- phone and the email to survive the erasure — so `delete_account` has to read both,
       -- from a frame that is definer because `service_role` holds nothing on that table. The
       -- values are destroyed by the same statement that deletes the Auth row, so there is no
       -- later moment to copy them from.
       --
       -- Named rather than pattern-excused, and bounded by the two assertions after this one:
       -- the exception list is exactly one function, and that function's answer carries
       -- neither value. The lint stays exhaustive over everything else.
       --
       -- **One identity and not a name.** This was `not like 'delete_account(%'`, which excused
       -- every overload: reproduced in review, `delete_account(uuid, boolean)` returning
       -- `to_jsonb(u)` from `auth.users` passed all three of these assertions while handing back
       -- any user's phone, email and `encrypted_password`. Postgres identifies a function by its
       -- argument types, so the exception has to as well.
       and d.fn <> 'delete_account(uuid)' $$,
  'no definer body in public reads the auth schema for anything §9.8 protects'
);

-- The exception cannot grow quietly. A second definer body reading `auth` for a §9.8 value
-- would have to be added to the list above, which is an edit a reviewer sees.
select results_eq(
  $$ with definer as (
       select p.oid::regprocedure::text as fn,
              regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g') as body
       from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.prosecdef
     )
     select count(*)::int from definer d
     where d.body ~ 'auth\.'
       -- **The same three branches as the lint above, not just the first.** Narrower here meant
       -- the bound could not catch what the exception let through: a `to_jsonb(u)` body spells
       -- none of these words, so the overload above was invisible to both assertions at once.
       and (
         d.body ~* '(phone|email|password|token|meta_data|identity_data)'
         or d.body ~* 'to_jsonb[[:space:]]*\([[:space:]]*[a-z_]+[[:space:]]*\)'
         or d.body ~* 'row_to_json'
       ) $$,
  $$ values (1) $$,
  'and exactly one definer body reads the auth schema that way at all (§11.6)'
);

-- §11.6 says "return **or log**", and the assertion below can only see what is returned. A
-- `raise notice '... %', v_registration.phone` would pass every other assertion in this file, so
-- the one exception carries no `raise` of any kind. Text, because there is nothing to execute.
select ok(
  pg_get_functiondef('delete_account(uuid)'::regprocedure) !~* '\mraise\M',
  'and the one exception raises nothing, which is the half a return assertion cannot see (§11.6)'
);

-- §11.6's own constraint on that frame: "neither function may return or log `phone` or
-- `email`". Asserted by running it, because a text lint cannot see what a body returns.
insert into auth.users (id, created_at, phone, email)
values ('77777777-7777-7777-7777-777777777777', now() - interval '30 days',
        '919000000001', 'erasure@seva.test');
insert into profiles (id, display_name)
values ('77777777-7777-7777-7777-777777777777', 'leaving');
insert into profile_private (user_id, date_of_birth, terms_version, privacy_version)
values ('77777777-7777-7777-7777-777777777777', '1995-04-04', '2026-10-01', '2026-10-01');
insert into account_deletions (user_id) values ('77777777-7777-7777-7777-777777777777');

create temp table erased as
  select delete_account('77777777-7777-7777-7777-777777777777') as answer;

select ok(
  (select answer::text not like '%919000000001%'
     and answer::text not like '%erasure@seva.test%'
   from erased),
  'the deletion function returns neither the phone number nor the email (§11.6, §9.8)'
);

-- And the copy §11.6 requires did happen, so the assertion above is about a frame that
-- really read them rather than one that skipped the work.
select ok(
  (select phone = '919000000001' and email = 'erasure@seva.test'
   from private.retained_registrations
   where user_id = '77777777-7777-7777-7777-777777777777'),
  'while the registration details are retained, which rule 3(1)(h) requires (§11.6)'
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
