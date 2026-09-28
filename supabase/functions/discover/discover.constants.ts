// §9.5 gives every function its own secret key, named in SUPABASE_SECRET_KEYS.
export const SECRET_KEY_NAME = "discover";

// §12.5 fixes the two bodies and "nothing else — never details". Which status code
// carries `degraded` depends on why: 503 when the database is unreachable, 200 when
// §10.4 has a backlog, so Route 53's availability check and the backlog alarm stop
// being one signal (owner decision, 28 September 2026). The 30-second cache behind
// them is inside `health_status()`, because §9.4 exposes only `public` to the Data
// API and the cache table is in `private`.
export const HEALTH_OK = { status: "ok" };
export const HEALTH_DEGRADED = { status: "degraded" };

// §7.1: "Pagination … Functions: an opaque `cursor`, `limit` ≤ 50". The ceiling is
// checked here so §7.4's message can name the field — §7.1 states that rule, so it is
// the route's to enforce. There is no floor: §7.1 gives none, and both functions
// clamp with `least(greatest(…, 1), 50)`, so `limit=0` is a page of one rather than a
// 400. A rule the function owns is not re-implemented here (§17.1).
export const MAX_PAGE_LIMIT = 50;

// The radius carries no bound of its own here, only the column's. §7.3 snaps it to
// its ladder inside the Postgres function — zero and negatives included, both landing
// on the smallest rung — and §17.1 keeps every rule but a shape there. What the route
// refuses is what `p_radius_km int` cannot take: a fractional value, or one outside
// int4. Measured, both raise in PostgREST's wrapper before the limiter counts them —
// an unbilled 5xx on an anonymous route, which §12.2's D5 note refuses.
