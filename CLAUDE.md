# SEVA backend

Backend for SEVA v1, a social-impact platform built for an Indian government program. Supabase and AWS, both in Mumbai (`ap-south-1`). No application servers. The client app lives in a separate repo.

## Source of truth

- `docs/SEVA-backend-v1.md` is the specification. It is local only and gitignored. Read the relevant section before changing anything, and cite it as `§n`.
- The decision register (§2.3, D1–D16) is settled. Don't propose alternatives unless asked.
- If a task conflicts with the spec, or the spec doesn't cover it, stop and ask. Don't invent requirements.
- If `docs/` is missing, ask for the spec instead of working from memory.

## Stack

- Postgres 17 with PostGIS, Supabase Auth, Data API (PostgREST), Storage, Edge Functions (Deno 2, TypeScript), Queues (pgmq), Cron.
- AWS: Rekognition, Bedrock Guardrails, SES, End User Messaging SMS, S3, CloudWatch.
- Allowed dependencies: `npm:@supabase/supabase-js`, `npm:hono`, the `npm:@aws-sdk/client-*` packages for the AWS services above, and `jsr:@std/*`. Any other dependency or service needs the four checks in §3.3 and approval first.
- Allowed tools outside the runtime: AWS CLI v2 and cfn-lint, both pinned. AWS infrastructure is CloudFormation YAML (§13.3); no Terraform, OpenTofu or CDK.

## Layout

```text
.githooks/          commit-msg and pre-commit checks
.github/workflows/  CI: database tests and function checks
admin/appsmith/     exported admin app
docs/               local only: the specification
infra/aws/          CloudFormation YAML, one stack per file (§13.3)
reference/          api.md, openapi-functions.yaml, runbook.md (handover docs)
supabase/
  config.toml       local project settings
  seed.sql          synthetic local data
  migrations/       hand-written SQL migrations, including bucket creation
  functions/        Edge Functions; shared code in _shared/
  tests/            pgTAP: security/ gates, rls/, rpc/, points/
tests/              api/ end-to-end, languages/ moderation samples, load/ k6
```

Create Edge Function folders with `supabase functions new <name>` only when building them. The CLI treats every folder in `supabase/functions/` as a deployable function. Planned functions: `acts`, `activities`, `uploads`, `reports`, `account`, `discover`, `feed`, `sms-hook`, `moderation-worker`, `message-worker`, `ops-worker`.

## Commands

```bash
supabase start       # local stack (needs Docker)
deno task check      # format check, lint, type-check functions
deno task test       # Edge Function tests
deno task db:test    # reset local db, lint it, run pgTAP including security gates
deno task test:api   # end-to-end API tests, needs a running stack
```

## Code rules

- **Build exactly what the spec asks for.** No extra features, fields, endpoints, options or abstractions.
- **No commented-out code.** Delete it; git keeps the history.
- **Comment only when the reason isn't obvious**, in one or two short lines. No docblocks that restate a signature, no banners, no TODOs.
- **Constants live beside the file that uses them:** `limits.ts` gets `limits.constants.ts`. No catch-all constants file. A value several files need belongs in the constants file of the module that owns the concept. No magic numbers or strings inline.
- **Write the least code that does the job.** No service or repository layers, no wrappers around a single call, no helpers used once, nothing speculative. Extract shared code only when a third copy appears.
- **Keep it debuggable without AI.** Plain control flow, early returns, descriptive names, short functions. No clever one-liners or metaprogramming.
- **Design for performance.** Indexed queries, no N+1, one database round trip per request where possible, nothing recomputed on hot paths.
- **Verify instead of experimenting.** Check current official docs (Supabase, Deno, PostgREST, pgTAP, AWS SDK) before using an API. When something fails, find the cause before changing approach. Never cycle through variations to see what sticks.
- Pin every import: `npm:pkg@1.2.3`, `jsr:@std/pkg@1.2.3`. No bare specifiers, `esm.sh` or `deno.land/x`.
- No `any`, and no non-null assertions used to silence the type checker.

## Database rules

