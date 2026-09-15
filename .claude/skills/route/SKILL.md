---
name: route
description: Write one SEVA Edge Function route group — the Hono handler chain, the shared error shape and its Deno tests. Use when building or changing anything under supabase/functions/.
---

# Writing a SEVA route group

Read `docs/SEVA-backend-v1.md` §7 for the route's contract and §7.4 for its error codes. Cite the § in the commit message.

Create the folder with `supabase functions new <name>` only when you are actually building it — the CLI treats every folder under `supabase/functions/` as deployable.

## The handler order, every time

1. Verify the token with `supabase.auth.getClaims()`.
2. Validate the input.
3. Check the kill switch and the rate limit.
4. Call **one** Postgres function.
5. Respond with the shared error shape (§7.1).

Take the user ID from the verified claims, never from the request body. One database round trip per request.

No service layers, no repositories, no wrapper around a single call. Before extracting a helper, check whether a third caller exists yet; if not, inline it.

## Fixed details

- Pin every import: `npm:pkg@1.2.3`, `jsr:@std/pkg@1.2.3`. No bare specifiers, no `esm.sh`, no `deno.land/x`.
- Allowed dependencies only: `@supabase/supabase-js`, `hono`, the `@aws-sdk/client-*` packages for the services in §3.1, and `jsr:@std/*`. Anything else needs the four checks in §3.3 and approval first.
- Each function reads its own named secret key from `SUPABASE_SECRET_KEYS`, so any one key can be revoked alone (§9.5).
- `verify_jwt` per §7.3. Functions serving logged-out callers set it false and check in code.
- Shared code lives in `_shared/` with relative imports. Functions never import each other.
- Constants sit beside the file that uses them: `limits.ts` gets `limits.constants.ts`. No magic numbers inline.
- No `any`, no non-null assertions used to silence the type checker.

## Never log

Request bodies, tokens, SMS codes, phone numbers, dates of birth, coordinates, email addresses (§9.8).

## Done means

`deno task check` and `deno task test` green, an idempotency test if the route creates anything (§7.1.1), one error-shape test per code the route can return, and a lowercase one-line commit citing the §.
