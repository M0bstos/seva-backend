import { Hono } from "npm:hono@4.13.9";
import {
  ApplyGuardrailCommand,
  BedrockRuntimeClient,
} from "npm:@aws-sdk/client-bedrock-runtime@3.1141.0";
import {
  DetectModerationLabelsCommand,
  type ModerationLabel,
  RekognitionClient,
} from "npm:@aws-sdk/client-rekognition@3.1141.0";
import { timingSafeEqual } from "jsr:@std/crypto@1.1.0/timing-safe-equal";
import { secretKey, secretKeyClient } from "../_shared/db.ts";
import { fail } from "../_shared/errors.ts";
import { isAcceptableJpeg, readDimensions, stripMetadata } from "./jpeg.ts";
import {
  AWS_REGION_VARIABLE,
  BATCH_SIZE,
  GUARDRAIL_ID_VARIABLE,
  GUARDRAIL_VERSION_VARIABLE,
  HIGH_SEVERITY_CATEGORIES,
  HOLD_AT_CONFIDENCE,
  LABEL_FLOOR_CONFIDENCE,
  LOG_LINES,
  MEDIA_BUCKET,
  PUBLISHED_CONTENT_TYPE,
  SECRET_KEY_NAME,
  UPLOADS_BUCKET,
} from "./moderation-worker.constants.ts";

// §8's worker. Cron calls it (§4.1), it claims a batch of jobs, and for each one it
// asks AWS and writes the answer back. §8 is explicit about why it is a worker and not
// part of a route: "Screening runs in background workers, so a slow or unavailable
// service delays publishing rather than breaking the app."
//
// `verify_jwt` is false and the secret key is checked here, because §7.3 says that key
// is not a JWT. Nothing is logged but counts: §9.8 keeps content, coordinates and
// identifiers out, and §12.5 reads these lines for a backlog. That bites hardest on
// an `activity_text` job, which carries `activities.location_label` — a meeting point
// a person typed, which can hold an exact address. So neither the claim's answer nor
// the Guardrails request may be logged, which is why the catch below logs the kind
// alone.
//
// A job that raises is left alone rather than completed, so §8.4's retry has it:
// "hidden for 60 seconds while processing and retried up to 5 times. After that they
// are archived and an alarm fires; nothing is silently dropped."
const db = secretKeyClient(SECRET_KEY_NAME);
const aws = awsSettings();
const guardrails = new BedrockRuntimeClient({ region: aws.region });
const rekognition = new RekognitionClient({ region: aws.region });

type Job = {
  msg_id: number;
  kind: "act_text" | "activity_text" | "profile_text" | "photo";
  texts?: (string | null)[];
  // What the verdict is about. The completion refuses one whose digest no longer
  // matches the live row, so an author editing while a job is in flight cannot have
  // the old verdict applied to the new text.
  digest?: string;
  upload_path?: string;
};

export const app = new Hono().basePath("/moderation-worker");

app.post("/", async (c) => {
  if (!authorised(c.req.header("Authorization"))) return fail("UNAUTHENTICATED");

  const { data, error } = await db.rpc("claim_moderation_jobs", { p_count: BATCH_SIZE });
  if (error) return fail("INTERNAL");

  const jobs = data as Job[];
  let screened = 0;
  let failed = 0;

  // Serially, because §8.4 caps Rekognition at 5 requests a second in Mumbai and says
  // to "keep the worker's concurrency below whatever limit is granted".
  for (const job of jobs) {
    try {
      if (job.kind === "photo") await screenPhoto(job);
      else await screenText(job);
      screened++;
    } catch {
      // The exception is not logged: a Guardrails validation error echoes the text it
      // was given, and a Storage error the path (§9.8). The kind is all §12.5 needs.
      console.log(`${LOG_LINES.failed} kind=${job.kind}`);
      failed++;
    }
  }

  console.log(`${LOG_LINES.run} claimed=${jobs.length} screened=${screened} failed=${failed}`);
  return Response.json({ claimed: jobs.length, screened, failed });
});

// §8.2: "The worker calls Bedrock Guardrails' `ApplyGuardrail` with content filters
// for hate, insults, sexual content, violence and misconduct. Filter strength starts
// at *medium*" — the filters and the strength are the guardrail's own configuration,
// which is why this call names one and sets none.
async function screenText(job: Job) {
  // The nulls are §5.2.1's optional columns — a bio, a what-to-bring — which
  // `claim_moderation_jobs` carries through as they are.
  const texts = (job.texts ?? []).filter((text): text is string =>
    typeof text === "string" && text.length > 0
  );

  // One call for the whole job rather than one per field. Not because the fields are
  // small — §5.2.1 gives a story and a description up to 2,000 characters, which is
  // two of §8.4's text units on its own — but because §8.2 wants one verdict per piece
  // of content, and `ApplyGuardrail`'s aggregate `action` is that verdict. Billing is
  // by character either way.
  const answer = await guardrails.send(
    new ApplyGuardrailCommand({
      guardrailIdentifier: aws.guardrailId,
      guardrailVersion: aws.guardrailVersion,
      source: "INPUT",
      content: texts.map((text) => ({ text: { text } })),
    }),
  );

  await complete("complete_text_screening", {
    p_msg_id: job.msg_id,
    p_flagged: answer.action === "GUARDRAIL_INTERVENED",
    p_digest: job.digest,
  });
}

