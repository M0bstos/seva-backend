# SEVA backend runbook

For whoever is on call. §12.6 of the specification is the source for the incident rows; this adds
the things only building it taught us, and the commands.

Written 12 October 2026, against a backend that has never been deployed. **Everything marked
**unverified** needs an AWS account or a hosted project and has not been run.**

---

## 1. Where everything is

| Thing | Where |
| --- | --- |
| Database, Auth, Storage, Edge Functions, queues | Supabase project, Mumbai (`ap-south-1`) |
| Screening, mail, SMS, logs, alarms | AWS, Mumbai — except the Route 53 health alarms, which are `us-east-1` because that is where Route 53 publishes metrics |
| Appsmith, the deploy runner, the weekly dump, the worker cron | The ops host: one EC2 instance in Mumbai, reached with `aws ssm start-session`, never SSH |
| Worker secret keys, the database password | SSM Parameter Store under `/seva/<environment>/` |
| The specification | `docs/SEVA-backend-v1.md`, local only, its own git repository |

**The three workers are driven by the ops host's cron, not by the database.** Nothing in Postgres
can reach an Edge Function — the extension that would is forbidden by a CI gate. So if screening or
mail stops, **check the ops host before anything else**: a host that is down, or a key that was
rotated without updating SSM, stops all three at once and looks exactly like a Supabase problem.

---

## 2. First moves, by symptom

| Symptom | First actions |
| --- | --- |
| A court or government takedown order arrives | **3-hour clock.** Verify the order, remove the content with `admin_set_content_status`, record the order's details in the reason. The audit row is the evidence. |
| An intimate-imagery report arrives | **2-hour clock.** The first report already held it. Confirm, remove, suspend, and leave the retention record alone. |
| Nothing is being screened, AWS looks healthy | The ops host. `aws ssm start-session --target <id>`, check the cron ran, check the worker key in SSM matches the project's. Then look at `pgmq.a_moderation` for archived jobs. |
| `/discover/health` says `degraded` and nothing says why | By design — it cannot say which of eleven conditions fired. Work §4's triage order below. |
| A Mumbai outage | There is no read path. Confirm the app shows its offline state, post a notice, wait. Do not fail over: §11.4 keeps the data in India. |
| A secret leaks | Revoke that one key, issue a new one, redeploy, update SSM, then check logs for use. Each function and worker has its own key so one revocation is not an outage. |
| Suspected breach | **6-hour CERT-In clock from noticing.** Preserve logs — see §6 below, it is not as simple as it looks — turn on `read_only` if data is being altered, notify the program. |
| Harmful content spreading | Turn off `uploads` and `create_acts` with `admin_set_flag`, clear the held queue, remove and suspend. |
| Points exploit | Turn off `award_points`, fix, rebuild totals from the ledger. The ledger is authoritative; totals are derived. |
| SMS spend climbing | Lower the daily cap, confirm Turnstile is enforced on code requests, block abusive ranges in the hook. The AWS Budgets alarm is the independent backstop. |
| A retention clock has to be proved | §5 below. |
| A bad migration | Roll forward with a fix migration. PITR only if data was lost. Never edit an applied migration. |

---

## 3. The kill switches

Six, all set with `admin_set_flag` as an admin with MFA: `uploads`, `create_acts`,
`create_activities`, `joins`, `award_points`, `read_only`.

**What they do not stop**, and this is deliberate: staff moderation actions and the report intake.
`read_only` is engaged during exactly the incidents when §11.6's 3-hour court-order clock and
§10.4's 2-hour intimate-imagery clock are most likely to be running, so a switch that stopped staff
taking content down, or stopped the public telling us about it, would force a choice between
containment and a legal deadline.

A switch answers `503 FEATURE_DISABLED`, which clients are told to treat as temporary and to keep
the user's draft through.

---

## 4. `degraded`: the triage order

`/discover/health` returns `ok` or `degraded` and nothing else, so a page at 45 minutes into a
two-hour deadline reads the same as a dead job. Work them in this order, because that is the order
of consequence:

1. **`intimate_imagery` and `impersonation` reports.** Those clocks are legal. 2 hours and 36 hours.
2. **Held content past 20 hours.** §10.4's review target is 24.
3. **Open reports past 18 hours.**
4. **Archived jobs** — `pgmq.a_moderation`, `pgmq.a_email`, `pgmq.a_ops`. One row means five
   failures and something a person has to look at.
5. **Anything pending or processing for 15 minutes.** A photo stuck in `processing` usually means
   the moderation worker is not running at all; see §2.

Also worth knowing: while the alarm is in ALARM for a routine 18-hour report, **a new
`intimate_imagery` report crossing 45 minutes produces no new notification**, because CloudWatch
notifies on state changes. Until the legal arms get metrics of their own, the rota needs a standing
queue review rather than waiting to be paged. This is an open item for the program.

---

## 5. The retention clocks

Three run on the ops host's cron through `ops-worker`, and each deletes its rows and queues its file
deletions in **one** transaction, so no object can outlive the row naming it:

| Clock | What | Where to look |
| --- | --- | --- |
| 24 hours | Uploads that never completed | `swept` in the worker's log line |
| 7 days | Account exports and their files | `expired`, `expiredFileJobs` |
| 180 days | Removed content's snapshots, and erased accounts' registration rows | `purgedContent`, `purgedRegistrations`, `purgedFileJobs` |

