// No test here reaches Storage, Auth or the database: what is testable without an AWS account or a
// stack is the secret-key check, the error shape and the bucket lists the Storage branches turn on.
Deno.env.set("SUPABASE_URL", "http://db.test");
Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ "ops-worker": "sb_secret_test" }));

const { app, authorised } = await import("./index.ts");
const { assertEquals } = await import("jsr:@std/assert@1.0.19");
const { BUCKETS, DELETE_FROM, PUBLISH_FROM, PUBLIC_MEDIA_PREFIX, PUBLISHED_CONTENT_TYPE } =
  await import("./ops-worker.constants.ts");

Deno.test("only the worker's own secret key is authorised (§7.3, §9.5)", () => {
  assertEquals(authorised("Bearer sb_secret_test"), true);
  assertEquals(authorised("Bearer sb_secret_other"), false);
  assertEquals(authorised("Bearer sb_secret_tes"), false);
  assertEquals(authorised(undefined), false);
});

Deno.test("a call with no key is UNAUTHENTICATED, not a 500 (§7.1, §7.4)", async () => {
  const response = await app.request("/ops-worker", { method: "POST" });
  assertEquals(response.status, 401);
  assertEquals((await response.json()).error.code, "UNAUTHENTICATED");
});

Deno.test("an unknown path under the worker is §7.1's shape (§7.1)", async () => {
  const response = await app.request("/ops-worker/x", { method: "POST" });
  assertEquals(response.status, 404);
  assertEquals((await response.json()).error.code, "NOT_FOUND");
});

Deno.test("the worker answers no preflight, because cron is its caller (§17 O37)", async () => {
  Deno.env.set("SEVA_ALLOWED_ORIGINS", "https://seva.example");
  const response = await app.request("/ops-worker", {
    method: "OPTIONS",
    headers: { Origin: "https://seva.example", "Access-Control-Request-Method": "POST" },
  });
  assertEquals(response.headers.get("access-control-allow-origin"), null);
  Deno.env.delete("SEVA_ALLOWED_ORIGINS");
});

// §17.1's no-bucket-column decision rests on a deletion trying every bucket a key could sit in.
// `exports` is deliberately not among them: §7.3 keeps an export in its own bucket and
// `expire_account_exports` deletes from there by name, so a content key could never be there.
Deno.test("a deletion tries every bucket a content key could be in (§11.6, §17.1)", () => {
  assertEquals([...DELETE_FROM], [BUCKETS.uploads, BUCKETS.media, BUCKETS.quarantine]);
  assertEquals(DELETE_FROM.includes(BUCKETS.exports as never), false);
});

// §17 O22: a public bucket serves an object as whatever type it carries, so the type is set and
// never passed through.
Deno.test("the published copy is written as image/jpeg (§17 O22)", () => {
  assertEquals(PUBLISHED_CONTENT_TYPE, "image/jpeg");
});

// §7.3's "Published photos appear as public URLs", built from the project URL the platform injects.
Deno.test("the export's photo URLs are built against the media bucket (§7.3)", () => {
  assertEquals(PUBLIC_MEDIA_PREFIX, "/storage/v1/object/public/media");
});

// §8.1's step 4 deletes the original once a photo passes, and a staff approval is it passing — but
// only out of `uploads`, because the other bucket `PUBLISH_FROM` looks in is `media`, where a file
// found is the published copy itself. `quarantine` is in `DELETE_FROM` and not in `PUBLISH_FROM`,
// which is the difference the assertions below pin.
// What this can assert is the two lists; the delete itself needs Storage, which no test in this
// file reaches, and the publication path has no end-to-end test because it starts at a moderator
// approval. Recorded in §17.1 rather than left to look covered.
Deno.test("publishing looks where the bytes can be, and nowhere they cannot (§8.1, §8.3)", () => {
  // The order is part of it: `media` last, so a photo whose original is still in `uploads` is
  // published from the original rather than from a copy that may not exist yet.
  assertEquals([...PUBLISH_FROM], [BUCKETS.uploads, BUCKETS.media]);
  // `uploads` for a photo held at screening; `media` for one published, then held, then approved,
  // whose original `uploads` copy was deleted when it first passed.
  assertEquals(PUBLISH_FROM.includes(BUCKETS.uploads), true);
  assertEquals(PUBLISH_FROM.includes(BUCKETS.media), true);
  // Never `quarantine`: a file arrives there only on removal, and removal is terminal, so no
  // publication can name one — and deleting out of it would destroy a file §11.6 is retaining.
  assertEquals((PUBLISH_FROM as readonly string[]).includes(BUCKETS.quarantine), false);
  assertEquals((DELETE_FROM as readonly string[]).includes(BUCKETS.quarantine), true);
});

// The two retention kinds delete from different places, and the separation is the point: §11.6's
// released content can be in any of the three content buckets, while `O7`'s expired export is only
// ever in the private `exports` bucket. If `exports` joined `DELETE_FROM`, a content key colliding
// with an export key would take somebody's export with it. The cast is what makes this a test: as
// written, `DELETE_FROM` is typed to the three content buckets and the comparison does not compile,
// so this fails at the moment somebody widens that type rather than after they widen the list.
Deno.test("an expired export is deleted from its own bucket alone (O7, §11.6)", () => {
  assertEquals((DELETE_FROM as readonly string[]).includes(BUCKETS.exports), false);
  assertEquals(BUCKETS.exports, "exports");
});
