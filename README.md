# SEVA backend

Supabase and AWS backend for SEVA v1. The specification is `docs/SEVA-backend-v1.md`, which is kept locally and never committed.

## Setup

1. Install the Supabase CLI, Deno 2 and a Docker-compatible runtime.
2. Enable the repository hooks: `git config core.hooksPath .githooks`
3. Start the local stack: `supabase start`

## Checks

- `deno task check`: format, lint and type-check Edge Functions
- `deno task test`: Edge Function tests
- `deno task db:test`: reset the local database, lint it and run the pgTAP tests
