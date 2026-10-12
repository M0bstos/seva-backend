// §9.5 gives every function its own secret key, named in SUPABASE_SECRET_KEYS. The name is
// what lives in the repo; the key itself never does.
export const SECRET_KEY_NAME = "account";

// §5.2.1's bounds for the two columns onboarding writes, checked here so §7.4's message can
// name the field the caller got wrong — the table's own checks stay the backstop
// `onboard_account` catches, which can only say "profile" (§17.1).
export const DISPLAY_NAME_LENGTH = { min: 2, max: 50 };

// §5.2.1: "both are the policy's effective date, check ^\d{4}-\d{2}-\d{2}$ — e.g.
// '2026-10-01'". The same shape as an ISO date, and `_shared/fields.ts`'s `isIsoDate` is what
// checks it is a real day as well as a well-formed one.
export const POLICY_VERSION_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

// §7.3: "writes `exports/{user_id}/{export_id}.json` to the private `exports` bucket".
export const EXPORTS_BUCKET = "exports";

// §7.3: "the URL is signed for 1 hour".
export const SIGNED_URL_SECONDS = 3600;
