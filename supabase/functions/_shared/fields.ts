import {
  CATEGORIES,
  INT4,
  ISO_DATE_PATTERN,
  ISO_TIMESTAMP_PATTERN,
  LATITUDE,
  LONGITUDE,
  MAX_OFFSET_MINUTES,
  MIN_YEAR,
  NUL,
  UUID_PATTERN,
} from "./fields.constants.ts";

// Shape only. Whether the thing named exists, is yours, or is still joinable is the
// route's one Postgres function's to answer (§13.4) — it holds the row locks those
// answers depend on. What these are for is the step before that: a value that cannot
// be cast would raise inside the function, and §7.4 can only answer a raise with a
// retryable INTERNAL whose DETAIL carries the request body into the log (§9.8).

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

export function isCategory(value: unknown): value is string {
  return typeof value === "string" && (CATEGORIES as readonly string[]).includes(value);
}

// The pattern is not enough: `2026-13-45` matches it and then raises on the cast to
// `date`, which §7.4 could only answer as a retryable INTERNAL for a request that can
// never succeed. Round-tripping through Date is what tells a real day from a
// well-shaped one — measured, `2026-02-30` and `0000-00-00` both matched the pattern.
//
// And the round-trip is not enough either: `Date` works in the proleptic Gregorian
// calendar, which has a year zero, and Postgres does not — `'0000-01-01'::date`
// raises 22008, measured. So the year is bounded before the round-trip is trusted.
export function isIsoDate(value: unknown): value is string {
  if (typeof value !== "string" || !ISO_DATE_PATTERN.test(value)) return false;
  if (Number(value.slice(0, 4)) < MIN_YEAR) return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().startsWith(value);
}

// §7.1: "ISO 8601 with offset, for example `2026-10-21T07:00:00+05:30`". An offset is
// required rather than assumed, because a timestamp without one is read in the
// database's timezone and would silently move an Activity by hours.
//
// Every bound beyond that is here because `Date` accepts something `timestamptz` does
// not, and each is measured: an extended year (`+275760-09-12`) and year zero raise
// 22008, an offset past ±15:59 raises 22009, and an over-length day is rolled over by
// V8 rather than refused. A raise in Postgres would be a retryable INTERNAL the
// limiter never counted, on a request that can never succeed.
//
// Where the two engines already agree, nothing is added: `T25:00` and `T23:60` are
// refused by both, `T24:00` is accepted by both, and `T23:59:60` is refused here and
// accepted by Postgres — stricter, which costs a caller nothing.
export function isTimestamp(value: unknown): value is string {
  if (typeof value !== "string" || !ISO_TIMESTAMP_PATTERN.test(value)) return false;

  // The calendar day is checked by `isIsoDate`, on the date part alone. That is the
  // one check that has to be offset-independent: rendering the whole timestamp back
  // through `toISOString()` would move a legitimate `+05:30` or `-05:00` across
  // midnight and refuse it — measured, two of three valid inputs. Reading the date
  // part keeps it exact, and brings the year bound with it.
  //
  // It is needed because V8's lenient parser does not reject an over-length day, it
  // **rolls it over**: `2027-02-30` parses as 2027-03-02 and `2027-04-31` as
  // 2027-05-01, while Postgres raises 22008 for both — measured. An off-by-one in a
  // date picker, or a naive "last day of the month", reaches this routinely.
  if (!isIsoDate(value.slice(0, 10))) return false;

  const offset = value.match(/([+-])(\d{2}):?(\d{2})$/);
  if (offset) {
    const minutes = Number(offset[2]) * 60 + Number(offset[3]);
    if (minutes > MAX_OFFSET_MINUTES) return false;
  }
  return !Number.isNaN(Date.parse(value));
}

// PostGIS coerces an out-of-range coordinate into range and serves the request from
// the coerced point rather than raising (§17.1), so nothing downstream can refuse it.
export function isLongitude(value: unknown): value is number {
  return isFiniteNumber(value) && value >= LONGITUDE.min && value <= LONGITUDE.max;
}

export function isLatitude(value: unknown): value is number {
  return isFiniteNumber(value) && value >= LATITUDE.min && value <= LATITUDE.max;
}

// What an `int` column can take, which is not the same as what `Number.isInteger`
// accepts: 2147483648 is a whole number and still raises on the cast.
export function isInt4(value: unknown): value is number {
  return Number.isInteger(value) && (value as number) >= INT4.min &&
    (value as number) <= INT4.max;
}

export function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

export function isTextWithin(
  value: unknown,
  bounds: { min: number; max: number },
): value is string {
  return typeof value === "string" && isStorableText(value) &&
    value.length >= bounds.min && value.length <= bounds.max;
}

// Text a request may carry to Postgres at all, whatever its length. Exported as well
// as used by the two guards above, because a value can reach a `text` parameter
// without passing either — §7.1's page cursor is opaque to the *client*, not to
// Postgres, so the routes run it through this on its way past. Two characters' worth
// of rule, each measured, and each an unbilled retryable 500 before it:
//
//   * A **NUL**, which `text` cannot hold. It raises 22P05 inside PostgREST's wrapper,
//     and the error logs the slice of the request body around it — exact coordinates
//     included, against §9.8. Refusing it here is what keeps it out of that log,
//     because nothing on this side logs at all.
//   * An **unpaired surrogate**, which JSON permits and `JSON.parse`/`stringify` carry
//     through untouched. PostgREST refuses the payload itself with `PGRST102 "Empty or
//     invalid json"` and never calls Postgres, so unlike the NUL there is no §9.8
//     exposure — but the route could only answer it as INTERNAL, and the limiter never
//     counted it (§12.2's D5 note).
export function isStorableText(value: string): boolean {
  return value.isWellFormed() && !value.includes(NUL);
}

// A flat map of finite numbers, which is what `act_metrics` takes: `metric` is an
// enum and `value` is `numeric` (§5.2.1). Flat matters twice over — a nested object
// reaches `requestHash`, whose recursion overflows the stack past a few thousand
// levels (measured), before any database call is made, and a key Postgres cannot
// store raises before it too — a NUL with the same §9.8 exposure as any other text.
export function isFlatNumberMap(value: unknown): boolean {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  return Object.entries(value).every(([key, entry]) =>
    isStorableText(key) && isFiniteNumber(entry)
  );
}

// The first shape a create has to pass: a JSON object. An array, a bare string and a
// body that does not parse are all VALIDATION_FAILED rather than a raise inside the
// handler, which Hono would answer as a 500 (§7.4).
export async function readJsonObject(request: Request): Promise<Record<string, unknown> | null> {
  try {
    const body = await request.json();
    return body !== null && typeof body === "object" && !Array.isArray(body)
      ? body as Record<string, unknown>
      : null;
  } catch {
    return null;
  }
}
