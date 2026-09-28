// §9.5 gives every function its own secret key, named in SUPABASE_SECRET_KEYS.
export const SECRET_KEY_NAME = "activities";

// §5.2.1's bounds for the columns this route writes, checked here so §7.4's message
// can name the field; the table's own checks stay as the backstop create_activity
// catches, which can only say "activity" (§17.1). Shapes every route shares are in
// `_shared/fields.ts`.
export const TITLE_LENGTH = { min: 5, max: 100 };
export const DESCRIPTION_LENGTH = { min: 20, max: 2000 };
export const LOCATION_LABEL_LENGTH = { min: 3, max: 200 };
export const WHAT_TO_BRING_LENGTH = { min: 0, max: 500 };
export const CAPACITY = { min: 1, max: 1000 };

// §5.2.1: `ends_at > starts_at` and `ends_at <= starts_at + interval '24 hours'`.
export const MAX_HOURS = 24;
