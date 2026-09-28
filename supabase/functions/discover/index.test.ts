// §9.5: the client is built at module load, so the names it reads are set first.
// SEVA_RATE_LIMIT_SALT is what keys the per-address hash (§17 O26); without it the
// anonymous path throws rather than hashing with a constant.
Deno.env.set("SUPABASE_URL", "http://db.test");
Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ discover: "sb_secret_test" }));
Deno.env.set("SEVA_RATE_LIMIT_SALT", "test-salt");

const { app } = await import("./index.ts");
const { assertEquals } = await import("jsr:@std/assert@1.0.19");

const NEARBY = "lon=73.8567&lat=18.5204";

// Every request below is anonymous and stops at validation, so none reaches Postgres.
// A valid one would, which is what tests/api covers against the running stack.

Deno.test("a bad coordinate is named, because PostGIS would coerce it (§7.4)", async () => {
  for (
    const [query, field] of [
      ["lat=18.5204", "lon"],
      ["lon=73.8567", "lat"],
      ["lon=abc&lat=18.5204", "lon"],
      ["lon=73.8567&lat=95", "lat"],
      ["lon=181&lat=18.5204", "lon"],
    ]
  ) {
    const response = await app.request(`/discover?${query}`);
    assertEquals(response.status, 400);
    const body = await response.json();
    assertEquals(body.error.code, "VALIDATION_FAILED");
    assertEquals(body.error.message, `${field} is missing or malformed.`);
  }
});

Deno.test("§7.1 caps a page at 50, and the message names it", async () => {
  const over = await app.request(`/discover?${NEARBY}&limit=51`);
  assertEquals(over.status, 400);
  assertEquals((await over.json()).error.message, "limit is missing or malformed.");

  const fractional = await app.request(`/discover?${NEARBY}&limit=2.5`);
  assertEquals(fractional.status, 400);
});

Deno.test("a category outside §5.3 never reaches the cast in Postgres", async () => {
  const response = await app.request(`/discover?${NEARBY}&category=gardening`);
  assertEquals(response.status, 400);
  assertEquals((await response.json()).error.message, "category is missing or malformed.");
});

Deno.test("the date range is a date, not a timestamp (§5.1)", async () => {
  const response = await app.request(`/discover?${NEARBY}&from=2026-10-21T07:00:00%2B05:30`);
  assertEquals(response.status, 400);
  assertEquals((await response.json()).error.message, "from is missing or malformed.");
});

// A day that matches the pattern but is not a day raises on the cast to `date`, and
// measured, that raise happens before the limiter counts the request — so this is not
// only the wrong code, it is an unbilled 5xx on an anonymous route (§12.2's D5 note).
Deno.test("a date that is not a real day is 400, never 500 (§7.4)", async () => {
  for (const day of ["2026-13-45", "2026-02-30", "0000-00-00"]) {
    const response = await app.request(`/discover?${NEARBY}&from=${day}`);
    assertEquals(response.status, 400, day);
    assertEquals((await response.json()).error.message, "from is missing or malformed.");
  }
});

Deno.test("a fractional radius is 400, never 500, for the same reason", async () => {
  const response = await app.request(`/discover?${NEARBY}&radius_km=3.5`);
  assertEquals(response.status, 400);
  assertEquals((await response.json()).error.message, "radius_km is missing or malformed.");
});

Deno.test("a shared link takes a uuid (§7.3)", async () => {
  for (const path of ["/discover/activities/nope", "/discover/campaigns/nope"]) {
    const response = await app.request(path);
    assertEquals(response.status, 400);
    assertEquals((await response.json()).error.message, "id is missing or malformed.");
  }
});

Deno.test("health is matched before the id routes, and answers §12.5's two words", async () => {
  const response = await app.request("/discover/health");
  // No database here, so the check cannot reach one — which §12.5 has no third
  // answer for. What matters is that the route exists and says nothing else.
  assertEquals(response.status, 503);
  assertEquals(await response.json(), { status: "degraded" });
});

Deno.test("a token that does not verify is refused, not served anonymously (§7.4)", async () => {
  const hs256 = `${btoa(JSON.stringify({ alg: "HS256", kid: "k" }))}.e30.sig`;
  const response = await app.request(`/discover?${NEARBY}`, {
    headers: { Authorization: `Bearer ${hs256}` },
  });
  assertEquals(response.status, 401);
  assertEquals((await response.json()).error.code, "UNAUTHENTICATED");
});

// §7.1's cursor is opaque to the client, not to Postgres. `%00` survives query
// decoding as a real NUL, which raised 22P05 on the `text` parameter before
// `private.decode_cursor` could answer VALIDATION_FAILED — a retryable 500 the
// limiter never counted, on the one route that is unauthenticated and bucketed by
// the per-address hash, with a slice of the payload logged against §9.8.
Deno.test("a NUL in the cursor is 400, never 500 (§9.8, §12.2)", async () => {
  const response = await app.request(`/discover?${NEARBY}&cursor=a%00b`);
  assertEquals(response.status, 400);
  assertEquals((await response.json()).error.message, "cursor is missing or malformed.");
});

Deno.test("a path §7.3 does not give this function is a 404", async () => {
  assertEquals((await app.request("/discover/acts")).status, 404);
  assertEquals((await app.request(`/discover?${NEARBY}`, { method: "POST" })).status, 404);
});
