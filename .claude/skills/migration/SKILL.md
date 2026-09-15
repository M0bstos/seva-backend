---
name: migration
description: Write one SEVA table migration — the table with its grants, RLS policies, indexes and pgTAP denial tests in a single file. Use when adding or changing a table, enum or Postgres function.
---

# Writing a SEVA migration

Read the relevant part of `docs/SEVA-backend-v1.md` §5 and §9 first and cite it as `§n` in the commit message. If the spec does not cover what you need, stop and ask — do not invent the requirement.

## Order of work

1. `supabase migration new <name>`. Never hand-name the file; never edit an applied one.
2. The table: columns, types, nullability, defaults and checks exactly as §5.2.1 gives them.
3. **Revoke first, then grant.** A new table in `public` arrives with grants nobody asked for, and `revoke all on table` leaves its identity sequence untouched:

   ```sql
   revoke all on table <t> from public, anon, authenticated, service_role;
   revoke all on sequence <t>_<column>_seq from public, anon, authenticated, service_role;
   ```

   Then grant exactly what §5.2 says, per role, and nothing more. `anon` gets nothing. Remember `service_role` for everything an Edge Function reaches through a `security invoker` function, and `usage` on the sequence for any role that has to insert.
4. `alter table ... enable row level security`.
5. One policy per operation, each with an explicit `to` role and `(select auth.uid())`.
6. The indexes from §5.5 that touch this table.
7. Tests in `supabase/tests/rls/<table>.test.sql`: denial tests one per policy, one allow test, and one proving `service_role` can do what this table's functions need.
8. `deno task db:test`. Green, or it does not exist.

Steps 2–6 go in the same migration file. That is what makes a table reviewable and revertable as one unit.

## Easy to get wrong

- `(select auth.uid())`, not `auth.uid()` — the bare form re-evaluates once per row, and Supabase's advisor flags it.
- Revoking `execute` from `anon, authenticated` without also revoking from `public` does nothing. Privileges granted to `PUBLIC` still reach both roles, and `has_function_privilege` — what the gates check — sees them. Always `revoke ... from public, anon, authenticated`. Then check whether `service_role` needed that privilege and grant it back explicitly.
- PostGIS lives in `extensions`, so the type is `extensions.geography(point, 4326)`, and any `security definer` function must write `extensions.st_dwithin`, never `st_dwithin`, because `search_path` is pinned to `''`.
- No polymorphic `subject_type`/`subject_id`. One nullable foreign key per target plus a `num_nonnulls()` check (§5.1).
- Destructive changes take two releases: add the new structure and move the data, then remove the old one later.
- Lowercase SQL keywords, snake_case identifiers.

## Denial tests and allow tests, always both

Each policy needs a test proving the *wrong* user gets nothing: set the role and the claims, run the query, assert empty. A policy whose only test is a happy path has not been tested.

But denial-only is the other half of the same trap — **a policy that denies everyone passes every denial test**. So each policy also gets one allow test, run as the role that is supposed to succeed, and each table gets one test that `service_role` can do what its functions need. Without those, a forgotten grant first appears as `permission denied` in an API test, a long way from the migration that caused it.

## Done means

`deno task db:test` green, one migration file, its denial tests alongside, and a lowercase one-line commit citing the §.
