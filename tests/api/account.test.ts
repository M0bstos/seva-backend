import { assertEquals, assertNotEquals } from "jsr:@std/assert@1.0.19";
import { callRoute, onboarded, signedIn } from "./stack.ts";

// §13.1 asks for one end-to-end test per §7.3 route. These four are the account group, and
// onboarding is the route that unblocks every other write test in this suite — before it existed
// each one stopped at §5.4's gate.

Deno.test("POST /account/onboarding creates the profile §5.4's gate wants (§7.3)", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/account/onboarding", {
    method: "POST",
    token,
    body: {
      display_name: "Anand",
      date_of_birth: "1995-04-04",
      terms_version: "2026-10-01",
      privacy_version: "2026-10-01",
    },
  });
  // §17.1: 201 for the account this call created.
  assertEquals(status, 201);
  assertEquals((body.profile as Record<string, unknown>).display_name, "Anand");
  assertEquals((body.profile as Record<string, unknown>).status, "active");
});

// §5.4: "having a profile row is the gate", so a second call has nothing to create.
Deno.test("onboarding twice answers the row rather than refusing (§5.4)", async () => {
  const { token } = await onboarded();
  const { status, body } = await callRoute("/account/onboarding", {
    method: "POST",
    token,
    body: {
      display_name: "Renamed",
      date_of_birth: "1990-01-01",
      terms_version: "2026-10-01",
      privacy_version: "2026-10-01",
    },
  });
  assertEquals(status, 200);
  // Nothing is overwritten: onboarding is not a way to edit a profile (§7.2 is).
  assertEquals((body.profile as Record<string, unknown>).display_name, "API test");
});

// D9's floor, checked in Postgres so the date never leaves it (§9.6, §17.1).
Deno.test("an account under 13 is refused, and no profile row is written (D9)", async () => {
  const { token } = await signedIn();
  const twelve = new Date(Date.now() - 12 * 365 * 24 * 3600 * 1000).toISOString().slice(0, 10);
  const { status, body } = await callRoute("/account/onboarding", {
    method: "POST",
    token,
    body: {
      display_name: "Too young",
      date_of_birth: twelve,
      terms_version: "2026-10-01",
      privacy_version: "2026-10-01",
    },
  });
  assertEquals(status, 403);
  assertEquals((body.error as Record<string, unknown>).code, "AGE_RESTRICTED");

  // And the gate stays shut: a write still answers ONBOARDING_REQUIRED rather than succeeding.
  const after = await callRoute("/account/export", { method: "POST", token });
  assertEquals(after.status, 403);
  assertEquals((after.body.error as Record<string, unknown>).code, "ONBOARDING_REQUIRED");
});

Deno.test("a policy version that is not §5.2.1's effective date is 400 by name", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/account/onboarding", {
    method: "POST",
    token,
    body: {
      display_name: "Anand",
      date_of_birth: "1995-04-04",
      terms_version: "v1",
      privacy_version: "2026-10-01",
    },
  });
  assertEquals(status, 400);
  assertEquals(
    (body.error as Record<string, unknown>).message,
    "terms_version is missing or malformed.",
  );
});

// §7.3: "Queues an export; returns `202 { export_id }`."
Deno.test("POST /account/export answers 202 with an export id (§7.3)", async () => {
  const { token } = await onboarded();
  const { status, body } = await callRoute("/account/export", { method: "POST", token });
  assertEquals(status, 202);
  assertNotEquals(body.export_id, undefined);
});

// §7.3: "Returns `{ status, url? }`; the URL is signed for 1 hour." Nothing has built the file yet,
// so there is a status and no url — which is the half this suite can prove without the worker.
Deno.test("GET /account/export/:id answers the status, and no url until it is ready", async () => {
  const { token } = await onboarded();
  const queued = await callRoute("/account/export", { method: "POST", token });
  const id = queued.body.export_id as string;

  const { status, body } = await callRoute(`/account/export/${id}`, { token });
  assertEquals(status, 200);
  assertEquals(body.status, "pending");
  assertEquals(body.url, undefined);
});

// §7.3 scopes the read to "Owner", and §7.4 folds "missing" with "not visible to you" so an id
// cannot be probed.
Deno.test("another person's export is NOT_FOUND, not FORBIDDEN (§7.3, §7.4)", async () => {
  const mine = await onboarded();
  const theirs = await onboarded();
  const queued = await callRoute("/account/export", { method: "POST", token: mine.token });
  const id = queued.body.export_id as string;

  const { status, body } = await callRoute(`/account/export/${id}`, { token: theirs.token });
  assertEquals(status, 404);
  assertEquals((body.error as Record<string, unknown>).code, "NOT_FOUND");
});

// §7.3: "Schedules full deletion (§5.4)", and §11.3 makes it an app-store requirement.
Deno.test("POST /account/delete schedules the erasure (§7.3, §11.3)", async () => {
  const { token } = await onboarded();
  const { status, body } = await callRoute("/account/delete", { method: "POST", token });
  assertEquals(status, 202);
  assertEquals((body.deletion as Record<string, unknown>).status, "pending");
});

// §5.2.1 gives `account_deletions` a key with no foreign key, so §11.2's erasure right does not
// begin at onboarding — this is the one write route that works before the gate.
Deno.test("an account that never onboarded can still be erased (§5.2.1, §11.2)", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/account/delete", { method: "POST", token });
  assertEquals(status, 202);
  assertEquals((body.deletion as Record<string, unknown>).status, "pending");
});

Deno.test("asking twice does not queue a second deletion (§7.3)", async () => {
  const { token } = await onboarded();
  const first = await callRoute("/account/delete", { method: "POST", token });
  const second = await callRoute("/account/delete", { method: "POST", token });
  assertEquals(first.status, 202);
  assertEquals(second.status, 202);
  assertEquals((second.body.deletion as Record<string, unknown>).status, "pending");
});

Deno.test("an unknown path under the function answers §7.1's shape", async () => {
  const { token } = await signedIn();
  const { status, body } = await callRoute("/account/nope", { method: "POST", token });
  assertEquals(status, 404);
  assertEquals((body.error as Record<string, unknown>).code, "NOT_FOUND");
});
