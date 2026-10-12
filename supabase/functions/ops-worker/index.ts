import { Hono } from "npm:hono@4.13.9";
import { timingSafeEqual } from "jsr:@std/crypto@1.1.0/timing-safe-equal";
import { secretKey, secretKeyClient } from "../_shared/db.ts";
import { fail } from "../_shared/errors.ts";
import {
  BATCH_SIZE,
  BUCKETS,
  DELETE_FROM,
  EXPORT_CONTENT_TYPE,
  LOG_LINES,
  PUBLIC_MEDIA_PREFIX,
  PUBLISH_FROM,
  PUBLISHED_CONTENT_TYPE,
  SECRET_KEY_NAME,
} from "./ops-worker.constants.ts";

// §1.1's third worker: "Operations (cleanup and health checks)". Cron calls it (§4.1), it drains
// the `ops` queue and then does the time-driven work nothing queues — §8.1's 24-hour sweep,
// §O7's seven-day export expiry and §11.6's 180-day purge.
//
// It is the only code that reaches Storage for anything but a screening publication, because §5.4
// is explicit that "storage files cannot be deleted with SQL". Every database decision stays in a
// Postgres function; this worker moves bytes and reports counts.
//
// Nothing is logged but counts and kinds. §9.8 allows an object path — it carries a user id and no
// coordinate — but a failure line names the kind alone, because a Storage error message carries
// the path and an Auth error can carry an address.
const db = secretKeyClient(SECRET_KEY_NAME);
export const app = new Hono().basePath("/ops-worker");

type Job = {
  msg_id: number;
  kind:
    | "delete_media_files"
    | "quarantine_file"
    | "publish_photo"
    | "sign_out"
    | "export_account"
    | "delete_account"
    | "delete_retained_files"
    | "delete_export_file";
  upload_path?: string;
  public_path?: string;
  thumb_path?: string;
  path?: string;
  paths?: string[];
  file_path?: string;
  media_id?: string;
  user_id?: string;
  export_id?: string;
};

app.post("/", async (c) => {
  if (!authorised(c.req.header("Authorization"))) return fail("UNAUTHENTICATED");

  const { data, error } = await db.rpc("claim_ops_jobs", { p_count: BATCH_SIZE });
  if (error) return fail("INTERNAL");

  const jobs = data as Job[];
  let done = 0;
  let failed = 0;

  // Serially, like the other two workers: the ops host's cron calls all three and the batch is
  // bounded by round trips. A job that raises is left alone so §8.4's retry has it.
  for (const job of jobs) {
    try {
      await run(job);
      done++;
    } catch {
      console.log(`${LOG_LINES.failed} kind=${job.kind}`);
      failed++;
    }
  }

  // The time-driven work, after the queue. It runs every invocation rather than on a schedule of
  // its own because §4.1 gives this worker one cron entry, and each step is a single indexed
  // statement that finds nothing on most runs.
  const maintenance = await maintain();

  console.log(`${LOG_LINES.run} claimed=${jobs.length} done=${done} failed=${failed}`);
  // Counts only (§9.8). The file-job counts matter as much as the row counts now that the two
  // retention clocks queue their deletions rather than returning keys: rows released with no job
  // sent would be the silent half of §11.6's duty.
  console.log(
    `${LOG_LINES.maintenance} swept=${maintenance.swept} unsuspended=${maintenance.unsuspended} ` +
      `expired=${maintenance.expired} expired_file_jobs=${maintenance.expiredFileJobs} ` +
      `purged_content=${maintenance.purgedContent} ` +
      `purged_registrations=${maintenance.purgedRegistrations} ` +
      `purged_file_jobs=${maintenance.purgedFileJobs}`,
  );
  return Response.json({ claimed: jobs.length, done, failed, ...maintenance });
});

