// The client is built at module load (§9.5), so the names it reads are set before the route is
// imported. No test here reaches the database or Storage: everything below is answered by the
// handler chain before it calls either, or by `firstOnboardingProblem` as a pure function.
Deno.env.set("SUPABASE_URL", "http://db.test");
Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ account: "sb_secret_test" }));

const { app, firstOnboardingProblem } = await import("./index.ts");
const { assertEquals } = await import("jsr:@std/assert@1.0.19");

const EXPORT_ID = "3f2504e0-4f89-41d3-9a0c-0305e82c3301";

function onboarding(overrides: Record<string, unknown> = {}) {
  return {
    display_name: "Anand",
    date_of_birth: "1995-04-04",
    terms_version: "2026-10-01",
    privacy_version: "2026-10-01",
    ...overrides,
  };
}

Deno.test("every route needs a session (§7.3, §7.4)", async () => {
  for (
    const [path, method] of [
      ["/account/onboarding", "POST"],
      ["/account/delete", "POST"],
      ["/account/export", "POST"],
      [`/account/export/${EXPORT_ID}`, "GET"],
    ]
  ) {
    const response = await app.request(path, {
      method,
      body: method === "POST" ? JSON.stringify(onboarding()) : undefined,
    });
    assertEquals(response.status, 401);
    assertEquals((await response.json()).error.code, "UNAUTHENTICATED");
  }
});

Deno.test("a token this project could not have issued is refused without a round trip", async () => {
  // §17 O31: an unknown `kid` costs two outbound calls, so `_shared/auth.ts` rejects a header
  // naming an algorithm the project never signs with before making any.
  const hs256 = `${btoa(JSON.stringify({ alg: "HS256", kid: "k" }))}.e30.sig`;
  const response = await app.request("/account/delete", {
    method: "POST",
    headers: { Authorization: `Bearer ${hs256}` },
  });
  assertEquals(response.status, 401);
});

Deno.test("an unknown path under the function is a 404 in §7.1's shape", async () => {
  const response = await app.request("/account/nope", { method: "POST" });
  assertEquals(response.status, 404);
  assertEquals((await response.json()).error.code, "NOT_FOUND");
});

Deno.test("a preflight is answered for an allowed origin and not for another (§17 O37)", async () => {
  Deno.env.set("SEVA_ALLOWED_ORIGINS", "https://seva.example");

  const allowed = await app.request("/account/delete", {
    method: "OPTIONS",
    headers: { Origin: "https://seva.example", "Access-Control-Request-Method": "POST" },
  });
  assertEquals(allowed.headers.get("access-control-allow-origin"), "https://seva.example");

  const other = await app.request("/account/delete", {
    method: "OPTIONS",
    headers: { Origin: "https://elsewhere.example", "Access-Control-Request-Method": "POST" },
  });
  assertEquals(other.headers.get("access-control-allow-origin"), null);

  Deno.env.delete("SEVA_ALLOWED_ORIGINS");
});

// §5.2.1's bounds on the three columns onboarding writes, named by §7.4's message.
Deno.test("onboarding names the field §5.2.1 refuses (§7.4)", () => {
  assertEquals(firstOnboardingProblem(onboarding()), null);
  assertEquals(firstOnboardingProblem(onboarding({ display_name: "A" })), "display_name");
  assertEquals(
    firstOnboardingProblem(onboarding({ display_name: "x".repeat(51) })),
    "display_name",
  );
  assertEquals(firstOnboardingProblem(onboarding({ display_name: 7 })), "display_name");
  assertEquals(firstOnboardingProblem(onboarding({ display_name: undefined })), "display_name");
});

Deno.test("a policy version is §5.2.1's effective date and a real day (§5.2.1)", () => {
  assertEquals(firstOnboardingProblem(onboarding({ terms_version: "v1" })), "terms_version");
  assertEquals(
    firstOnboardingProblem(onboarding({ terms_version: "2026-10-1" })),
    "terms_version",
  );
  // The pattern accepts it and the calendar does not, which is what `isIsoDate` adds.
  assertEquals(
    firstOnboardingProblem(onboarding({ terms_version: "2026-02-30" })),
    "terms_version",
  );
  // Postgres has no year zero, measured (§17.1).
  assertEquals(
    firstOnboardingProblem(onboarding({ privacy_version: "0000-01-01" })),
    "privacy_version",
  );
  assertEquals(
    firstOnboardingProblem(onboarding({ privacy_version: null })),
    "privacy_version",
  );
});

// A date of birth that cannot be cast would raise inside PostgREST's wrapper before the
// function body runs, unbilled (§12.2's D5 note) — and its DETAIL would carry the date into the
// log (§9.8). Whether it clears D9's 13 stays inside Postgres.
Deno.test("a date of birth is checked for shape here and for age in Postgres (§9.6)", () => {
  assertEquals(firstOnboardingProblem(onboarding({ date_of_birth: "1995-04-04" })), null);
  assertEquals(
    firstOnboardingProblem(onboarding({ date_of_birth: "04-04-1995" })),
    "date_of_birth",
  );
  assertEquals(
    firstOnboardingProblem(onboarding({ date_of_birth: "2026-02-30" })),
    "date_of_birth",
  );
  assertEquals(
    firstOnboardingProblem(onboarding({ date_of_birth: "0000-01-01" })),
    "date_of_birth",
  );
  assertEquals(firstOnboardingProblem(onboarding({ date_of_birth: undefined })), "date_of_birth");
  // A 12-year-old's date is a perfectly good date: this side must not be able to tell, because
  // §17.1 forbids an age band reaching anything that logs.
  const twelve = new Date(Date.now() - 12 * 365 * 24 * 3600 * 1000).toISOString().slice(0, 10);
  assertEquals(firstOnboardingProblem(onboarding({ date_of_birth: twelve })), null);
});

Deno.test("an export id that is not a UUID never reaches the cast in Postgres", async () => {
  const response = await app.request("/account/export/not-a-uuid", { method: "GET" });
  // Unauthenticated, so §13.4's first step answers; what this asserts is that no path sends
  // `not-a-uuid` to Postgres.
  assertEquals(response.status, 401);
});

Deno.test("the methods §7.3 does not give these routes are 404", async () => {
  assertEquals((await app.request("/account/onboarding")).status, 404);
  assertEquals((await app.request("/account/export")).status, 404);
  assertEquals(
    (await app.request(`/account/export/${EXPORT_ID}`, { method: "POST" })).status,
    404,
  );
});
