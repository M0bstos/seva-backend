import { Hono } from "npm:hono@4.13.9";
import { requiredCaller } from "../_shared/auth.ts";
import { browserOrigins } from "../_shared/cors.ts";
import { secretKeyClient } from "../_shared/db.ts";
import { fail, refusal } from "../_shared/errors.ts";
import { isTextWithin, isUuid, readJsonObject } from "../_shared/fields.ts";
import { idempotencyKey, requestHash } from "../_shared/idempotency.ts";
import { limitArgs } from "../_shared/limits.ts";
import {
  DETAILS_LENGTH,
  REASONS,
  SECRET_KEY_NAME,
  SUBJECT_FIELDS,
  SUBJECT_TYPES,
} from "./reports.constants.ts";

// §7.3's `POST /reports`: "Reports an Act, Activity or person | Signed in | 20/day". The
// handler chain is §13.4's — verify the token, validate, call one Postgres function,
// answer with the shared error shape — and everything else lives in `submit_report`,
// which §8.5 says owns the whole flow "not a trigger, so it all happens in one
// transaction".
//
// Nothing here logs. §9.8 keeps request bodies out, which matters more on this route than
// most: a `details` field is free text about another person, and §11.6 keeps the Postgres
// log 180 days.
const db = secretKeyClient(SECRET_KEY_NAME);
export const app = new Hono().basePath("/reports");

// §17 `O37`: §4.1's app is "iOS · Android · web", so a browser preflights every call.
app.use("*", browserOrigins());

app.post("/", async (c) => {
  const userId = await requiredCaller(db, c.req.header("Authorization"));
  if (userId instanceof Response) return userId;

  const key = idempotencyKey(c.req.raw.headers);
  if (!key) return fail("VALIDATION_FAILED", "Idempotency-Key");

  const body = await readJsonObject(c.req.raw);
  if (body === null) return fail("VALIDATION_FAILED", "body");

  const bad = firstProblem(body);
  if (bad) return fail("VALIDATION_FAILED", bad);

  // §7.1.1 hashes "the **validated** input", which §17.1 settles as the normalised
  // arguments rather than the body as written: `details: null` and an omitted `details`
  // reach `submit_report` as the identical argument, so hashing the body would give one
  // call two hashes and answer a retry `IDEMPOTENCY_KEY_REUSED`.
  const input = {
    subject_type: body.subject_type,
    act_id: body.act_id ?? null,
    activity_id: body.activity_id ?? null,
    reported_user_id: body.reported_user_id ?? null,
    reason: body.reason,
    details: body.details ?? null,
  };

  const { data, error } = await db.rpc("submit_report", {
    p_subject_type: input.subject_type,
    p_act_id: input.act_id,
    p_activity_id: input.activity_id,
    p_reported_user_id: input.reported_user_id,
    p_reason: input.reason,
    p_details: input.details,
    p_idempotency_key: key,
    p_request_hash: await requestHash(input),
    ...limitArgs("reports.create", userId, userId),
  });
  // The Postgres error is not logged: its DETAIL carries the failing row, which here is
  // free text a person wrote about another person (§9.8).
  if (error) return fail("INTERNAL");

  const answer = data as Record<string, unknown>;
  const refused = refusal(answer);
  if (refused) return refused;

  // §17.1: 201 for a new row, 200 otherwise. Two flags and not one, because
  // `submit_report` answers a duplicate with the open report on file (§5.2.1 allows one per
  // reporter per subject) and that created nothing either — a 201 there told the app a
  // second report existed, and an end-to-end test caught it.
  //
  // Nothing about §8.5's automatic hold is in the answer, and `submit_report` sends none —
  // a reporter who could see the threshold fire could find it by experiment.
  const created = !answer.replayed && !answer.already_open;
  return Response.json({ report: answer.report }, { status: created ? 201 : 200 });
});

// The name of the first field that is missing or the wrong shape, or null. Shape only:
// whether the subject exists, whether the reporter may see it, and §8.5's threshold are
// all `submit_report`'s, which holds the row locks those answers depend on.
export function firstProblem(body: Record<string, unknown>): string | null {
  if (!isSubjectType(body.subject_type)) return "subject_type";
  if (!isReason(body.reason)) return "reason";

  // §5.2.1 pairs each `subject_type` with one id column and forbids the others. Checked
  // here as well as in `submit_report` because §7.4 has the message name the field, and
  // the table's own check can only name the row (§17.1).
  // The named column first, so a caller who says `activity` and sends `act_id` is told
  // `activity_id` — the field their own `subject_type` asks for — rather than being told
  // about the one they did send. Then the other two, which must be absent.
  const named = SUBJECT_FIELDS[body.subject_type];
  if (!isUuid(body[named])) return named;
  for (const field of Object.values(SUBJECT_FIELDS)) {
    if (field !== named && body[field] !== undefined && body[field] !== null) return field;
  }

  // Absent and null are the same request (§7.1.1), and an empty string is not: §5.2.1
  // stores it, so it is a value rather than a missing field.
  if (body.details !== undefined && body.details !== null) {
    if (!isTextWithin(body.details, DETAILS_LENGTH)) return "details";
  }
  return null;
}

function isSubjectType(value: unknown): value is keyof typeof SUBJECT_FIELDS {
  return typeof value === "string" &&
    (SUBJECT_TYPES as readonly string[]).includes(value);
}

function isReason(value: unknown): value is string {
  return typeof value === "string" &&
    (REASONS as readonly string[]).includes(value);
}

// §7.1 gives every function error one shape, including the two Hono would otherwise
// answer in its own words.
app.notFound(() => fail("NOT_FOUND"));
app.onError(() => fail("INTERNAL"));

if (import.meta.main) Deno.serve(app.fetch);