async function run(job: Job) {
  switch (job.kind) {
    case "delete_media_files": {
      // §5.4's trigger names the three paths and not their buckets, so each is removed from every
      // bucket it could be in (§17.1). The row is already gone — the trigger fires `after delete`.
      await removeEverywhere(
        [job.upload_path, job.public_path, job.thumb_path].filter(isPath),
      );
      await completeJob(job);
      return;
    }

    case "delete_retained_files": {
      // §11.6's 180 days are up and `purge_retained_records` has already deleted the row, in the
      // transaction that sent this. Any of the three buckets, by the same no-bucket-column
      // decision as `delete_media_files` (§17.1) — a held photo's original moves to `quarantine`
      // only if the content is later removed, so a bucket recorded at snapshot time would be
      // stale.
      await removeEverywhere((job.paths ?? []).filter(isPath));
      await completeJob(job);
      return;
    }

    case "delete_export_file": {
      // `O7`'s seven days. One bucket, because §5.5 writes an export to `exports` and nowhere
      // else — and `remove` on a key that is not there is a no-op, so a retry of an already
      // deleted file succeeds.
      const exportPath = job.file_path;
      if (!isPath(exportPath)) throw new Error("an export deletion with no path");
      const gone = await db.storage.from(BUCKETS.exports).remove([exportPath]);
      if (gone.error) throw new Error("the expired export could not be deleted");
      await completeJob(job);
      return;
    }

    case "quarantine_file": {
      // §11.6: "The public `media` bucket must stop serving a removed file immediately. Moving it
      // to `quarantine` rather than deleting it satisfies both the takedown and the retention
      // duty." Measured: `move` errors `NoSuchKey` on an object that is not there, which a retry
      // of an already-moved file hits — so a missing source is success rather than a failure that
      // would retry five times and archive.
      const path = job.path;
      if (!isPath(path)) throw new Error("a quarantine job with no path");
      const moved = await db.storage
        .from(BUCKETS.media)
        .move(path, path, { destinationBucket: BUCKETS.quarantine });
      if (moved.error && !(await missing(BUCKETS.media, path))) {
        throw new Error("the file could not be quarantined");
      }
      await completeJob(job);
      return;
    }

    case "publish_photo": {
      // §8.3's held → visible for a photo. The bytes are copied before any row says they are
      // published, which is §8.1's invariant — "a `ready` photo always has a published copy".
      // `claim_ops_jobs` hands over the `upload_path` read off the row, so the published key is
      // derived rather than taken from the message (§8.1, §17.1).
      const path = job.upload_path;
      if (!isPath(path)) throw new Error("a publish job with no path");
      await publish(path);
      // The completion sets `ready` and `public_path`, re-checking `processing` under a lock so a
      // takedown committing beside it is not overwritten.
      await expectDatabase("complete_photo_publication", { p_msg_id: job.msg_id });
      return;
    }

    case "sign_out": {
      // §10.2's suspension queues this. The whole of it is SQL: measured, GoTrue exposes no admin
      // endpoint for revoking another person's sessions, so `complete_sign_out` deletes them and
      // closes the job in one definer frame.
      await expectDatabase("complete_sign_out", { p_msg_id: job.msg_id });
      return;
    }

    case "export_account": {
      // §7.3: "The operations worker calls `export_account(user_id)`, one Postgres call returning
      // jsonb, and writes `exports/{user_id}/{export_id}.json` to the private `exports` bucket."
      const { user_id: userId, export_id: exportId } = job;
      if (!userId || !exportId) throw new Error("an export job with no subject");

      const built = await db.rpc("export_account", {
        p_user_id: userId,
        p_media_base_url: publicMediaBase(),
      });
      if (built.error) throw new Error("the export could not be built");

      const path = `${userId}/${exportId}.json`;
      const written = await db.storage.from(BUCKETS.exports).upload(
        path,
        new TextEncoder().encode(JSON.stringify(built.data)),
        // `upsert` because §8.4 retries: a job that died after the write and before the completion
        // runs again, and the second write must not fail on the first.
        { contentType: EXPORT_CONTENT_TYPE, upsert: true },
      );
      if (written.error) throw new Error("the export could not be written");

      await expectDatabase("complete_account_export", {
        p_msg_id: job.msg_id,
        p_export_id: exportId,
        p_file_path: path,
      });
      return;
    }

    case "delete_account": {
      // §5.5's function does the whole erasure in one transaction, including §11.6's copy-first
      // retention writes. The files its cascade released are queued as `delete_media_files` jobs
      // by §5.4's trigger, so there is nothing for this worker to do with Storage here.
      const userId = job.user_id;
      if (!userId) throw new Error("a deletion job with no subject");
      const erased = await db.rpc("delete_account", { p_user_id: userId });
      if (erased.error) throw new Error("the account could not be erased");

      // **A refusal is logged**, which review asked for and §11.2 is the reason. `FORBIDDEN` here
      // means §5.4's "staff are demoted, never deleted" — the function marks the request `failed`
      // and closes, so no retry burns, but nothing else in the system says why: no audit row,
      // because it is not a staff action, and no §12.5 arm covers `account_deletions`. Without
      // this line a staff member's erasure fails permanently and invisibly, and they can re-ask
      // three times a day to the same silence. With the user id, which §9.8 permits in terms —
      // "Logs identify people by user ID only" — because an operator who cannot tell *whose*
      // request failed cannot act on it (§17.1 carries the §12.5 arm this still wants).
      const refusal = (erased.data as { error?: string } | null)?.error;
      if (refusal === "FORBIDDEN") {
        console.log(`${LOG_LINES.refused} kind=${job.kind} user=${userId}`);
      }

      // NOT_FOUND means it was already done, which is a job to close rather than retry.
      await completeJob(job);
      return;
    }
  }
}

