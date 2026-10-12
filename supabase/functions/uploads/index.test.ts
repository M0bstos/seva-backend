// The client is built at module load (§9.5), so the names it reads are set before the
// route is imported. No test here reaches the database or Storage: everything below is
// answered by the handler chain before it calls either.
Deno.env.set("SUPABASE_URL", "http://db.test");
Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ uploads: "sb_secret_test" }));

const { app, isPurpose } = await import("./index.ts");
const { assertEquals } = await import("jsr:@std/assert@1.0.19");

const MEDIA_ID = "3f2504e0-4f89-41d3-9a0c-0305e82c3301";

Deno.test("a request with no session is UNAUTHENTICATED (§7.4)", async () => {
  const response = await app.request("/uploads", {
    method: "POST",
    body: JSON.stringify({ purpose: "act" }),
  });
  assertEquals(response.status, 401);
  assertEquals((await response.json()).error.code, "UNAUTHENTICATED");
});

Deno.test("so is a completion with no session, before the id is even read", async () => {
  const response = await app.request(`/uploads/${MEDIA_ID}/complete`, { method: "POST" });
  assertEquals(response.status, 401);
});

Deno.test("a token this project could not have issued is refused without a round trip", async () => {
  // §17 O31: an unknown `kid` costs two outbound calls, so `_shared/auth.ts` rejects a
  // header naming an algorithm the project never signs with before making any.
  const hs256 = `${btoa(JSON.stringify({ alg: "HS256", kid: "k" }))}.e30.sig`;
  const response = await app.request("/uploads", {
    method: "POST",
    headers: { Authorization: `Bearer ${hs256}` },
    body: JSON.stringify({ purpose: "act" }),
  });
  assertEquals(response.status, 401);
});

Deno.test("the token is checked before the body, so a bad one is 401 and never 500", async () => {
  const response = await app.request("/uploads", {
    method: "POST",
    headers: { Authorization: "Bearer not-a-token" },
    body: "not json at all",
  });
  assertEquals(response.status, 401);
});

Deno.test("an unknown path under the function is a 404 in §7.1's shape", async () => {
  const response = await app.request("/uploads/x/y/z", { method: "POST" });
  assertEquals(response.status, 404);
  assertEquals((await response.json()).error.code, "NOT_FOUND");
});

Deno.test("a preflight is answered for an allowed origin and not for another (§17 O37)", async () => {
  Deno.env.set("SEVA_ALLOWED_ORIGINS", "https://seva.example");

  const allowed = await app.request("/uploads", {
    method: "OPTIONS",
    headers: { Origin: "https://seva.example", "Access-Control-Request-Method": "POST" },
  });
  assertEquals(allowed.headers.get("access-control-allow-origin"), "https://seva.example");

  const other = await app.request("/uploads", {
    method: "OPTIONS",
    headers: { Origin: "https://elsewhere.example", "Access-Control-Request-Method": "POST" },
  });
  assertEquals(other.headers.get("access-control-allow-origin"), null);

  Deno.env.delete("SEVA_ALLOWED_ORIGINS");
});

// §5.3's media_purpose, checked in the route because a value outside the enum raises
// inside PostgREST's wrapper before the function body runs — unbilled, and a retryable
// 500 on a request that can never succeed (§12.2's D5 note, §17.1). Tested as the pure
// function it is: through the chain, §13.4's token step answers first, so a request
// could never show which field was refused.
Deno.test("the purpose must be one of §5.3's three (§5.3, §7.4)", () => {
  assertEquals(isPurpose("act"), true);
  assertEquals(isPurpose("activity"), true);
  assertEquals(isPurpose("avatar"), true);

  assertEquals(isPurpose("banner"), false);
  assertEquals(isPurpose("ACT"), false);
  assertEquals(isPurpose(""), false);
  assertEquals(isPurpose(7), false);
  assertEquals(isPurpose(null), false);
  assertEquals(isPurpose(undefined), false);
  assertEquals(isPurpose(["act"]), false);
});

Deno.test("GET is not a method either route serves (§7.3)", async () => {
  assertEquals((await app.request("/uploads")).status, 404);
  assertEquals((await app.request(`/uploads/${MEDIA_ID}/complete`)).status, 404);
});