- Write migrations by hand with `supabase migration new <name>`. Don't use declarative schemas or `supabase db diff`: the diff misses column privileges and view `security_invoker`, which §9 depends on.
- A table's migration also holds its grants, RLS, policies and indexes. Never edit an applied migration. Destructive changes take two releases.
- `auto_expose_new_tables` is off. Grant every table explicitly, per role.
- RLS on every table. One policy per operation, each with an explicit `to` role, using `(select auth.uid())`.
- Functions are `security invoker` unless definer is required. Definer functions `set search_path = ''`, use schema-qualified names and check permissions first. Revoke `execute` from `public, anon, authenticated`; only `admin_*` functions are granted to `authenticated`. Mark functions `stable` or `immutable` when true.
- Views use `with (security_invoker = true)`. Extensions go in the `extensions` schema, with one exception: `pgmq` refuses any schema but its own, so queues live in `pgmq` (§5.1).
- Nothing in `private` or `pgmq` is ever granted to `anon` or `authenticated`. Gates 6 and 7 check this; gate 3 only sees `public`.
- Points, verification, counts, content status and `profiles.avatar_path` are never client-writable (§9.2). Avatars are set by the moderation worker.
- Never grant `anon` anything. Logged-out reads go through the `discover` function (§7.3), so gate 2 stays at zero rows.
- No polymorphic `subject_type`/`subject_id` pairs. One nullable foreign key per target plus a `num_nonnulls()` check (§5.1).
- v1 ships no views. If one is ever added it must be `with (security_invoker = true)` and must not be readable by `anon` (§9.1).
- Every policy ships with a pgTAP denial test in `supabase/tests/rls/`.
- Lowercase SQL keywords and snake_case identifiers.

## Edge Function rules

- Follow Supabase's Edge Functions guidelines: https://supabase.com/docs/guides/getting-started/ai-prompts/edge-functions
- One function per route group, routed with Hono. Handler order: verify the token with `supabase.auth.getClaims()`, validate input, check the kill switch and rate limit, call one Postgres function, then respond with the shared error shape (§7.1, codes in §7.4).
- Take the user ID from verified claims, never from the request body.
- Each function uses its own named secret key. Don't use `@supabase/server`; it's still in beta.
- Share code only through `_shared/` with relative imports. Functions never import each other.
- Never log request bodies, tokens, SMS codes, phone numbers, dates of birth, coordinates or email addresses.

## Checks

- Before every commit, run `deno task check` and the tests for what changed. Never commit on red.
- Never skip, disable or weaken a check or test to make it pass. Fix the cause. `// deno-lint-ignore` needs a one-line reason.
- When asked for a clean check, run every check, then remove unused code, exports, files and dependencies, and report what was removed.
- **Never run `supabase config push` against production while `[auth.sms.test_otp]` is in `config.toml`.** Those numbers accept a fixed code, so pushing them would let anyone sign in as them. They are local-only fixtures; production auth settings are changed in the dashboard (§9.3).

## Review before committing

The agent that writes the code is never the agent that approves it. Three read-only reviewers live in `.claude/agents/`.

- **Before every commit** that changes SQL, an Edge Function or a test, run `db-security` and `spec-conformance` on the diff. Each returns `PASS` or `BLOCK`. A `BLOCK` from either is fixed and re-reviewed before the commit happens.
- **Run `compliance`** as well when the change touches retention, reports, moderation, account deletion, logging, minors, or anything that calls AWS. It never blocks; surface its open items to the user, because most need a program or legal decision rather than a code change.
- Never skip a review because the change looks small, and never resolve a finding by weakening the check that produced it.

Three skills in `.claude/skills/` carry the procedures: `migration` for a table migration, `route` for an Edge Function route group, `clean-check` for a full sweep. Use them rather than reinventing the steps.

## Git

- One-line commit messages, lowercase, imperative, 72 characters at most, e.g. `add join_activity capacity lock`.
- No commit body, no `Co-Authored-By`, no trailers. `.githooks/commit-msg` rejects anything else.
- Never commit secrets, `.env` files or anything in `docs/`.
- Don't push, force-push, rewrite history or open pull requests unless asked.

### Commit granularity

Commit at every reviewable checkpoint, so a bad change is easy to find and safe to revert on its own. One commit is exactly one of these, never a mix:

- One migration: a table with its grants, RLS policies and indexes, plus its pgTAP denial tests.
- One Postgres function, plus its pgTAP test.
- One Edge Function route group, or one worker.
- One `_shared/` module.
- One infrastructure stack.
- One reference or configuration file.

Schema changes and Edge Function changes never share a commit. Every commit leaves the tests for what it touched green, and `deno task check` green whenever it changes a `.ts` file, so `git revert` on any single commit still gives a working tree. (`deno task check` errors with `No target files found` while the repo has no `.ts` files at all; that is expected until the first Edge Function exists.)
