// The client and the AWS settings are read at boot (§9.5), so the names they read are
// set before the module is imported. Nothing here reaches AWS or the database: the
// worker's own decisions are what these exercise, up to the send.
Deno.env.set("SUPABASE_URL", "http://db.test");
Deno.env.set(
  "SUPABASE_SECRET_KEYS",
  JSON.stringify({ "moderation-worker": "sb_secret_worker_test" }),
);
Deno.env.set("AWS_REGION", "ap-south-1");
Deno.env.set("SEVA_GUARDRAIL_ID", "gr-abc123");
Deno.env.set("SEVA_GUARDRAIL_VERSION", "1");

const { app, authorised, holdsPhoto } = await import("./index.ts");
const { assertEquals } = await import("jsr:@std/assert@1.0.19");

Deno.test("§7.3: the worker checks its own secret key, which is not a JWT", () => {
  assertEquals(authorised("Bearer sb_secret_worker_test"), true);
  assertEquals(authorised("Bearer sb_secret_worker_tesx"), false);
  // A prefix must not pass: the comparison is over equal lengths or nothing.
  assertEquals(authorised("Bearer sb_secret_worker_tes"), false);
  assertEquals(authorised("Bearer "), false);
  assertEquals(authorised("sb_secret_worker_test"), false);
  assertEquals(authorised(undefined), false);
});

Deno.test("a call with no key is refused before anything is claimed", async () => {
  const response = await app.request("/moderation-worker", { method: "POST" });
  assertEquals(response.status, 401);
  assertEquals((await response.json()).error.code, "UNAUTHENTICATED");
});

Deno.test("an unknown path under the worker is §7.1's shape, not Hono's", async () => {
  const response = await app.request("/moderation-worker/drain", { method: "POST" });
  assertEquals(response.status, 404);
  assertEquals((await response.json()).error.code, "NOT_FOUND");
});

// §8.4: "hold at 80% confidence or above in the high-severity categories (explicit
// content, violence, visually disturbing, hate symbols)".
Deno.test("§8.4's threshold holds a photo at 80 in the four named categories", () => {
  assertEquals(holdsPhoto([{ Name: "Explicit", Confidence: 80, TaxonomyLevel: 1 }]), true);
  assertEquals(holdsPhoto([{ Name: "Violence", Confidence: 99.4, TaxonomyLevel: 1 }]), true);
  assertEquals(
    holdsPhoto([{ Name: "Visually Disturbing", Confidence: 88, TaxonomyLevel: 1 }]),
    true,
  );
  assertEquals(holdsPhoto([{ Name: "Hate Symbols", Confidence: 91, TaxonomyLevel: 1 }]), true);
});

Deno.test("and lets a photo through below it, or outside those categories", () => {
  assertEquals(holdsPhoto([]), false);
  assertEquals(holdsPhoto([{ Name: "Explicit", Confidence: 79.9, TaxonomyLevel: 1 }]), false);
  // §8.4 names four of the ten top-level categories. Alcohol at a community event and
  // swimwear at a beach clean-up are not ones a moderator should be queued for.
  assertEquals(holdsPhoto([{ Name: "Alcohol", Confidence: 99, TaxonomyLevel: 1 }]), false);
  assertEquals(
    holdsPhoto([{ Name: "Swimwear or Underwear", Confidence: 95, TaxonomyLevel: 1 }]),
    false,
  );
  assertEquals(holdsPhoto([{ Name: "Gambling", Confidence: 99, TaxonomyLevel: 1 }]), false);
});

// A level-3 label's `ParentName` is its level-2 parent, not the category, so an
// implementation reading `ParentName` would miss "Explicit" three levels down. The
// API returns the top-level label alongside the deeper ones, which is what is read.
Deno.test("the category's own name is what decides, not a deeper one's parent", () => {
  const deep = [
    { Name: "Explicit", Confidence: 96, TaxonomyLevel: 1 },
    { Name: "Explicit Nudity", ParentName: "Explicit", Confidence: 95, TaxonomyLevel: 2 },
    {
      Name: "Exposed Male Genitalia",
      ParentName: "Explicit Nudity",
      Confidence: 94,
      TaxonomyLevel: 3,
    },
  ];
  assertEquals(holdsPhoto(deep), true);

  // The same deeper labels without the level-1 one do not hold on their own, because
  // the category is what §8.4 names.
  assertEquals(holdsPhoto(deep.slice(1)), false);
});

Deno.test("a confidence the API did not return is not a hold", () => {
  assertEquals(holdsPhoto([{ Name: "Explicit", TaxonomyLevel: 1 }]), false);
  assertEquals(holdsPhoto([{ Confidence: 99, TaxonomyLevel: 1 }]), false);
});

// Fail closed on a response shape §8.4 did not anticipate. An earlier version also
// required `TaxonomyLevel === 1`, so a taxonomy that stopped sending the level would
// have passed every photo silently — the worst way for a moderation check to break.
Deno.test("a label with no taxonomy level still holds, rather than passing silently", () => {
  assertEquals(holdsPhoto([{ Name: "Explicit", Confidence: 96 }]), true);
  assertEquals(holdsPhoto([{ Name: "Hate Symbols", Confidence: 81 }]), true);
  // And the threshold still applies, so this is not fail-closed on everything.
  assertEquals(holdsPhoto([{ Name: "Explicit", Confidence: 60 }]), false);
});
