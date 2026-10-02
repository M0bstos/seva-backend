import { Hono } from "npm:hono@4.13.9";
import { requiredCaller } from "../_shared/auth.ts";
import { secretKeyClient } from "../_shared/db.ts";
import { browserOrigins } from "../_shared/cors.ts";
import { fail, refusal } from "../_shared/errors.ts";
import { idempotencyKey, requestHash } from "../_shared/idempotency.ts";
import { limitArgs } from "../_shared/limits.ts";
import {
  isCategory,
  isFlatNumberMap,
  isIsoDate,
  isLatitude,
  isLongitude,
  isTextWithin,
  isUuid,
  readJsonObject,
} from "../_shared/fields.ts";
import { SECRET_KEY_NAME, STORY_LENGTH, TITLE_LENGTH } from "./acts.constants.ts";

// §7.3's `POST /acts` and `PATCH /acts/:id`. The handler chain is the one §13.4 fixes:
// verify the token, validate the input, call one Postgres function, answer with the
// shared error shape. The kill switch, the limiter, onboarding, suspension and every
// rule about the content itself live in that one function (§12.2), so nothing here
// reads the database twice.
//
// Nothing in this file logs: a request body, a token and a coordinate are all on
// §9.8's never-log list, and §17.1 adds that a route must not log `AGE_RESTRICTED`
// against a user id.
const db = secretKeyClient(SECRET_KEY_NAME);
// Exported for the tests, which exercise the chain through `app.request()`. The
// serve call is guarded so importing this file does not open a listener — the edge
// runtime loads it as the entry module, where `import.meta.main` is true (measured
// against supabase-edge-runtime 1.74.3).
export const app = new Hono().basePath("/acts");

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

  // §7.1.1 hashes "the **validated** input", and the arguments below are what that
  // means here — normalised once, then both hashed and sent. Hashing the body as
  // written instead would make `photo_ids: null` and an omitted `photo_ids` two
  // hashes for one identical call, so a client whose JSON library adds or drops nulls
  // on a retry would be answered 422 for the creation §7.1.1 exists to protect.
  const input = {
    title: body.title,
    story: body.story,
    category: body.category,
    occurred_on: body.occurred_on,
    lon: body.lon,
    lat: body.lat,
    activity_id: body.activity_id ?? null,
    // An empty metrics object and an empty photo array are the same request as
    // leaving either out: create_act coalesces both to nothing, and §7.1.1 would
    // otherwise hold two hashes for one call under one key.
    metrics: emptyAsNull(body.metrics),
    photo_ids: emptyAsNull(body.photo_ids),
  };

  const { data, error } = await db.rpc("create_act", {
    p_title: input.title,
    p_story: input.story,
    p_category: input.category,
    p_occurred_on: input.occurred_on,
    p_lon: input.lon,
    p_lat: input.lat,
    p_activity_id: input.activity_id,
    p_metrics: input.metrics,
    p_photo_ids: input.photo_ids,
    p_idempotency_key: key,
    p_request_hash: await requestHash(input),
    ...limitArgs("acts.create", userId, userId),
  });
  // The Postgres error is not logged: its DETAIL carries the failing row, which is
  // the request body (§9.8). The 5xx is what §12.5's error-rate alarm watches.
  if (error) return fail("INTERNAL");

  const answer = data as Record<string, unknown>;
  const refused = refusal(answer);
  if (refused) return refused;

  // §17.1: 201 for a new Act, 200 for the replay §7.1.1 answers with the original row.
  // `replayed` is how this route tells them apart and is not part of the answer.
  return Response.json({ act: answer.act }, { status: answer.replayed ? 200 : 201 });
});

