import { Hono } from "npm:hono@4.13.9";
import { requiredCaller } from "../_shared/auth.ts";
import { secretKeyClient } from "../_shared/db.ts";
import { browserOrigins } from "../_shared/cors.ts";
import { fail, refusal } from "../_shared/errors.ts";
import {
  isCategory,
  isFiniteNumber,
  isLatitude,
  isLongitude,
  isTextWithin,
  isTimestamp,
  isUuid,
  readJsonObject,
} from "../_shared/fields.ts";
import { idempotencyKey, requestHash } from "../_shared/idempotency.ts";
import { limitArgs } from "../_shared/limits.ts";
import {
  CAPACITY,
  DESCRIPTION_LENGTH,
  LOCATION_LABEL_LENGTH,
  MAX_HOURS,
  SECRET_KEY_NAME,
  TITLE_LENGTH,
  WHAT_TO_BRING_LENGTH,
} from "./activities.constants.ts";

// §7.3's four Activity routes: create, join, leave and cancel. The handler chain is
// the one §13.4 fixes — verify the token, validate, call one Postgres function,
// answer with the shared error shape — and everything else lives in that function:
// the kill switch, the limiter, §9.6's 18+ rule for organisers, the capacity lock,
// and who is allowed to cancel (§12.2, §17.1).
//
// Nothing here logs. A request body, a token and a coordinate are all on §9.8's
// never-log list, and §17.1 adds that a route must not log `AGE_RESTRICTED` against a
// user id — which this route group is the one that can answer it.
const db = secretKeyClient(SECRET_KEY_NAME);

// Exported for the tests, which exercise the chain through `app.request()`. The serve
// call is guarded so importing this file does not open a listener; the edge runtime
// loads it as the entry module, where `import.meta.main` is true.
export const app = new Hono().basePath("/activities");

// §17 `O37`: §4.1's app is "iOS · Android · web", so a browser preflights every call
// here — §7.1 puts `apikey` on all of them. Before routing, so an OPTIONS is answered
// rather than falling through to the 404 below.
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

  // §7.1.1 hashes "the **validated** input", and these are the arguments the function
  // receives — normalised once, then both hashed and sent. Hashing the body as written
  // would make an omitted optional field and an explicit null two hashes for one
  // identical call, and answer a retry 422 (§7.1.1).
  const input = {
    title: body.title,
    description: body.description,
    category: body.category,
    starts_at: body.starts_at,
    ends_at: body.ends_at,
    lon: body.lon,
    lat: body.lat,
    location_label: body.location_label,
    capacity: body.capacity,
    what_to_bring: body.what_to_bring ?? null,
    campaign_id: body.campaign_id ?? null,
    // An empty photo array is the same request as leaving it out, and §7.1.1 would
    // otherwise hold two hashes for one call under one key.
    photo_ids: emptyAsNull(body.photo_ids),
  };

  const { data, error } = await db.rpc("create_activity", {
    p_title: input.title,
    p_description: input.description,
    p_category: input.category,
    p_starts_at: input.starts_at,
    p_ends_at: input.ends_at,
    p_lon: input.lon,
    p_lat: input.lat,
    p_location_label: input.location_label,
    p_capacity: input.capacity,
    p_what_to_bring: input.what_to_bring,
    p_campaign_id: input.campaign_id,
    p_photo_ids: input.photo_ids,
    p_idempotency_key: key,
    p_request_hash: await requestHash(input),
    ...limitArgs("activities.create", userId, userId),
  });
  // The Postgres error is not logged: its DETAIL carries the failing row, which is the
  // request body (§9.8). The 5xx is what §12.5's error-rate alarm watches.
  if (error) return fail("INTERNAL");

  const answer = data as Record<string, unknown>;
  const refused = refusal(answer);
  if (refused) return refused;

  // §17.1: 201 for a new Activity, 200 for the replay §7.1.1 answers with the
  // original row. `replayed` is how this route tells them apart, not part of the
  // answer.
  return Response.json({ activity: answer.activity }, { status: answer.replayed ? 200 : 201 });
});

// §7.3: "Joins under a capacity lock. Joining twice returns the existing row." No
// Idempotency-Key: §7.1 requires one on a create, and a repeat join is not one — the
// Postgres function answers the existing row and §17.1 meters it like any request.
app.post("/:id/join", (c) => call(c.req.param("id"), c.req.header("Authorization"), "join"));

// §7.3: "Frees the place", sharing the join limit, so it passes the join bucket
// rather than one of its own (`_shared/limits.constants.ts`).
app.post("/:id/leave", (c) => call(c.req.param("id"), c.req.header("Authorization"), "leave"));

