// §9.5 gives every function its own secret key, named in SUPABASE_SECRET_KEYS. The
// name is what lives in the repo; the key itself never does.
export const SECRET_KEY_NAME = "acts";

// §5.2.1's bounds for the two columns this route writes. They are checked in the
// route so §7.4's message can name the field the caller got wrong; the table's own
// checks stay as the backstop create_act catches, which can only say "act" (§17.1).
// Shapes every route shares — the category list, a uuid, a coordinate — are in
// `_shared/fields.ts`.
export const TITLE_LENGTH = { min: 5, max: 100 };
export const STORY_LENGTH = { min: 20, max: 2000 };
