import { assertEquals } from "jsr:@std/assert@1.0.19";
import { callRoute, signedIn } from "./stack.ts";

// A signed-in account with no `profiles` row is what §5.4 calls un-onboarded, and it
// is what these tests use: the onboarding route is week 4–5 (§16), so every write
// here stops at that gate. What that proves end to end is the order §13.4 fixes —
// the token, then the body, then one Postgres call — and that the gate is reached at
// all, which no unit test can show.

const ACT = {
  title: "A morning at the river",
  story: "We filled eleven sacks along the bank before the rain came in at noon.",
  category: "environment",
  occurred_on: "2026-09-27",
  lon: 73.8567,
  lat: 18.5204,
};

const ACTIVITY = {
  title: "Riverside cleanup",
  description: "Bring gloves and water. We meet at the east gate at dawn on Sunday.",
  category: "environment",
  starts_at: "2026-10-21T07:00:00+05:30",
  ends_at: "2026-10-21T10:00:00+05:30",
  lon: 73.8567,
  lat: 18.5204,
  location_label: "East gate",
  capacity: 20,
};

Deno.test("POST /acts stops at §5.4's onboarding gate (§7.4)", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/acts", {
    method: "POST",
    token,
    body: ACT,
    idempotencyKey: crypto.randomUUID(),
  });
  assertEquals(status, 403);
  assertEquals(body.error, {
    code: "ONBOARDING_REQUIRED",
    message: "Finish onboarding before writing.",
    retryable: false,
  });
});

Deno.test("a create with no Idempotency-Key is refused by name (§7.1)", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/acts", { method: "POST", token, body: ACT });
  assertEquals(status, 400);
  assertEquals(
    (body.error as Record<string, unknown>).message,
    "Idempotency-Key is missing or malformed.",
  );
});

Deno.test("validation runs before the database, and names the field (§13.4, §7.4)", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/acts", {
    method: "POST",
    token,
    body: { ...ACT, title: "four" },
    idempotencyKey: crypto.randomUUID(),
  });
  assertEquals(status, 400);
  assertEquals(
    (body.error as Record<string, unknown>).message,
    "title is missing or malformed.",
  );
});

Deno.test("PATCH /acts/:id checks onboarding before ownership (§17.1)", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/acts/3f2504e0-4f89-41d3-9a0c-0305e82c3301", {
    method: "PATCH",
    token,
    body: { title: "A morning at the river, rewritten" },
  });
  assertEquals(status, 403);
  assertEquals((body.error as Record<string, unknown>).code, "ONBOARDING_REQUIRED");
});

Deno.test("POST /activities stops at the same gate (§7.3)", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/activities", {
    method: "POST",
    token,
    body: ACTIVITY,
    idempotencyKey: crypto.randomUUID(),
  });
  assertEquals(status, 403);
  assertEquals((body.error as Record<string, unknown>).code, "ONBOARDING_REQUIRED");
});

Deno.test("an Activity that ends before it starts is named, not raised (§5.2.1)", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/activities", {
    method: "POST",
    token,
    body: { ...ACTIVITY, ends_at: "2026-10-21T06:00:00+05:30" },
    idempotencyKey: crypto.randomUUID(),
  });
  assertEquals(status, 400);
  assertEquals(
    (body.error as Record<string, unknown>).message,
    "ends_at is missing or malformed.",
  );
});

Deno.test("join, leave and cancel are three paths on one Activity (§7.3)", async () => {
  const { token } = await signedIn();
  const id = "3f2504e0-4f89-41d3-9a0c-0305e82c3301";
  for (const action of ["join", "leave", "cancel"]) {
    const { status, body } = await callRoute(`/activities/${id}/${action}`, {
      method: "POST",
      token,
    });
    assertEquals(status, 403, action);
    assertEquals((body.error as Record<string, unknown>).code, "ONBOARDING_REQUIRED", action);
  }
});

Deno.test("GET /feed needs no profile row, because §7.3 says signed in", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/feed?lon=73.8567&lat=18.5204", { token });
  assertEquals(status, 200);
  assertEquals(Array.isArray(body.acts), true);
  assertEquals("next_cursor" in body, true);
});

Deno.test("GET /feed with no token is refused by the platform (§7.3)", async () => {
  // §7.3 sets verify_jwt true for this function, so the platform answers before the
  // handler runs — in its own shape, not §7.1's. §17.1 records that seam.
  const { status } = await callRoute("/feed?lon=73.8567&lat=18.5204");
  assertEquals(status, 401);
});

