import { Hono } from "npm:hono@4.13.9";
import { requiredCaller } from "../_shared/auth.ts";
import { browserOrigins } from "../_shared/cors.ts";
import { secretKeyClient } from "../_shared/db.ts";
import { fail, refusal } from "../_shared/errors.ts";
import { isUuid, readJsonObject } from "../_shared/fields.ts";
import { limitArgs } from "../_shared/limits.ts";
import {
  MAX_UPLOAD_BYTES,
  PURPOSES,
  SECRET_KEY_NAME,
  UPLOADS_BUCKET,
} from "./uploads.constants.ts";

// §7.3's `POST /uploads` and `POST /uploads/:id/complete` — §8.1 steps 1 and 3. This is
// the only producer of the photo jobs §8's worker consumes, so until it exists §8's
// photo pipeline has no in-system trigger and §8.3's photo half is unreachable.
//
// The handler chain is §13.4's: verify the token, validate, call Postgres, answer with
// the shared error shape. The kill switch, limiter, onboarding and suspension all live
// inside the Postgres calls (§12.2, §17.1).
//
// `complete` makes **two** Postgres calls rather than one, which the migration's own
// header argues: §8.1 puts a Storage confirmation between the checks and the writes,
// §5.4 says storage cannot be reached from SQL, and §17.1 requires the count to happen
// before per-request content — which a media id is — is checked.
//
// Nothing here logs. A request body is on §9.8's never-log list, and so is an object
// path: §17.1 records that an avatar's key carries its owner's user id.
const db = secretKeyClient(SECRET_KEY_NAME);
export const app = new Hono().basePath("/uploads");

// §17 `O37`: §4.1's app is "iOS · Android · web", so a browser preflights every call —
// §7.1 puts `apikey` on all of them. §7.3's prose names four route groups for this
// because it was written before this one existed; a web build that can create an Act
// but cannot upload its photo is not a web build.
app.use("*", browserOrigins());

app.post("/", async (c) => {
  const userId = await requiredCaller(db, c.req.header("Authorization"));
  if (userId instanceof Response) return userId;

  const body = await readJsonObject(c.req.raw);
  if (body === null) return fail("VALIDATION_FAILED", "body");
  if (!isPurpose(body.purpose)) return fail("VALIDATION_FAILED", "purpose");

  const { data, error } = await db.rpc("create_upload", {
    p_purpose: body.purpose,
    // `p_user_id` comes from limitArgs, which §12.2 makes the one place a route's
    // caller and caps are assembled.
    ...limitArgs("uploads.create", userId, userId),
  });
  // The Postgres error is not logged: its DETAIL carries the failing row (§9.8).
  if (error) return fail("INTERNAL");

  const answer = data as Record<string, unknown>;
  const refused = refusal(answer);
  if (refused) return refused;

  // §8.1 step 1's other half, which SQL cannot reach (§5.4). A signed URL that cannot
  // be minted leaves the row in `uploading`, which §8.1's own 24-hour sweep collects —
  // so the failure costs a swept row rather than a photo the app cannot upload to.
  const signed = await db.storage
    .from(UPLOADS_BUCKET)
    .createSignedUploadUrl(answer.upload_path as string);
  if (signed.error || !signed.data) return fail("INTERNAL");

  // §17.1 puts this route among the creates that store no `idempotency_key`, so every
  // call is a new row and there is no replay to answer 200 for.
  return Response.json(
    { photo: { id: answer.media_id }, upload_url: signed.data.signedUrl },
    { status: 201 },
  );
});

app.post("/:id/complete", async (c) => {
  const userId = await requiredCaller(db, c.req.header("Authorization"));
  if (userId instanceof Response) return userId;

  const mediaId = c.req.param("id");
  if (!isUuid(mediaId)) return fail("VALIDATION_FAILED", "id");

  const target = await db.rpc("confirm_upload_target", {
    p_media_id: mediaId,
    ...limitArgs("uploads.complete", userId, userId),
  });
  if (target.error) return fail("INTERNAL");

  const confirmed = target.data as Record<string, unknown>;
  const refused = refusal(confirmed);
  if (refused) return refused;

  // No path back means the photo is already past `uploading`, so there is nothing to
  // confirm and nothing to queue. §17.1: a repeat is idempotent by construction, this
  // route being a transition on a resource the URL names rather than a §7.1.1 create.
  const path = confirmed.upload_path;
  if (typeof path !== "string") {
    return Response.json({ photo: { id: mediaId, status: confirmed.status } });
  }

  // §8.1 step 3: "confirms the object exists and is 5 MB or smaller through the Storage
  // API". One call answers both — `info` returns the size, and a missing key is an
  // error (measured against the local stack). Both failures are the caller's upload
  // being wrong rather than the request naming the wrong photo, so §7.4's
  // VALIDATION_FAILED names it and `_shared/errors.ts` composes "file is missing or
  // malformed." The error is not inspected further: a Storage message carries the path.
  // A size the API did not report is treated as a size that cannot be confirmed, which
  // §8.1 asks this step to do before anything is queued — fail closed, because the
  // alternative is sending a file of unknown size to Rekognition at §8.4's expense.
  const object = await db.storage.from(UPLOADS_BUCKET).info(path);
  const size = object.data?.size;
  if (object.error || typeof size !== "number") return fail("VALIDATION_FAILED", "file");
  if (size > MAX_UPLOAD_BYTES) return fail("VALIDATION_FAILED", "file");

  const queued = await db.rpc("queue_photo_screening", {
    p_user_id: userId,
    p_media_id: mediaId,
  });
  if (queued.error) return fail("INTERNAL");

  const answer = queued.data as Record<string, unknown>;
  const refusedWrite = refusal(answer);
  if (refusedWrite) return refusedWrite;

  return Response.json({ photo: { id: mediaId, status: answer.status } });
});

// Exported for the tests, so §5.3's enum is checked as the pure function it is rather
// than through a chain that answers 401 first (§13.4 puts the token before the body).
export function isPurpose(value: unknown): value is string {
  return typeof value === "string" && (PURPOSES as readonly string[]).includes(value);
}

// §7.1 gives every function error one shape, including the two Hono would otherwise
// answer in its own words: a path this function does not serve is "missing" (§7.4), and
// an unexpected throw must not reach a client as a stack trace.
app.notFound(() => fail("NOT_FOUND"));
app.onError(() => fail("INTERNAL"));

if (import.meta.main) Deno.serve(app.fetch);
