// §9.5 gives every function its own secret key, named in SUPABASE_SECRET_KEYS. The
// name is what lives in the repo; the key itself never does.
export const SECRET_KEY_NAME = "uploads";

// §5.3's `media_purpose`. It is checked here rather than left to the cast in Postgres
// for the reason §17.1 gives the category list: a value outside the enum raises inside
// PostgREST's wrapper before the function body runs, so the limiter never counts it —
// a retryable 500 on a request that can never succeed. It lives beside this route
// rather than in `_shared/fields.ts` because this is the only route that writes it.
export const PURPOSES = ["act", "activity", "avatar"] as const;

// §8.1 step 1: "a one-time signed URL for `uploads/{user_id}/{media_id}` in the private
// bucket" — `uploads` being the bucket, and the object key what `upload_path` holds.
export const UPLOADS_BUCKET = "uploads";

// §8.1 step 3: the route "confirms the object exists and is 5 MB or smaller". The same
// number is on the bucket itself (`file_size_limit`, in the buckets migration), so this
// is the second of two checks rather than the only one — kept because §8.1 asks the
// route for it, and because a bucket limit is configuration that can be widened in a
// dashboard where this cannot.
export const MAX_UPLOAD_BYTES = 5242880;
