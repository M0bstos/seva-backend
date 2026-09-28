// §9.5 gives every function its own secret key, named in SUPABASE_SECRET_KEYS.
export const SECRET_KEY_NAME = "feed";

// §7.1 states the ceiling, so the route names the field for it. It states no floor,
// and `feed_acts` clamps, so `limit=0` is a page of one rather than a 400.
export const MAX_PAGE_LIMIT = 50;

// `p_radius_km` is an `int`, so a fractional value would raise on the cast before
// `feed_acts` ran — and measured, before the limiter counted it. Which rung the
// number lands on is that function's rule: `O30`'s smallest rung of 5 km is a snap
// there, not a refusal here, so 2 km answers the 5 km cell rather than a 400, and so
// does 0. What is left to refuse is what the column cannot take — a fraction, or a
// value outside int4 — which `_shared/fields.ts` owns for every route.
