// §9.5 gives every function its own secret key, named in SUPABASE_SECRET_KEYS. The
// name is what lives in the repo; the key itself never does.
export const SECRET_KEY_NAME = "reports";

// §5.3's `report_subject` and `report_reason`. Both are checked here rather than left
// to the cast in Postgres, for the reason §17.1 gives the category list: a value outside
// an enum raises inside PostgREST's wrapper before the function body runs, so the
// limiter never counts it — a retryable 500 on a request that can never succeed.
export const SUBJECT_TYPES = ["act", "activity", "profile"] as const;

export const REASONS = [
  "spam",
  "inappropriate",
  "unsafe",
  "misleading",
  "harassment",
  "intimate_imagery",
  "impersonation",
  "other",
] as const;

// §5.2.1 bounds `details` at 500 and makes it nullable, with no lower bound — so an
// empty string is a value the column stores, distinct from null, exactly as §17.1
// records for `what_to_bring`.
export const DETAILS_LENGTH = { min: 0, max: 500 };

// Which id column each `subject_type` names (§5.2.1's `reports_subject_matches_type`).
// One place, so the route cannot disagree with the table about the pairing.
export const SUBJECT_FIELDS = {
  act: "act_id",
  activity: "activity_id",
  profile: "reported_user_id",
} as const;
