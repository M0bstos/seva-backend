// §9.5 gives every function and worker its own secret key. For a worker that key is
// also the inbound shared secret, because §7.3 has the three workers "check their
// secret key in code, since that key is not a JWT".
export const SECRET_KEY_NAME = "moderation-worker";

// §8.4 holds a Rekognition job for 60 seconds and retries five times, so a batch that
// runs long is retried rather than lost. Ten is what fits: the metadata strip of a
// 5 MB file costs about 2.8 ms of CPU (measured, §16 week 1's spike), so the cost is
// the AWS round trips, and §8.4 caps Rekognition at 5 requests a second in Mumbai.
export const BATCH_SIZE = 10;

// §8.4: "Starting photo threshold: hold at 80% confidence or above in the
// high-severity categories (explicit content, violence, visually disturbing, hate
// symbols). Tune this on real uploads during the closed beta."
export const HOLD_AT_CONFIDENCE = 80;

// The four §8.4 names, as Rekognition's taxonomy version 7 spells its top-level
// categories. No second- or third-level label shares one of these names, so matching
// the label's own name is exact; reading `ParentName` would miss, because a level-3
// label's parent is its level-2 one rather than the category.
export const HIGH_SEVERITY_CATEGORIES = [
  "Explicit",
  "Violence",
  "Visually Disturbing",
  "Hate Symbols",
] as const;

// Below §8.4's hold threshold on purpose. The near-misses are what the closed beta
// tunes the threshold against, and `media_labels` is where they are kept (`O21`).
export const LABEL_FLOOR_CONFIDENCE = 50;

export const UPLOADS_BUCKET = "uploads";
export const MEDIA_BUCKET = "media";

// §17 `O22`: the `media` bucket is public and carries no mime allow-list, so an object
// is served unauthenticated with whatever content type it has. Set explicitly rather
// than passed through, because an object served as `text/html` or `image/svg+xml` from
// a public origin is stored XSS on the project's own domain.
export const PUBLISHED_CONTENT_TYPE = "image/jpeg";

export const AWS_REGION_VARIABLE = "AWS_REGION";
export const GUARDRAIL_ID_VARIABLE = "SEVA_GUARDRAIL_ID";
export const GUARDRAIL_VERSION_VARIABLE = "SEVA_GUARDRAIL_VERSION";

// §12.5 reads the log drain (`D12`). One line per run, carrying counts and no
// identifier: §9.8 keeps content out, and a backlog is a count. The per-job failure
// line names the kind and nothing else, for the same reason.
export const LOG_LINES = {
  run: "moderation-worker: run",
  failed: "moderation-worker: job failed",
} as const;
