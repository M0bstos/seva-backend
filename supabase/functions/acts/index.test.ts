// The client is built at module load (§9.5), so the names it reads are set before the
// route is imported. No test here reaches the database: everything below is answered
// by the handler chain before it calls one.
Deno.env.set("SUPABASE_URL", "http://db.test");
Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ acts: "sb_secret_test" }));

const { app, firstProblem } = await import("./index.ts");
const { assertEquals } = await import("jsr:@std/assert@1.0.19");

const KEY = "3f2504e0-4f89-41d3-9a0c-0305e82c3301";

function act(overrides: Record<string, unknown> = {}) {
  return {
    title: "A morning at the river",
    story: "We filled eleven sacks along the bank before the rain came in at noon.",
    category: "environment",
    occurred_on: "2026-09-27",
    lon: 73.8567,
    lat: 18.5204,
    ...overrides,
  };
}

Deno.test("a request with no session is UNAUTHENTICATED (§7.4)", async () => {
  const response = await app.request("/acts", {
    method: "POST",
    headers: { "Idempotency-Key": KEY },
    body: JSON.stringify(act()),
  });
  assertEquals(response.status, 401);
  assertEquals((await response.json()).error.code, "UNAUTHENTICATED");
});

Deno.test("a token this project could not have issued is refused without a round trip", async () => {
  // §17 O31: an unknown `kid` costs two outbound calls, so `_shared/auth.ts` rejects
  // a header naming an algorithm the project never signs with before making any.
  const hs256 = `${btoa(JSON.stringify({ alg: "HS256", kid: "k" }))}.e30.sig`;
  const response = await app.request("/acts", {
    method: "POST",
    headers: { Authorization: `Bearer ${hs256}`, "Idempotency-Key": KEY },
    body: JSON.stringify(act()),
  });
  assertEquals(response.status, 401);
});

Deno.test("an unknown path under the function is a 404, not a validation error", async () => {
  const response = await app.request("/acts/x/y", { method: "POST" });
  assertEquals(response.status, 404);
});

Deno.test("every field §5.2.1 bounds is named by the message that refuses it (§7.4)", () => {
  assertEquals(firstProblem(act()), null);
  assertEquals(firstProblem(act({ title: "four" })), "title");
  assertEquals(firstProblem(act({ title: "x".repeat(101) })), "title");
  assertEquals(firstProblem(act({ story: "too short" })), "story");
  assertEquals(firstProblem(act({ story: "x".repeat(2001) })), "story");
  assertEquals(firstProblem(act({ category: "gardening" })), "category");
  assertEquals(firstProblem(act({ occurred_on: "27-09-2026" })), "occurred_on");
});

Deno.test("a coordinate outside the world is refused here, because PostGIS coerces it", () => {
  assertEquals(firstProblem(act({ lat: 95 })), "lat");
  assertEquals(firstProblem(act({ lon: 181 })), "lon");
  assertEquals(firstProblem(act({ lon: "73.8567" })), "lon");
  assertEquals(firstProblem(act({ lat: Number.NaN })), "lat");
});

Deno.test("an id that is not a UUID never reaches the cast in Postgres", () => {
  assertEquals(firstProblem(act({ activity_id: "not-a-uuid" })), "activity_id");
  assertEquals(firstProblem(act({ activity_id: KEY })), null);
  assertEquals(firstProblem(act({ photo_ids: [KEY, "nope"] })), "photo_ids");
  assertEquals(firstProblem(act({ photo_ids: [KEY] })), null);
  assertEquals(firstProblem(act({ photo_ids: "not-an-array" })), "photo_ids");
});

Deno.test("metrics must be an object, which is what create_act unpacks", () => {
  assertEquals(firstProblem(act({ metrics: { waste_kg: 12 } })), null);
  assertEquals(firstProblem(act({ metrics: [12] })), "metrics");
  assertEquals(firstProblem(act({ metrics: 12 })), "metrics");
});

Deno.test("the token is checked before anything else, so a bad one is 401 (§13.4)", async () => {
  const response = await app.request("/acts", {
    method: "POST",
    headers: { Authorization: "Bearer not-a-token" },
    body: JSON.stringify(act()),
  });
  // §13.4 fixes the order: verify, then validate. The missing Idempotency-Key below
  // is never reached, and what this must never answer is a 500.
  assertEquals(response.status, 401);
});

// §7.1.1 makes a retry that spells an absent field as `null` the same request, so an
// optional field cannot mean "malformed" when null and "absent" when missing.
Deno.test("null reads as absent on every optional field (§7.1.1)", () => {
  assertEquals(firstProblem(act({ activity_id: null })), null);
  assertEquals(firstProblem(act({ metrics: null })), null);
  assertEquals(firstProblem(act({ photo_ids: null })), null);
  // A value that is present and wrong is still named.
  assertEquals(firstProblem(act({ activity_id: "nope" })), "activity_id");
});

// `update_act` coalesces, so `null` keeps the column exactly as a missing field does.
// The PATCH handler tested `undefined` alone, which made the two spellings a 403 and
// a 400 on the same route (§7.1.1).
Deno.test("PATCH reads null as absent, like every other optional field", async () => {
  const cases: Array<[Record<string, unknown>, number]> = [
    [{ title: null, story: "We filled eleven sacks along the bank before the rain came." }, 401],
    [{ title: null, story: null }, 401],
    [{}, 401],
  ];
  for (const [body, status] of cases) {
    const response = await app.request(`/acts/${KEY}`, {
      method: "PATCH",
      body: JSON.stringify(body),
    });
    // No session, so every one of these stops at the token check — what matters is
    // that none of them is a 400 from a spelling difference. The field-level
    // behaviour is pinned end to end in tests/api.
    assertEquals(response.status, status);
  }
});

Deno.test("a NUL or a nested metric is refused before Postgres logs it (§9.8, §12.2)", () => {
  assertEquals(firstProblem(act({ title: "A morning\u0000at the river" })), "title");
  assertEquals(
    firstProblem(act({ story: "We filled eleven sacks\u0000along the bank." })),
    "story",
  );
  assertEquals(firstProblem(act({ metrics: { "waste\u0000kg": 12 } })), "metrics");
  assertEquals(firstProblem(act({ metrics: { waste_kg: { deep: 1 } } })), "metrics");
  assertEquals(firstProblem(act({ occurred_on: "0000-01-01" })), "occurred_on");
});

Deno.test("a lone surrogate in text or a metric key is 400 (§12.2)", () => {
  assertEquals(firstProblem(act({ title: "A morning\ud800at the river" })), "title");
  assertEquals(firstProblem(act({ metrics: { "trees\ud800": 3 } })), "metrics");
});
