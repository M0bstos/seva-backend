import { assertEquals, assertNotEquals } from "jsr:@std/assert@1.0.19";
import { callRoute, signedIn } from "./stack.ts";

// §13.1: one end-to-end test per route in §7.3, against the stack `supabase start`
// leaves running. These prove the seam the unit tests cannot: config.toml's
// verify_jwt, the secret key, PostgREST's argument names and the shape that reaches
// a client.

Deno.test("GET /discover/health answers §12.5's two words and nothing else", async () => {
  const { status, body } = await callRoute("/discover/health");
  assertEquals(Object.keys(body), ["status"]);
  // 200 for either word: a §10.4 backlog is `degraded` without being an outage, and
  // only a database this route cannot reach is a 503 (owner decision).
  assertEquals(status, 200);
  assertEquals(body.status === "ok" || body.status === "degraded", true);
});

Deno.test("GET /discover serves a logged-out caller (§7.3, §9.1)", async () => {
  const { status, body } = await callRoute("/discover?lon=73.8567&lat=18.5204");
  assertEquals(status, 200);
  assertEquals(Array.isArray(body.activities), true);
  assertEquals("next_cursor" in body, true);
});

Deno.test("a bad coordinate is 400 and the message names it (§7.4)", async () => {
  const { status, body } = await callRoute("/discover?lon=73.8567&lat=95");
  assertEquals(status, 400);
  assertEquals(body.error, {
    code: "VALIDATION_FAILED",
    message: "lat is missing or malformed.",
    retryable: false,
  });
});

Deno.test("GET /discover/campaigns is public and pages (§7.3, §7.1)", async () => {
  const { status, body } = await callRoute("/discover/campaigns?limit=2");
  assertEquals(status, 200);
  assertEquals(Array.isArray(body.campaigns), true);
});

Deno.test("a shared link to something absent is NOT_FOUND, not an empty page", async () => {
  const absent = "3f2504e0-4f89-41d3-9a0c-0305e82c3301";
  for (const path of [`/discover/activities/${absent}`, `/discover/campaigns/${absent}`]) {
    const { status, body } = await callRoute(path);
    assertEquals(status, 404);
    assertEquals((body.error as Record<string, unknown>).code, "NOT_FOUND");
  }
});

Deno.test("a path §7.3 does not give discover still answers §7.1's shape", async () => {
  const { status, body } = await callRoute("/discover/acts");
  assertEquals(status, 404);
  assertEquals((body.error as Record<string, unknown>).code, "NOT_FOUND");
});

Deno.test("a signed-in caller reaches the same public routes (§7.3)", async () => {
  const { token } = await signedIn();
  const { status } = await callRoute("/discover?lon=73.8567&lat=18.5204", { token });
  assertEquals(status, 200);
});

Deno.test("a token that does not verify is refused, not served anonymously (§7.4)", async () => {
  const hs256 = `${btoa(JSON.stringify({ alg: "HS256", kid: "k" }))}.e30.sig`;
  const { status, body } = await callRoute("/discover?lon=73.8567&lat=18.5204", {
    token: hs256,
  });
  assertEquals(status, 401);
  assertEquals((body.error as Record<string, unknown>).code, "UNAUTHENTICATED");
});

Deno.test("the cursor is opaque and round-trips through the route (§7.1)", async () => {
  const first = await callRoute("/discover?lon=73.8567&lat=18.5204&limit=1");
  assertEquals(first.status, 200);
  // With no visible Activities nearby there is no next page, which is itself the
  // contract: a short page ends the walk.
  if (first.body.next_cursor === null) return;

  const next = await callRoute(
    `/discover?lon=73.8567&lat=18.5204&limit=1&cursor=${
      encodeURIComponent(String(first.body.next_cursor))
    }`,
  );
  assertEquals(next.status, 200);
  assertNotEquals(next.body.activities, first.body.activities);
});

// Both of these reached Postgres and raised before the limiter counted them, which
// answered a retryable 500 for a request that can never succeed and left an unbilled
// path on an anonymous route (§12.2's D5 note, §7.4).
Deno.test("a well-shaped non-day and a fractional radius are 400, not 500", async () => {
  for (const [query, field] of [["from=2026-13-45", "from"], ["radius_km=3.5", "radius_km"]]) {
    const { status, body } = await callRoute(`/discover?lon=73.8567&lat=18.5204&${query}`);
    assertEquals(status, 400, query);
    assertEquals(
      (body.error as Record<string, unknown>).message,
      `${field} is missing or malformed.`,
    );
  }
});

Deno.test("a cursor that was never issued is VALIDATION_FAILED (§7.4)", async () => {
  const { status, body } = await callRoute("/discover?lon=73.8567&lat=18.5204&cursor=nope");
  assertEquals(status, 400);
  assertEquals(
    (body.error as Record<string, unknown>).message,
    "cursor is missing or malformed.",
  );
});

// The scope note from the security review: `discover` reads a date range through the
// same shared validator, on an unauthenticated route whose counter is keyed by the
// per-address hash (§17 O26) — a worse place to lose a count than a signed-in one.
// Postgres has no year zero, so this raised 22008 before the function body ran.
Deno.test("a year Postgres has no room for is 400 here too (§7.4, §12.2)", async () => {
  const { status, body } = await callRoute("/discover?lon=73.8567&lat=18.5204&from=0000-01-01");
  assertEquals(status, 400);
  assertEquals((body.error as Record<string, unknown>).message, "from is missing or malformed.");
});

// `%00` survives query decoding as a real NUL, unlike an unpaired surrogate, so this
// path reached Postgres and raised 22P05 before the cursor could be decoded — an
// unbilled retryable 500 on the anonymous route, logging a slice of the payload.
Deno.test("a NUL in the cursor is 400 end to end (§9.8, §12.2)", async () => {
  const { status, body } = await callRoute("/discover?lon=73.8567&lat=18.5204&cursor=a%00b");
  assertEquals(status, 400);
  assertEquals((body.error as Record<string, unknown>).message, "cursor is missing or malformed.");
});
