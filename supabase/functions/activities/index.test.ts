// The client is built at module load (§9.5), so the names it reads are set before the
// route is imported. Nothing here reaches the database.
Deno.env.set("SUPABASE_URL", "http://db.test");
Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ activities: "sb_secret_test" }));

const { app, firstProblem } = await import("./index.ts");
const { assertEquals } = await import("jsr:@std/assert@1.0.19");

const KEY = "3f2504e0-4f89-41d3-9a0c-0305e82c3301";

function activity(overrides: Record<string, unknown> = {}) {
  return {
    title: "Riverside cleanup",
    description: "Bring gloves and water. We meet at the east gate at dawn on Sunday.",
    category: "environment",
    starts_at: "2026-10-21T07:00:00+05:30",
    ends_at: "2026-10-21T10:00:00+05:30",
    lon: 73.8567,
    lat: 18.5204,
    location_label: "East gate",
    capacity: 20,
    ...overrides,
  };
}

Deno.test("every route needs a session (§7.3)", async () => {
  for (const path of ["/activities", "/activities/" + KEY + "/join"]) {
    const response = await app.request(path, {
      method: "POST",
      headers: { "Idempotency-Key": KEY },
      body: JSON.stringify(activity()),
    });
    assertEquals(response.status, 401);
    assertEquals((await response.json()).error.code, "UNAUTHENTICATED");
  }
});

Deno.test("leave and cancel are separate paths, not one (§7.3)", async () => {
  for (const action of ["leave", "cancel"]) {
    const response = await app.request(`/activities/${KEY}/${action}`, { method: "POST" });
    assertEquals(response.status, 401);
  }
  // A path §7.3 does not give this function is a 404, not a 401.
  const unknown = await app.request(`/activities/${KEY}/delete`, { method: "POST" });
  assertEquals(unknown.status, 404);
});

Deno.test("every field §5.2.1 bounds is named by the message that refuses it (§7.4)", () => {
  assertEquals(firstProblem(activity()), null);
  assertEquals(firstProblem(activity({ title: "four" })), "title");
  assertEquals(firstProblem(activity({ description: "too short" })), "description");
  assertEquals(firstProblem(activity({ category: "gardening" })), "category");
  assertEquals(firstProblem(activity({ location_label: "ab" })), "location_label");
  assertEquals(firstProblem(activity({ what_to_bring: "x".repeat(501) })), "what_to_bring");
});

Deno.test("a timestamp without an offset is refused, or the event moves (§7.1)", () => {
  assertEquals(firstProblem(activity({ starts_at: "2026-10-21T07:00:00" })), "starts_at");
  assertEquals(firstProblem(activity({ ends_at: "2026-10-21" })), "ends_at");
});

Deno.test("§5.2.1 bounds the length of an Activity as well as its order", () => {
  assertEquals(
    firstProblem(activity({ ends_at: "2026-10-21T06:00:00+05:30" })),
    "ends_at",
    "an Activity cannot end before it starts",
  );
  assertEquals(
    firstProblem(activity({ ends_at: "2026-10-21T07:00:00+05:30" })),
    "ends_at",
    "or at the same moment",
  );
  assertEquals(
    firstProblem(activity({ ends_at: "2026-10-22T08:00:00+05:30" })),
    "ends_at",
    "and cannot run past 24 hours",
  );
  assertEquals(
    firstProblem(activity({ ends_at: "2026-10-22T07:00:00+05:30" })),
    null,
    "exactly 24 hours is allowed, as the check is <=",
  );
});

Deno.test("capacity is a whole number inside §5.2.1's range", () => {
  assertEquals(firstProblem(activity({ capacity: 0 })), "capacity");
  assertEquals(firstProblem(activity({ capacity: 1001 })), "capacity");
  assertEquals(firstProblem(activity({ capacity: 20.5 })), "capacity");
  assertEquals(firstProblem(activity({ capacity: "20" })), "capacity");
  assertEquals(firstProblem(activity({ capacity: 1 })), null);
});

Deno.test("an id that is not a UUID never reaches the cast in Postgres", () => {
  assertEquals(firstProblem(activity({ campaign_id: "not-a-uuid" })), "campaign_id");
  assertEquals(firstProblem(activity({ campaign_id: KEY })), null);
  assertEquals(firstProblem(activity({ photo_ids: [KEY, 7] })), "photo_ids");
  assertEquals(firstProblem(activity({ photo_ids: [] })), null);
});

Deno.test("null reads as absent on every optional field (§7.1.1)", () => {
  assertEquals(firstProblem(activity({ campaign_id: null })), null);
  assertEquals(firstProblem(activity({ what_to_bring: null })), null);
  assertEquals(firstProblem(activity({ photo_ids: null })), null);
  assertEquals(firstProblem(activity({ campaign_id: "nope" })), "campaign_id");
});

// Every one of these was well-shaped and uncastable: each raised inside PostgREST's
// wrapper before `create_activity` ran, so the limiter never counted it and the route
// answered a retryable 500 (§12.2's D5 note, §17.1).
Deno.test("a timestamp Postgres cannot take is 400, never 500 (§7.4)", () => {
  assertEquals(firstProblem(activity({ starts_at: "2026-10-21T07:00:00+18:00" })), "starts_at");
  assertEquals(
    firstProblem(activity({
      starts_at: "0000-10-21T07:00:00+05:30",
      ends_at: "0000-10-21T09:00:00+05:30",
    })),
    "starts_at",
  );
  assertEquals(firstProblem(activity({ ends_at: "+275760-09-12T00:00:00Z" })), "ends_at");
});

Deno.test("a NUL in any text field is refused before it can be logged (§9.8)", () => {
  assertEquals(firstProblem(activity({ location_label: "Dadar\u0000beach" })), "location_label");
  assertEquals(firstProblem(activity({ title: "Riverside\u0000cleanup" })), "title");
  assertEquals(firstProblem(activity({ what_to_bring: "Gloves\u0000" })), "what_to_bring");
});

Deno.test("a lone surrogate is 400, not the 500 PostgREST would force (§12.2)", () => {
  assertEquals(firstProblem(activity({ location_label: "Dadar\ud800beach" })), "location_label");
  assertEquals(firstProblem(activity({ title: "Riverside\ud800cleanup" })), "title");
});

// Reachable by an off-by-one in a date picker, not only by trying: V8 rolls the day
// forward and Postgres raises 22008, so both timestamps rolled together and the
// 24-hour bound saw a clean two-hour window (§12.2's D5 note).
Deno.test("a day that does not exist is 400, never 500 (§7.4)", () => {
  assertEquals(
    firstProblem(activity({
      starts_at: "2027-02-30T07:00:00Z",
      ends_at: "2027-02-30T09:00:00Z",
    })),
    "starts_at",
  );
  assertEquals(firstProblem(activity({ ends_at: "2027-04-31T09:00:00+05:30" })), "ends_at");
});
