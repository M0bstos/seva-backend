import { assertEquals } from "jsr:@std/assert@1.0.19";
import {
  isCategory,
  isFlatNumberMap,
  isInt4,
  isIsoDate,
  isLatitude,
  isLongitude,
  isTextWithin,
  isTimestamp,
  isUuid,
} from "./fields.ts";

Deno.test("a uuid is what every id column takes (§5.2.1)", () => {
  assertEquals(isUuid("3f2504e0-4f89-41d3-9a0c-0305e82c3301"), true);
  assertEquals(isUuid("3F2504E0-4F89-41D3-9A0C-0305E82C3301"), true);
  assertEquals(isUuid("3f2504e0-4f89-41d3-9a0c-0305e82c330"), false);
  assertEquals(isUuid("3f2504e04f8941d39a0c0305e82c3301"), false);
  assertEquals(isUuid(""), false);
  assertEquals(isUuid(null), false);
});

Deno.test("the category list is §5.3's, exactly", () => {
  for (const value of ["environment", "animals", "community", "education", "health", "other"]) {
    assertEquals(isCategory(value), true);
  }
  assertEquals(isCategory("gardening"), false);
  assertEquals(isCategory("Environment"), false);
  assertEquals(isCategory(1), false);
});

Deno.test("a timestamp carries its offset (§7.1)", () => {
  assertEquals(isTimestamp("2026-10-21T07:00:00+05:30"), true);
  assertEquals(isTimestamp("2026-10-21T01:30:00Z"), true);
  assertEquals(isTimestamp("2026-10-21T01:30:00+0530"), true);
  // Without one, Postgres reads it in the database's timezone and the event moves.
  assertEquals(isTimestamp("2026-10-21T07:00:00"), false);
  assertEquals(isTimestamp("2026-10-21"), false);
  assertEquals(isTimestamp("not a time"), false);
});

Deno.test("a date is a date, not a timestamp (§5.2.1)", () => {
  assertEquals(isIsoDate("2026-09-27"), true);
  assertEquals(isIsoDate("2028-02-29"), true, "2028 is a leap year, so this day exists");
  assertEquals(isIsoDate("2026-02-29"), false, "2026 is not, so this one does not");
  assertEquals(isIsoDate("2026-09-27T07:00:00+05:30"), false);
  assertEquals(isIsoDate("27-09-2026"), false);
});

// A well-shaped non-day raises on the cast to `date`, which §7.4 could only answer as
// a retryable INTERNAL — and measured, the raise beats the limiter to it.
Deno.test("a day that does not exist is not a date (§7.4)", () => {
  for (const day of ["2026-13-45", "2026-02-30", "0000-00-00", "2026-00-10", "2026-01-32"]) {
    assertEquals(isIsoDate(day), false, day);
  }
});

Deno.test("coordinates are refused here, because PostGIS coerces them (§17.1)", () => {
  assertEquals(isLongitude(73.8567), true);
  assertEquals(isLatitude(18.5204), true);
  assertEquals(isLongitude(181), false);
  assertEquals(isLatitude(95), false);
  assertEquals(isLongitude(Number.NaN), false);
  assertEquals(isLatitude(Number.POSITIVE_INFINITY), false);
  assertEquals(isLongitude("73.8567"), false);
});

Deno.test("text is measured against the bounds its own table checks (§5.2.1)", () => {
  assertEquals(isTextWithin("a morning", { min: 5, max: 100 }), true);
  assertEquals(isTextWithin("four", { min: 5, max: 100 }), false);
  assertEquals(isTextWithin("x".repeat(101), { min: 5, max: 100 }), false);
  assertEquals(isTextWithin(12, { min: 5, max: 100 }), false);
});

// An `int` column is int4, and a whole number outside it is uncastable: measured, the
// raise happens in PostgREST's wrapper before the limiter counts the request, so a
// route that let one through would hand an anonymous caller an unbilled 5xx (§12.2).
Deno.test("an int column takes int4 and not every whole number (§7.4)", () => {
  assertEquals(isInt4(50), true);
  assertEquals(isInt4(0), true);
  assertEquals(isInt4(-5), true);
  assertEquals(isInt4(2147483647), true);
  assertEquals(isInt4(-2147483648), true);
  assertEquals(isInt4(2147483648), false);
  assertEquals(isInt4(-2147483649), false);
  assertEquals(isInt4(3.5), false);
  assertEquals(isInt4("50"), false);
  assertEquals(isInt4(Number.NaN), false);
});