// §7.3: "Cancels and emails participants". The mail is queued inside the function,
// because §4 has the workers as the only code that calls AWS.
app.post("/:id/cancel", (c) => call(c.req.param("id"), c.req.header("Authorization"), "cancel"));

type Membership = "join" | "leave" | "cancel";

// The three take one id and nothing else, so they share a handler rather than three
// copies of the same six lines. The limit name is the one difference §7.3 draws
// between them: leave shares join's budget, and cancel has its own.
async function call(
  activityId: string,
  authorization: string | undefined,
  action: Membership,
): Promise<Response> {
  const userId = await requiredCaller(db, authorization);
  if (userId instanceof Response) return userId;
  if (!isUuid(activityId)) return fail("VALIDATION_FAILED", "id");

  const { data, error } = await db.rpc(`${action}_activity`, {
    p_activity_id: activityId,
    ...limitArgs(action === "cancel" ? "activities.cancel" : "activities.join", userId, userId),
  });
  if (error) return fail("INTERNAL");

  // The function's payload goes out as it stands — `joined_at`, `participant_count`
  // and `already_joined` for a join; `left` and `participant_count` for a leave;
  // `cancelled_at` and `notified` for a cancel. Nothing is stripped, unlike the
  // create path's `replayed`: each of those fields answers something §7.3 asks the
  // route to do, and `reference/api.md` states them (§7.5).
  const answer = data as Record<string, unknown>;
  return refusal(answer) ?? Response.json(answer);
}

// The name of the first field that is missing or the wrong shape, or null. §5.2.1's
// bounds are checked here so §7.4's message names the field; everything else — the
// campaign being active, who owns which photo, the organiser being 18+ — belongs to
// create_activity, which holds the locks those answers depend on.
export function firstProblem(body: Record<string, unknown>): string | null {
  if (!isTextWithin(body.title, TITLE_LENGTH)) return "title";
  if (!isTextWithin(body.description, DESCRIPTION_LENGTH)) return "description";
  if (!isCategory(body.category)) return "category";
  if (!isTimestamp(body.starts_at)) return "starts_at";
  if (!isTimestamp(body.ends_at)) return "ends_at";

  // §5.2.1 bounds the length of an Activity as well as its order. Checked here so the
  // message names `ends_at`; the table's checks catch anything that slips past.
  const starts = Date.parse(body.starts_at);
  const ends = Date.parse(body.ends_at);
  if (ends <= starts || ends - starts > MAX_HOURS * 60 * 60 * 1000) return "ends_at";

  if (!isLongitude(body.lon)) return "lon";
  if (!isLatitude(body.lat)) return "lat";
  if (!isTextWithin(body.location_label, LOCATION_LABEL_LENGTH)) return "location_label";
  if (
    !isFiniteNumber(body.capacity) || !Number.isInteger(body.capacity) ||
    body.capacity < CAPACITY.min || body.capacity > CAPACITY.max
  ) {
    return "capacity";
  }
  if (isPresent(body.what_to_bring) && !isTextWithin(body.what_to_bring, WHAT_TO_BRING_LENGTH)) {
    return "what_to_bring";
  }
  // `null` reads as absent for every optional field, so the normalisation above makes
  // the two spellings one request (§7.1.1) rather than one of them a 400.
  if (isPresent(body.campaign_id) && !isUuid(body.campaign_id)) return "campaign_id";
  if (isPresent(body.photo_ids)) {
    if (!Array.isArray(body.photo_ids) || !body.photo_ids.every(isUuid)) return "photo_ids";
  }
  return null;
}

// An optional field is absent when it is missing or null: §7.1.1 makes a retry that
// spells one of those the other the same request, so they cannot mean different things.
function isPresent(value: unknown): boolean {
  return value !== undefined && value !== null;
}

// And an empty photo array is absent too, because create_activity reads it as no
// photos. Normalised before the hash, so all three spellings are one request.
function emptyAsNull(value: unknown): unknown {
  if (!isPresent(value)) return null;
  return Array.isArray(value) && value.length === 0 ? null : value;
}

// §7.1 gives every function error one shape, which includes the two Hono would
// otherwise answer itself. A path this function does not serve is "missing" (§7.4),
// and an unexpected throw must not reach a client as a stack trace — §9.8 keeps
// request content out of anything we emit, and the 5xx is what §12.5 counts.
app.notFound(() => fail("NOT_FOUND"));
app.onError(() => fail("INTERNAL"));

if (import.meta.main) Deno.serve(app.fetch);
