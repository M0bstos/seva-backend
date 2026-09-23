import { assertEquals } from "jsr:@std/assert@1.0.19";
import { fail } from "./errors.ts";
import { ERRORS } from "./errors.constants.ts";

// §7.4, copied from the spec so a changed status fails here rather than in a client.
const SPEC: Array<[string, number, boolean]> = [
  ["VALIDATION_FAILED", 400, false],
  ["UNAUTHENTICATED", 401, false],
  ["ONBOARDING_REQUIRED", 403, false],
  ["AGE_RESTRICTED", 403, false],
  ["FORBIDDEN", 403, false],
  ["NOT_FOUND", 404, false],
  ["ACTIVITY_FULL", 409, false],
  ["ACTIVITY_NOT_JOINABLE", 409, false],
  ["IDEMPOTENCY_KEY_REUSED", 422, false],
  ["EVIDENCE_REQUIRED", 422, false],
  ["METRIC_OUT_OF_RANGE", 422, false],
  ["DAILY_LIMIT_REACHED", 429, true],
  ["RATE_LIMITED", 429, true],
  ["FEATURE_DISABLED", 503, true],
  ["INTERNAL", 500, true],
];

// The overloads make each code's extra argument mandatory or forbidden, which is the
// point of them; this one widened alias drives all fifteen through a single door.
const anyCode = fail as (code: string, detail?: string | number) => Response;

Deno.test("§7.4's table is the table: every code, its status, and nothing else", () => {
  assertEquals(Object.keys(ERRORS), SPEC.map(([code]) => code));
});

Deno.test("every code answers in §7.1's shape with the status §7.4 gives it", async () => {
  for (const [code, status, retryable] of SPEC) {
    const response = anyCode(code, code === "VALIDATION_FAILED" ? "title" : undefined);
    assertEquals(response.status, status, code);
    const body = await response.json();
    assertEquals(Object.keys(body), ["error"]);
    assertEquals(Object.keys(body.error).sort(), ["code", "message", "retryable"]);
    assertEquals(body.error.code, code);
    assertEquals(body.error.retryable, retryable, code);
    assertEquals(typeof body.error.message, "string");
  }
});

Deno.test("both 429s carry Retry-After in whole seconds, and no other code does", () => {
  assertEquals(fail("RATE_LIMITED", 12.1).headers.get("Retry-After"), "13");
  assertEquals(fail("DAILY_LIMIT_REACHED", 3600).headers.get("Retry-After"), "3600");
  for (const [code, status] of SPEC) {
    if (status === 429) continue;
    assertEquals(anyCode(code, "x").headers.get("Retry-After"), null, code);
  }
});

// A window that has already closed can compute a remainder of zero or less; a header
// of "-30" is malformed, so the floor is one second.
Deno.test("a window that has already closed still gives the client a usable delay", () => {
  assertEquals(fail("RATE_LIMITED", 0).headers.get("Retry-After"), "1");
  assertEquals(fail("RATE_LIMITED", -30).headers.get("Retry-After"), "1");
});

Deno.test("a validation failure names the field, per §7.4", async () => {
  const body = await fail("VALIDATION_FAILED", "title").json();
  assertEquals(body.error.message, "title is missing or malformed.");
});

// The overloads are the first guard. This is the second: the runtime keys off the
// code, so even a widened call cannot put a caller's string in front of a client —
// which is what keeps §9.8 data out of a response body if the types ever loosen.
Deno.test("no other code will echo a caller-supplied message", async () => {
  for (const [code] of SPEC) {
    if (code === "VALIDATION_FAILED") continue;
    const body = await anyCode(code, "duplicate key value violates profiles_phone_key").json();
    assertEquals(body.error.message, ERRORS[code as keyof typeof ERRORS].message, code);
  }
});

Deno.test("and no other code will take a Retry-After from one either", () => {
  for (const [code, status] of SPEC) {
    if (status === 429) continue;
    assertEquals(anyCode(code, 30).headers.get("Retry-After"), null, code);
  }
});