// A NUL raises 22P05 inside PostgREST's wrapper, which logs the slice of the request
// body around it — coordinates and all, against §9.8 — and never reaches the function
// body, so the limiter never counts it either. Refused here, where nothing logs.
// An unpaired surrogate is legal JSON and survives parse and stringify untouched, so
// it reached PostgREST, which refused the payload itself — `PGRST102`, no Postgres call
// and so no §9.8 exposure, but a retryable 500 the limiter never counted (§12.2).
Deno.test("text Postgres cannot store is refused: a lone surrogate (§12.2)", () => {
  assertEquals(isTextWithin("Dadar\ud800beach", { min: 3, max: 200 }), false);
  assertEquals(isTextWithin("\ud800", { min: 0, max: 200 }), false);
  // A proper pair is ordinary text and stays welcome.
  assertEquals(isTextWithin("a rocket \u{1F680} launch", { min: 3, max: 200 }), true);
});

Deno.test("text carrying a NUL is refused however long it is (§9.8)", () => {
  assertEquals(isTextWithin("Dadar beach", { min: 3, max: 200 }), true);
  assertEquals(isTextWithin("Dadar\u0000beach", { min: 3, max: 200 }), false);
  assertEquals(isTextWithin("\u0000", { min: 0, max: 200 }), false);
});

// Postgres has no year zero and `timestamptz` takes ±15:59; `Date` has both and more,
// so a round-trip through it cannot catch either. Each of these raised before the
// function body ran, unbilled (§12.2's D5 note).
Deno.test("a year Postgres has no room for is not a date (§7.4)", () => {
  assertEquals(isIsoDate("0001-01-01"), true);
  assertEquals(isIsoDate("0000-01-01"), false);
});

// V8's lenient parser rolls an over-length day forward instead of refusing it, so
// `Date.parse` alone cannot see this; Postgres raises 22008. `isIsoDate` had the
// calendar check all along, and `isTimestamp` now runs it on the date part.
Deno.test("a calendar day that does not exist is not a timestamp (§7.4)", () => {
  assertEquals(isTimestamp("2027-02-30T07:00:00Z"), false, "rolls to 03-02 in V8");
  assertEquals(isTimestamp("2027-04-31T07:00:00Z"), false, "rolls to 05-01");
  assertEquals(isTimestamp("2028-02-29T07:00:00Z"), true, "2028 is a leap year");
  assertEquals(isTimestamp("2027-02-29T07:00:00Z"), false, "2027 is not");
});

// The trap in the obvious fix: rendering the whole timestamp through toISOString()
// moves a legitimate offset across midnight and refuses it. Reading the date part
// alone is offset-independent.
Deno.test("an offset that crosses midnight is still valid (§7.1)", () => {
  assertEquals(isTimestamp("2027-10-21T02:00:00+05:30"), true, "UTC 10-20T20:30");
  assertEquals(isTimestamp("2027-10-21T23:00:00-05:00"), true, "UTC 10-22T04:00");
});

Deno.test("a timestamp is bounded by what timestamptz takes, not by what Date parses", () => {
  assertEquals(isTimestamp("2026-10-21T07:00:00+05:30"), true);
  assertEquals(isTimestamp("2026-10-21T07:00:00+15:59"), true, "the widest offset it takes");
  assertEquals(isTimestamp("2026-10-21T07:00:00+16:00"), false, "one minute past it: 22009");
  assertEquals(isTimestamp("2026-10-21T07:00:00+18:00"), false, "a plausible client bug");
  assertEquals(isTimestamp("2026-10-21T07:00:00-18:00"), false);
  assertEquals(isTimestamp("0000-01-01T00:00:00Z"), false, "no year zero: 22008");
  assertEquals(isTimestamp("+275760-09-12T00:00:00Z"), false, "an extended year: 22009");
});

// `metrics` is the only nested-object field either create route takes, and
// `requestHash` recurses once per level — measured, it overflows the stack somewhere
// between 1,000 and 5,000 levels, before any database call is made. A flat map of
// numbers is what `act_metrics` holds anyway (§5.2.1).
Deno.test("metrics is a flat map of finite numbers (§5.2.1, §12.2)", () => {
  assertEquals(isFlatNumberMap({ waste_kg: 12, trees_planted: 3 }), true);
  assertEquals(isFlatNumberMap({}), true);
  assertEquals(isFlatNumberMap({ waste_kg: { nested: 1 } }), false);
  assertEquals(isFlatNumberMap({ waste_kg: "12" }), false);
  assertEquals(isFlatNumberMap({ waste_kg: Number.NaN }), false);
  assertEquals(isFlatNumberMap({ "waste\u0000kg": 12 }), false, "a NUL in a key logs too");
  assertEquals(isFlatNumberMap({ "trees\ud800": 3 }), false, "and a lone surrogate");
  assertEquals(isFlatNumberMap([1, 2]), false);
  assertEquals(isFlatNumberMap(null), false);

  let deep: Record<string, unknown> = { waste_kg: 1 };
  for (let i = 0; i < 6000; i++) deep = { nested: deep };
  assertEquals(isFlatNumberMap(deep), false, "and nothing deep reaches requestHash");
});
