// §9.5 gives every function and worker its own secret key, and §7.3 has the three workers check
// theirs in code because it is not a JWT.
export const SECRET_KEY_NAME = "ops-worker";

// The same batch as the other two workers. Every job here is one or two Storage or Auth calls, so
// the bound that matters is the round trips inside Edge Functions' 2 seconds of CPU, and §8.4's
// 60-second window retries a batch that runs long rather than losing it.
export const BATCH_SIZE = 10;

// §14.1's four buckets. §11.6 moves a removed file from the public one to `quarantine`; §8.1 keeps
// an upload in `uploads` and publishes to `media`; §7.3 writes an export to `exports`.
export const BUCKETS = {
  uploads: "uploads",
  media: "media",
  quarantine: "quarantine",
  exports: "exports",
} as const;

// **Where a deletion looks.** §17.1 records the decision: `private.preserved_content.file_paths`
// carries no bucket, because one object key names the same object in whichever bucket it sits in
// and a bucket written at snapshot time can be stale — a held photo's original moves to
// `quarantine` only if the content is later removed. Measured: `remove` on a key that is not there
// answers `{data: [], error: null}`, so trying each is idempotent and cheap.
export const DELETE_FROM = [BUCKETS.uploads, BUCKETS.media, BUCKETS.quarantine] as const;

// **Where a publication looks**, corrected twice in review. A photo held at screening time still
// has its original in `uploads` (§8.1, §17.1). A photo that was published, then held, then approved
// has its bytes in `media` and nowhere else: `set_content_status` moves a file to `quarantine` only
// inside its `removed` branch — a hold moves nothing — and removal is terminal, so no
// `publish_photo` job can ever name a photo whose bytes are quarantined. `quarantine` was therefore
// describing a state the system cannot reach, while the one bucket the bytes are actually in was
// missing, and §8.3's `held → visible` row could not complete for any photo published once.
//
// `media` last, because finding it there means the published copy already exists and the copy is a
// no-op upsert — and because `publish()` deletes the original only when it came from `uploads`,
// which is what stops it deleting the very copy it just confirmed.
export const PUBLISH_FROM = [BUCKETS.uploads, BUCKETS.media] as const;

// §17 `O22`, decided during the build: the published copy is served unauthenticated from a public
// bucket with whatever content type it carries, so the type is set explicitly rather than passed
// through. The moderation worker does the same for the same reason.
export const PUBLISHED_CONTENT_TYPE = "image/jpeg";

// §7.3: "writes `exports/{user_id}/{export_id}.json`".
export const EXPORT_CONTENT_TYPE = "application/json";

// The public base §7.3's export needs for "Published photos appear as public URLs". Built from
// the project URL the platform already injects, so nothing new has to be configured.
export const PUBLIC_MEDIA_PREFIX = "/storage/v1/object/public/" + BUCKETS.media;

// §12.5 reads these lines to count. Counts and kinds only — never a path, an address or a number
// (§9.8), though §9.8 does allow an object key, which is why a failure line may name the kind.
export const LOG_LINES = {
  run: "ops-worker run",
  failed: "ops-worker job failed",
  maintenance: "ops-worker maintenance",
  // A job the database refused for a reason a retry cannot change (§5.4's staff rule).
  refused: "seva.ops.refused",
} as const;