// §8.1's 24-hour sweep, §O7's seven days and §11.6's 180 days. Each is one call; the Storage half
// of the last two is here because §5.4 keeps file deletion out of SQL.
// The three clocks that are nobody's job otherwise: §8.1's 24-hour sweep, `O7`'s 7-day export
// expiry and §11.6's 180-day purge. Each deletes its rows and queues its own file deletions in one
// transaction, so this function only reports what happened.
//
// **A failure here is raised, not counted**, which was a defect found in review. All three
// answers were read as `?? 0`, so a purge that was failing — a revoked grant, a renamed function —
// logged `purgedContent=0`, indistinguishable from a quiet day, and §11.6's 180 days would have
// overrun with nothing to notice: §12.5's eleven arms watch screening, holds, reports and jobs,
// and none of them watches retention, while §14.4's retention check is a one-off at launch rather
// than a running control. Throwing is what reaches an operator, because §12.5 alarms on a worker
// call that answers 5xx.
async function maintain() {
  const swept = await db.rpc("sweep_stale_uploads");
  // §10.2's "up to 7 days", which nothing enforced until review found that no sweep existed.
  const unsuspended = await db.rpc("clear_expired_suspensions");
  const expired = await db.rpc("expire_account_exports");
  const purged = await db.rpc("purge_retained_records");

  // The kind alone, never the message: a Postgres error text can carry the failing row (§9.8).
  const broken = [
    swept.error && "the stale upload sweep",
    expired.error && "the export expiry",
    purged.error && "the retention purge",
    unsuspended.error && "the suspension expiry",
  ].filter((name): name is string => typeof name === "string");
  if (broken.length > 0) throw new Error(`${broken.join(", ")} failed`);

  return {
    swept: swept.data?.swept ?? 0,
    unsuspended: unsuspended.data?.cleared ?? 0,
    expired: expired.data?.expired ?? 0,
    expiredFileJobs: expired.data?.file_jobs ?? 0,
    purgedContent: purged.data?.preserved_content ?? 0,
    purgedRegistrations: purged.data?.registrations ?? 0,
    purgedFileJobs: purged.data?.file_jobs ?? 0,
  };
}