// §17 O30 makes 5 km Feed's smallest rung, and the snap is what enforces it: a 2 km
// request is answered from the 5 km cell rather than refused. What the route refuses
// is a value the `int` column cannot take, which would raise before the limiter
// counted it — measured, an unbilled 5xx.
Deno.test("a radius finer than the Act grid is snapped, not refused (§17 O30)", async () => {
  const { token } = await signedIn();
  const snapped = await callRoute("/feed?lon=73.8567&lat=18.5204&radius_km=2", { token });
  assertEquals(snapped.status, 200);

  const fractional = await callRoute("/feed?lon=73.8567&lat=18.5204&radius_km=3.5", { token });
  assertEquals(fractional.status, 400);
  assertEquals(
    (fractional.body.error as Record<string, unknown>).message,
    "radius_km is missing or malformed.",
  );
});

// §7.1.1 makes a retry that respells an absent field the same request. `update_act`
// coalesces, so `null` keeps the column exactly as a missing field does — these two
// spellings must not be a 403 and a 400 on the same route.
Deno.test("PATCH /acts/:id reads null as absent on both fields (§7.1.1)", async () => {
  const { token } = await signedIn();
  const id = "3f2504e0-4f89-41d3-9a0c-0305e82c3301";
  const story = "We filled eleven sacks along the bank before the rain came in at noon.";

  const omitted = await callRoute(`/acts/${id}`, { method: "PATCH", token, body: { story } });
  const explicit = await callRoute(`/acts/${id}`, {
    method: "PATCH",
    token,
    body: { title: null, story },
  });
  assertEquals(explicit.status, omitted.status);
  assertEquals(explicit.body, omitted.body);

  // With both absent however they are spelled, the message names `body` (§17.1).
  const neither = await callRoute(`/acts/${id}`, {
    method: "PATCH",
    token,
    body: { title: null, story: null },
  });
  assertEquals(neither.status, 400);
  assertEquals(
    (neither.body.error as Record<string, unknown>).message,
    "body is missing or malformed.",
  );
});

// §9.8 names "request bodies" and exact coordinates. A NUL anywhere in the body made
// PostgREST raise 22P05 and put the slice around it into the Postgres log — with the
// raw coordinates, before §5.4's coarsening trigger ever saw them. It also never
// reached the function body, so the limiter did not count it.
Deno.test("a NUL is refused before Postgres can log the body around it (§9.8)", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/activities", {
    method: "POST",
    token,
    body: { ...ACTIVITY, location_label: "Dadar\u0000beach" },
    idempotencyKey: crypto.randomUUID(),
  });
  assertEquals(status, 400);
  assertEquals(
    (body.error as Record<string, unknown>).message,
    "location_label is missing or malformed.",
  );
});

Deno.test("an offset wider than timestamptz takes is 400, never 500 (§7.4)", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/activities", {
    method: "POST",
    token,
    body: {
      ...ACTIVITY,
      starts_at: "2026-10-21T07:00:00+18:00",
      ends_at: "2026-10-21T09:00:00+18:00",
    },
    idempotencyKey: crypto.randomUUID(),
  });
  assertEquals(status, 400);
  assertEquals(
    (body.error as Record<string, unknown>).message,
    "starts_at is missing or malformed.",
  );
});

// JSON permits an unpaired surrogate and both parse and stringify carry it through, so
// it reached PostgREST, which refused the payload with `PGRST102` and never called
// Postgres — no §9.8 exposure, but a retryable 500 the limiter never counted.
Deno.test("a lone surrogate is 400, never the 500 PostgREST forced (§12.2)", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/activities", {
    method: "POST",
    token,
    body: { ...ACTIVITY, location_label: "Dadar\ud800beach" },
    idempotencyKey: crypto.randomUUID(),
  });
  assertEquals(status, 400);
  assertEquals(
    (body.error as Record<string, unknown>).message,
    "location_label is missing or malformed.",
  );
});

Deno.test("a day that does not exist is 400 end to end (§7.4, §12.2)", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/activities", {
    method: "POST",
    token,
    body: {
      ...ACTIVITY,
      starts_at: "2027-02-30T07:00:00+05:30",
      ends_at: "2027-02-30T09:00:00+05:30",
    },
    idempotencyKey: crypto.randomUUID(),
  });
  assertEquals(status, 400);
  assertEquals(
    (body.error as Record<string, unknown>).message,
    "starts_at is missing or malformed.",
  );
});