// §8.1's four steps, in order: check the bytes, strip the metadata, screen, publish.
async function screenPhoto(job: Job) {
  const path = job.upload_path;
  if (!path) throw new Error("a photo job with no upload path");

  const download = await db.storage.from(UPLOADS_BUCKET).download(path);
  if (download.error || !download.data) throw new Error("the upload could not be read");
  const original = new Uint8Array(await download.data.arrayBuffer());

  // Steps 1 and 2. §5.3 keeps `rejected` for a file that is not the JPEG it claimed to
  // be — the bucket's allow-list checks the declared type, not the bytes.
  const stripped = isAcceptableJpeg(original) ? stripMetadata(original) : null;
  if (!stripped) {
    await complete("complete_photo_screening", {
      p_msg_id: job.msg_id,
      p_outcome: "rejected",
      p_labels: null,
      p_bytes: null,
      p_width: null,
      p_height: null,
    });
    // Nothing to review in a malformed file, so it goes with the row's verdict.
    await db.storage.from(UPLOADS_BUCKET).remove([path]);
    return;
  }

  // Step 3. The floor is below §8.4's hold threshold on purpose: the near-misses are
  // what the closed beta tunes against, and `media_labels` is where they are kept.
  const screening = await rekognition.send(
    new DetectModerationLabelsCommand({
      Image: { Bytes: stripped },
      MinConfidence: LABEL_FLOOR_CONFIDENCE,
    }),
  );
  const labels = screening.ModerationLabels ?? [];
  const held = holdsPhoto(labels);
  const size = readDimensions(stripped);

  // Step 4, for a photo that passed. §8.1 publishes "full size + 480 px thumbnail";
  // the thumbnail is the half of §16 week 1's spike that is still open, because it
  // needs a JPEG decoder and §3.3 has no approved dependency for one. `thumb_path`
  // stays null and §8.1's own fallback — the app uploading its own thumbnail as a
  // second photo — is what covers it until that is decided.
  //
  // The published object takes the same path inside `media` that it had inside
  // `uploads`, so one key identifies one photo in both buckets.
  // Nothing is published for a held or rejected photo: §8 opens "Nothing a person
  // writes or uploads is public until it has been screened", and `media` is a public
  // bucket. What that leaves open is who publishes one a moderator later approves —
  // §8.3's held → visible — which is week 4–5's `admin_set_content_status` queueing an
  // `ops` job, because §5.4 says storage cannot be reached from SQL. Recorded in §8.1.
  if (!held) {
    // `upsert` because §8.4 retries: a job that died after the upload and before the
    // completion runs again, and the second upload must not fail on the first.
    const upload = await db.storage.from(MEDIA_BUCKET).upload(path, stripped, {
      contentType: PUBLISHED_CONTENT_TYPE,
      upsert: true,
    });
    if (upload.error) throw new Error("the published copy could not be written");
  }

  await complete("complete_photo_screening", {
    p_msg_id: job.msg_id,
    p_outcome: held ? "held" : "ready",
    p_labels: {
      model_version: screening.ModerationModelVersion ?? null,
      labels,
    },
    p_bytes: stripped.length,
    p_width: size?.width ?? null,
    p_height: size?.height ?? null,
  });

  // §8.1 step 4 "deletes the original upload". Only for a photo that passed: §10.3's
  // review screen shows held content, and a moderator cannot review a file that is
  // gone. A held photo's original therefore stays in the private `uploads` bucket,
  // where nothing serves it, until staff decide (§11.6 moves a removed one to
  // `quarantine`).
  if (!held) await db.storage.from(UPLOADS_BUCKET).remove([path]);
}

// §8.4's threshold. The four names are level-1 categories and no deeper label shares
// one, so matching the name is what decides — and matching it *without* also requiring
// `TaxonomyLevel === 1` is deliberate: a response that omitted the level would
// otherwise pass every photo silently. Reading `ParentName` instead would miss
// "Explicit" on a photo labelled three levels deep, since a level-3 label's parent is
// its level-2 one rather than the category.
export function holdsPhoto(labels: ModerationLabel[]): boolean {
  return labels.some((label) =>
    (HIGH_SEVERITY_CATEGORIES as readonly string[]).includes(label.Name ?? "") &&
    (label.Confidence ?? 0) >= HOLD_AT_CONFIDENCE
  );
}

// A completion that the database refuses is the worker's bug, not the queue's, so it
// raises and the job is left for §8.4's retry rather than being silently dropped.
async function complete(fn: string, args: Record<string, unknown>) {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error("the screening result could not be written");
  const answer = data as { error?: string } | null;
  // NOT_FOUND is work another worker already did, past the 60-second window (§8.4).
  if (answer?.error && answer.error !== "NOT_FOUND") {
    throw new Error("the screening result was refused");
  }
}

// §7.3: the workers "check their secret key in code, since that key is not a JWT".
// Compared as bytes and in constant time, and not logged either way (§9.8).
export function authorised(authorization: string | undefined): boolean {
  const bearer = authorization?.match(/^Bearer (\S+)$/);
  if (!bearer) return false;

  const sent = new TextEncoder().encode(bearer[1]);
  const expected = new TextEncoder().encode(secretKey(SECRET_KEY_NAME));
  return sent.length === expected.length && timingSafeEqual(sent, expected);
}

// Read at boot, so a worker missing one of them fails on deploy rather than after it
// has already claimed a batch and hidden it for 60 seconds.
function awsSettings() {
  const read = (name: string) => {
    const value = Deno.env.get(name);
    if (!value) throw new Error(`${name} is not set`);
    return value;
  };
  return {
    region: read(AWS_REGION_VARIABLE),
    guardrailId: read(GUARDRAIL_ID_VARIABLE),
    guardrailVersion: read(GUARDRAIL_VERSION_VARIABLE),
  };
}

app.notFound(() => fail("NOT_FOUND"));
app.onError(() => fail("INTERNAL"));

if (import.meta.main) Deno.serve(app.fetch);