A fourth, not retention but on the same pass: `unsuspended`, which ends a suspension whose date has
passed. Without it a seven-day suspension would never end.

**A failure in any of them makes the worker answer 5xx rather than logging a zero**, because a
purge that quietly stopped would overrun 180 days with nothing to notice — no §12.5 arm watches
retention. So an `ops-worker` 5xx is a retention incident until proved otherwise.

To prove a clock: check the worker's last call, then look for archived `delete_retained_files` or
`delete_export_file` jobs in `pgmq.a_ops`.

---

## 6. Preserving logs in an incident — read this before you need it

The log bucket uses S3 Object Lock in **COMPLIANCE** mode with a 180-day lifecycle. Two
consequences that will surprise you at the worst moment:

- **Nothing can be deleted early, by anybody, including the account root.** If something that should
  never have been logged reaches the drain, it stays 180 days. There is no cleanup path.
- **Extending a hold needs the break-glass role.** `PutObjectRetention` and `PutObjectLegalHold` are
  denied to every other principal, so an incident noticed on day 170 cannot have its evidence held
  past the expiry without that role. Know who holds it before you need it.

Whether COMPLIANCE is the right mode, given the first point, is an open legal question.

---

## 7. Traps measured during the build

These cost time once. They are written down so they cost nothing again.

- **A local signed upload URL names `http://kong:8000`**, which only Docker can resolve. Storage
  builds it from the URL the edge runtime sees. Hosted, it is correct as issued. A test outside the
  container has to rewrite the scheme and host, leaving the path and signature alone.
- **A new Edge Function folder needs a full `supabase stop && supabase start`**, not a reload.
- **The local stack injects one secret key named `default`.** Each function names its own key, with
  a fallback to `default` gated on the URL being local — so a worker's key check works locally and
  is still one-key-per-worker in production.
- **`log_parameter_max_length_on_error = 0` is load-bearing.** With `log_statement = ddl` and
  `log_min_duration_statement = -1`, an ordinary call is not logged at all, and a constraint
  violation's DETAIL is the only route from a phone number or a reporter's free text into the
  180-day log. Check these after any Postgres configuration change.
- **There is no admin endpoint to revoke another person's sessions.** A suspension queues a job that
  deletes rows from `auth.sessions` directly, which does make a refresh fail.
- **A `remove` on a missing Storage key is a no-op; a `move` errors.** That is why file deletion
  tries every bucket a key could be in and quarantine tolerates a missing source.
- **`select ... for update` needs an update privilege on at least one column.** Narrowing a grant to
  zero columns breaks row locks, not just writes.
- **A table referenced inside an RLS policy is itself subject to that table's RLS.** A policy that
  restates its parent's conditions is dead code; deferring with a bare `exists` cannot drift.

---

## 8. Running it locally

```bash
supabase start
supabase functions serve --no-verify-jwt
deno task db:test     # reset, lint, 1117 pgTAP assertions across 76 files
deno task test        # 196 Edge Function tests
deno task test:api    # 55 end-to-end tests
deno task smoke       # the §14.4 dry run: one real person, sign-up to erasure
cfn-lint infra/aws/*.yaml
k6 run -e BASE=http://127.0.0.1:54321 -e KEY=<publishable> tests/load/discover.js
```

The load script's own README is the thing to read before trusting its numbers: §12.2 limits Discover
per IP, so a single generator is refused almost everything and k6's built-in failure rate reads
~99% while nothing is actually wrong. Measured on a laptop, 40,600 requests in 15 seconds produced
**no 5xx at all**, which is the first evidence for D5's trade-off — a flood reaches Postgres, and
each refusal costs one cheap indexed write.

`deno task smoke` is the one to run when somebody asks whether the product works. It takes a real
account through sign-up, onboarding, a photo upload with real bytes, an Act, a staff approval with
real TOTP, publication, the feed, an avatar on and off, an Activity joined and cancelled, a report,
an export and an erasure — asserting each step — and then reports the three places that need AWS.

**Without an AWS account, exactly three things do not work**, and nothing else is affected:

1. `moderation-worker` — Rekognition and Bedrock Guardrails. Nothing becomes visible on its own, so
   staff must take content `pending → held → visible` by hand. The two calls are the same ones they
   make on a reported item, and everything downstream behaves identically.
2. `message-worker` — SES and End User Messaging. A queued cancellation message retries and then
   archives; nothing is lost.
3. `sms-hook` — phone sign-in. Email sign-in works.

---

## 9. What is not done

- The Rekognition and Guardrails latency spike from Mumbai. Needs an account; **still open.**
- The Appsmith export JSON. The seven screens are defined in `admin/appsmith/screens/*.yaml`; the
  export is produced by building them once in Appsmith and committing the file.
- The ops-host cron, the DLT registration, the SMS spend limit and the protect-configuration
  association. All hand steps on the launch checklist.
- The log scanner, and therefore five of §12.5's seven alarm rows.
- The load test and the restore drill.
- **Four of §10.3's seven admin screens have no read path.** `authenticated` holds nothing on
  `reports`, `admin_audit_log` or `staff`, and the policies on `acts`, `media` and `profiles`
  exclude held content and suspended people — the subjects those screens exist for. Closing it means
  either four new read functions or policies admitting staff, and that is a decision nobody has made.
- Around twenty-six legal and program questions, in §17 of the specification as `O1`–`O52`.
