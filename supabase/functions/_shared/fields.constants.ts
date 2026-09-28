// The shapes §5.2.1 and §5.3 fix for values that arrive in a request. They live here
// rather than beside one route because `acts`, `activities`, `discover` and `feed`
// all take them, and the category list in particular has to match §5.3 exactly in one
// place: a value outside it reaches a cast in Postgres and raises, which §7.4 could
// only answer as a retryable INTERNAL for a request that can never succeed.
//
// Each route keeps its own §5.2.1 bounds — a title's length, a capacity's range — in
// its own constants file, because those belong to the table that route writes.
export const CATEGORIES = [
  "environment",
  "animals",
  "community",
  "education",
  "health",
  "other",
] as const;

export const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// An ISO calendar date, which is what a `date` column takes (§5.2.1). §7.1 puts
// timestamps in ISO 8601 with an offset; a date carries none.
export const ISO_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

// §7.1's "ISO 8601 with offset", with a four-digit year and an offset of its own, so
// nothing wider than `timestamptz` can be spelled. ECMAScript's extended years
// (`+275760-09-12`) and its ±23:59 offsets are both wider than Postgres accepts.
export const ISO_TIMESTAMP_PATTERN =
  /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d{1,6})?)?(Z|[+-]\d{2}:?\d{2})$/;

// Postgres has no year zero: `'0000-01-01'::date` raises 22008, measured, while
// `'0001-01-01'` is fine. `Date` has one, so a round-trip through it cannot catch this.
export const MIN_YEAR = 1;

// `timestamptz` takes ±15:59 and no more: `'…+15:59'::timestamptz` is fine and
// `'…+16:00'` raises 22009, measured.
export const MAX_OFFSET_MINUTES = 15 * 60 + 59;

// The one character Postgres `text` cannot hold. A NUL reaching PostgREST raises
// 22P05 *and* puts a slice of the request body in the Postgres log, coordinates and
// all (§9.8) — so it is refused here, where nothing is logged, rather than there.
export const NUL = "\u0000";

export const LONGITUDE = { min: -180, max: 180 };
export const LATITUDE = { min: -90, max: 90 };

// `int` in Postgres is int4, and every one of these columns is one. A value outside
// the range is well-shaped and still uncastable: it raises inside PostgREST's wrapper
// before the function body runs, so the limiter never counts it — measured, an
// unbilled retryable 500 on routes §7.3 gives to "Anyone".
export const INT4 = { min: -2147483648, max: 2147483647 };
