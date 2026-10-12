import { assertEquals, assertNotEquals } from "jsr:@std/assert@1.0.19";
import { callRoute, onboarded, reachable, readTable, signedIn } from "./stack.ts";

// §13.1 asks for one end-to-end test per §7.3 route. These accounts are signed in and
// un-onboarded, so both routes stop at §5.4's gate — which is what proves the chain
// reaches Postgres at all, and in §13.4's order. The full flow, where a photo is
// uploaded to a signed URL and completed, needs a profile row and so lands with the
// account route.

// The smallest thing the `uploads` bucket will take. §8.1 puts the type and size check on the
// bucket, which reads the declared content type rather than the bytes (§17.1), so four bytes
// declared `image/jpeg` is enough to exercise steps 1 to 3 — the bytes themselves are the moderation
// worker's business, and §8.1 step 1 is where they are judged.
const JPEG_SOI_EOI = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);

Deno.test("POST /uploads stops at §5.4's onboarding gate (§7.4)", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/uploads", {
    method: "POST",
    token,
    body: { purpose: "act" },
  });
  assertEquals(status, 403);
  assertEquals(body.error, {
    code: "ONBOARDING_REQUIRED",
    message: "Finish onboarding before writing.",
    retryable: false,
  });
});

Deno.test("a purpose outside §5.3's enum is refused by name, not by a cast (§7.4)", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/uploads", {
    method: "POST",
    token,
    body: { purpose: "banner" },
  });
  // The cast would raise inside PostgREST's wrapper before the function body, which
  // §12.2's D5 note refuses: a retryable 500 the limiter never counted.
  assertEquals(status, 400);
  assertEquals(
    (body.error as Record<string, unknown>).message,
    "purpose is missing or malformed.",
  );
});

Deno.test("POST /uploads/:id/complete stops at the same gate (§7.4)", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute(`/uploads/${crypto.randomUUID()}/complete`, {
    method: "POST",
    token,
  });
  assertEquals(status, 403);
  assertEquals((body.error as Record<string, unknown>).code, "ONBOARDING_REQUIRED");
});

Deno.test("a media id that is not a UUID is refused by name (§7.4)", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/uploads/not-a-uuid/complete", {
    method: "POST",
    token,
  });
  assertEquals(status, 400);
  assertEquals((body.error as Record<string, unknown>).message, "id is missing or malformed.");
});

Deno.test("an unknown path under the function answers §7.1's shape, not Hono's", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/uploads/x/y/z", { method: "POST", token });
  assertEquals(status, 404);
  assertEquals((body.error as Record<string, unknown>).code, "NOT_FOUND");
});

Deno.test("§8.1 steps 1 to 3 end to end: a photo ID, a signed URL, and a queued job", async () => {
  const { token } = await onboarded();

  // Step 1. §8.1: "The app calls `POST /uploads` and receives a photo ID and a one-time signed URL
  // for `uploads/{user_id}/{media_id}` in the private bucket."
  const created = await callRoute("/uploads", {
    method: "POST",
    token,
    body: { purpose: "act" },
  });
  assertEquals(created.status, 201);
  const photoId = (created.body.photo as Record<string, unknown>).id as string;
  const uploadUrl = created.body.upload_url as string;
  assertNotEquals(photoId, undefined);
  assertNotEquals(uploadUrl, undefined);

  // The row arrives in `uploading`, which §8.1's 24-hour sweep collects if nothing follows.
  const before = await readTable(`media?id=eq.${photoId}&select=status,public_path`, token);
  assertEquals(before[0].status, "uploading");
  assertEquals(before[0].public_path, null);

  // Step 2, from the app's side: "The app uploads a JPEG, at most 2048 px on the long edge and
  // 5 MB. The bucket rejects any other type or size." A one-time signed upload URL takes a PUT.
  //
  // `reachable` is what makes this work from outside Docker: measured, a local stack issues the URL
  // against `http://kong:8000` because that is the `SUPABASE_URL` the edge runtime sees. Hosted, the
  // URL is right as issued — see the note on `reachable` in stack.ts.
  const put = await fetch(await reachable(uploadUrl), {
    method: "PUT",
    headers: { "Content-Type": "image/jpeg" },
    body: JPEG_SOI_EOI,
  });
  assertEquals(put.ok, true);

  // Step 3: "That route confirms the object exists and is 5 MB or smaller through the Storage API,
  // sets the photo to `processing`, and queues a moderation job."
  const completed = await callRoute(`/uploads/${photoId}/complete`, { method: "POST", token });
  assertEquals(completed.status, 200);
  assertEquals((completed.body.photo as Record<string, unknown>).status, "processing");

  // On the row, which is what §12.5's stuck-screening arm measures a photo from. The queue write and
  // this status change are one transaction, so a `processing` row is proof the job was sent.
  const after = await readTable(`media?id=eq.${photoId}&select=status`, token);
  assertEquals(after[0].status, "processing");

  // §5.2.1 gives `media` no idempotency key, so a repeat is answered with the status it already has
  // rather than refused, and queues no second job (§17.1).
  const again = await callRoute(`/uploads/${photoId}/complete`, { method: "POST", token });
  assertEquals(again.status, 200);
  assertEquals((again.body.photo as Record<string, unknown>).status, "processing");
});

Deno.test("completing an upload that was never made is 400 by name (§8.1 step 3)", async () => {
  const { token } = await onboarded();
  const created = await callRoute("/uploads", {
    method: "POST",
    token,
    body: { purpose: "avatar" },
  });
  const photoId = (created.body.photo as Record<string, unknown>).id as string;

  // No PUT, so there is no object. §8.1 asks the route to confirm it exists, and both the missing
  // and the oversized case are the caller's upload being wrong rather than the wrong photo named.
  const { status, body } = await callRoute(`/uploads/${photoId}/complete`, {
    method: "POST",
    token,
  });
  assertEquals(status, 400);
  assertEquals((body.error as Record<string, unknown>).message, "file is missing or malformed.");

  // And the photo is left in `uploading`, where §8.1's sweep collects it — not in `processing`,
  // where §12.5's arm would fire on it fifteen minutes later.
  const row = await readTable(`media?id=eq.${photoId}&select=status`, token);
  assertEquals(row[0].status, "uploading");
});

Deno.test("another person's photo cannot be completed (§7.4, §17.1)", async () => {
  const mine = await onboarded();
  const theirs = await onboarded();
  const created = await callRoute("/uploads", {
    method: "POST",
    token: mine.token,
    body: { purpose: "act" },
  });
  const photoId = (created.body.photo as Record<string, unknown>).id as string;

  const { status, body } = await callRoute(`/uploads/${photoId}/complete`, {
    method: "POST",
    token: theirs.token,
  });
  assertEquals(status, 403);
  assertEquals((body.error as Record<string, unknown>).code, "FORBIDDEN");
});