app.patch("/:id", async (c) => {
  const userId = await requiredCaller(db, c.req.header("Authorization"));
  if (userId instanceof Response) return userId;

  const actId = c.req.param("id");
  if (!isUuid(actId)) return fail("VALIDATION_FAILED", "id");

  const body = await readJsonObject(c.req.raw);
  if (body === null) return fail("VALIDATION_FAILED", "body");

  // §7.3 scopes the edit to "title and story". Either may be left out, and update_act
  // coalesces, so `null` keeps the column exactly as a missing field does — which is
  // why absence is `isPresent` here too, and not `undefined` alone (§7.1.1).
  //
  // A call that changes neither would still re-screen the Act and take a visible one
  // back to `pending` (§8.3), so it is refused. `body` is what the message names:
  // with both absent the route cannot know which one the caller meant, and §7.4 has
  // the message name a field that is actually missing.
  if (!isPresent(body.title) && !isPresent(body.story)) {
    return fail("VALIDATION_FAILED", "body");
  }
  if (isPresent(body.title) && !isTitle(body.title)) {
    return fail("VALIDATION_FAILED", "title");
  }
  if (isPresent(body.story) && !isStory(body.story)) {
    return fail("VALIDATION_FAILED", "story");
  }

  const { data, error } = await db.rpc("update_act", {
    p_act_id: actId,
    p_title: body.title ?? null,
    p_story: body.story ?? null,
    ...limitArgs("acts.update", userId, userId),
  });
  if (error) return fail("INTERNAL");

  const answer = data as Record<string, unknown>;
  const refused = refusal(answer);
  if (refused) return refused;

  return Response.json({ act: answer.act });
});

// The name of the first field that is missing or the wrong shape, or null. Shape
// only: §5.2.1's bounds on the title and story are here because §7.4 has the message
// name the field, while every other rule — the photo count, the metric values and
// their maxima, who owns what — belongs to create_act, which already holds the row
// locks those answers depend on (§8.1).
export function firstProblem(body: Record<string, unknown>): string | null {
  if (!isTitle(body.title)) return "title";
  if (!isStory(body.story)) return "story";
  if (!isCategory(body.category)) return "category";
  if (!isIsoDate(body.occurred_on)) return "occurred_on";
  if (!isLongitude(body.lon)) return "lon";
  if (!isLatitude(body.lat)) return "lat";
  // `null` reads as absent here, as it does for `metrics` and `photo_ids` below, so
  // the normalisation above is what makes the two spellings one request (§7.1.1). A
  // client that sends `activity_id: null` on a retry is answered the original row
  // rather than a 400.
  if (isPresent(body.activity_id) && !isUuid(body.activity_id)) return "activity_id";
  // A flat map of finite numbers. create_act validates the metric names and their
  // values itself, against §5.3's enum and §6.3's maxima, and answers
  // VALIDATION_FAILED or METRIC_OUT_OF_RANGE for them — what it cannot answer for is
  // a payload that raises before its body runs: a nested object that overflows
  // `requestHash`, or a NUL in a key that raises 22P05 and logs the request body
  // (§9.8). Those are this check's job.
  if (isPresent(body.metrics) && !isFlatNumberMap(body.metrics)) return "metrics";
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

// And an empty collection is absent too, because create_act reads both as no metrics
// and no photos. Normalised before the hash, so all three spellings are one request.
function emptyAsNull(value: unknown): unknown {
  if (!isPresent(value)) return null;
  if (Array.isArray(value)) return value.length === 0 ? null : value;
  if (typeof value === "object" && Object.keys(value as object).length === 0) return null;
  return value;
}

function isTitle(value: unknown): value is string {
  return isTextWithin(value, TITLE_LENGTH);
}

function isStory(value: unknown): value is string {
  return isTextWithin(value, STORY_LENGTH);
}

// §7.1 gives every function error one shape, which includes the two Hono would
// otherwise answer itself. A path this function does not serve is "missing" (§7.4),
// and an unexpected throw must not reach a client as a stack trace — §9.8 keeps
// request content out of anything we emit, and the 5xx is what §12.5 counts.
app.notFound(() => fail("NOT_FOUND"));
app.onError(() => fail("INTERNAL"));

if (import.meta.main) Deno.serve(app.fetch);