// §8.1's step 4 for a photo a moderator approved rather than one screening passed. The bytes are in
// `uploads` for a photo held at screening time and in `media` for one held after it was published —
// those are the two `PUBLISH_FROM` tries, and the constant carries the reasoning for why
// `quarantine` is not among them. The published copy is written with an explicit content type,
// because §17 `O22` found that a public bucket serves an object as whatever type it carries.
async function publish(path: string) {
  for (const bucket of PUBLISH_FROM) {
    const original = await db.storage.from(bucket).download(path);
    if (original.error || !original.data) continue;

    const written = await db.storage.from(BUCKETS.media).upload(
      path,
      new Uint8Array(await original.data.arrayBuffer()),
      { contentType: PUBLISHED_CONTENT_TYPE, upsert: true },
    );
    if (written.error) throw new Error("the published copy could not be written");

    // §8.1: step 4 "deletes the original upload", and "the original is deleted only when the
    // photo **passed or was rejected**" — a staff approval is it passing. Review found the
    // original surviving in both buckets for ever after an approval, which §17.1 had already
    // flagged as this phase's gap: a held photo's original has no clock, no bucket recorded in
    // `preserved_content.file_paths` and no purge, and §8.1's 24-hour sweep covers `uploading`
    // alone. The moderation worker does the same step on the screening path
    // (`if (!held) await db.storage.from(UPLOADS_BUCKET).remove([path])`).
    //
    // **Only out of `uploads`.** The other bucket this looks in is `media`, and a file found there
    // *is* the published copy — deleting it would undo the publication this job exists to perform.
    // (`quarantine` is no longer tried at all: a file arrives there only on removal, which is
    // terminal, so no publication can name one.)
    if (bucket === BUCKETS.uploads) {
      const gone = await db.storage.from(BUCKETS.uploads).remove([path]);
      if (gone.error) throw new Error("the original could not be deleted after publishing");
    }
    return;
  }
  throw new Error("the original could not be found to publish");
}

// Measured: `remove` on a key that is not there answers `{data: [], error: null}`, so one key can
// be removed from every bucket it could sit in without a missing-object branch (§17.1).
async function removeEverywhere(paths: string[]) {
  if (paths.length === 0) return;
  for (const bucket of DELETE_FROM) {
    const removed = await db.storage.from(bucket).remove(paths);
    if (removed.error) throw new Error("a file could not be deleted");
  }
}

// Exported because the two Storage branches that tolerate a missing object turn on it, and a
// branch that swallowed a real error would be the quiet kind of failure §8.4 exists to prevent.
export async function missing(bucket: string, path: string): Promise<boolean> {
  const found = await db.storage.from(bucket).exists(path);
  return found.data === false;
}

function isPath(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

// §7.3's "Published photos appear as public URLs". Built from the project URL the platform
// injects, so §9.5 has nothing new to hold and §14 nothing new to tick.
function publicMediaBase(): string {
  const url = Deno.env.get("SUPABASE_URL");
  if (!url) throw new Error("SUPABASE_URL is not set");
  return `${url}${PUBLIC_MEDIA_PREFIX}`;
}

// The kind travels with the id, because §8.4 binds a verdict to what it is about as well as to
// when it was claimed, and the database refuses a pairing that does not match the queued message.
async function completeJob(job: Job) {
  await expectDatabase("complete_ops_job", { p_msg_id: job.msg_id, p_kind: job.kind });
}

// A refusal the database returns is this worker's bug rather than the queue's, so it raises and
// §8.4's retry has the job. NOT_FOUND is work another worker already did past the 60-second
// window, or a subject that has since gone — neither is a bug.
async function expectDatabase(fn: string, args: Record<string, unknown>) {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error("the job could not be completed");
  const answer = data as { error?: string } | null;
  if (answer?.error && answer.error !== "NOT_FOUND") {
    throw new Error("the completion was refused");
  }
}

// §7.3: the workers "check their secret key in code, since that key is not a JWT". Compared as
// bytes and in constant time, and not logged either way (§9.8).
export function authorised(authorization: string | undefined): boolean {
  const bearer = authorization?.match(/^Bearer (\S+)$/);
  if (!bearer) return false;

  const sent = new TextEncoder().encode(bearer[1]);
  const expected = new TextEncoder().encode(secretKey(SECRET_KEY_NAME));
  return sent.length === expected.length && timingSafeEqual(sent, expected);
}

app.notFound(() => fail("NOT_FOUND"));
app.onError(() => fail("INTERNAL"));

if (import.meta.main) Deno.serve(app.fetch);
