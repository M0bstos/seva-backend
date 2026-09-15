---
name: migration
description: Write one SEVA table migration — the table with its grants, RLS policies, indexes and pgTAP denial tests in a single file. Use when adding or changing a table, enum or Postgres function.
---

# Writing a SEVA migration

Read the relevant part of `docs/SEVA-backend-v1.md` §5 and §9 first and cite it as `§n` in the commit message. If the spec does not cover what you need, stop and ask — do not invent the requirement.

## Order of work

1. `supabase migration new <name>`. Never hand-name the file; never edit an applied one.
2. The table: columns, types, nullability, defaults and checks exactly as §5.2.1 gives them.
3. Grants, explicitly, per role. `anon` gets nothing.
4. `alter table ... enable row level security`.
5. One policy per operation, each with an explicit `to` role and `(select auth.uid())`.
6. The indexes from §5.5 that touch this table.
7. Denial tests in `supabase/tests/rls/<table>.test.sql`, one per policy.
8. `deno task db:test`. Green, or it does not exist.

Steps 2–6 go in the same migration file. That is what makes a table reviewable and revertable as one unit.

## Easy to get wrong

- `(select auth.uid())`, not `auth.uid()` — the bare form re-evaluates once per row, and Supabase's advisor flags it.
- Revoking `execute` from `anon, authenticated` without also revoking from `public` does nothing. Privileges granted to `PUBLIC` still reach both roles, and `has_function_privilege` — what the gates check — sees them. Always `revoke ... from public, anon, authenticated`. Then check whether `service_role` needed that privilege and grant it back explicitly.
- PostGIS lives in `extensions`, so the type is `extensions.geography(point, 4326)`, and any `security definer` function must write `extensions.st_dwithin`, never `st_dwithin`, because `search_path` is pinned to `''`.
- No polymorphic `subject_type`/`subject_id`. One nullable foreign key per target plus a `num_nonnulls()` check (§5.1).
- Destructive changes take two releases: add the new structure and move the data, then remove the old one later.
- Lowercase SQL keywords, snake_case identifiers.

## A denial test is not an access test

Each policy needs a test proving the *wrong* user gets nothing — not merely that the right one gets a row. Set the role and the claims, run the query, assert empty. A policy whose only test is a happy path has not been tested.

## Done means

`deno task db:test` green, one migration file, its denial tests alongside, and a lowercase one-line commit citing the §.
