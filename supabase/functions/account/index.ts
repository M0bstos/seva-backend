import { Hono } from "npm:hono@4.13.9";
import { requiredCaller } from "../_shared/auth.ts";
import { browserOrigins } from "../_shared/cors.ts";
import { secretKeyClient } from "../_shared/db.ts";
import { fail, refusal } from "../_shared/errors.ts";
import { isIsoDate, isTextWithin, isUuid, readJsonObject } from "../_shared/fields.ts";
import { limitArgs } from "../_shared/limits.ts";
import {
  DISPLAY_NAME_LENGTH,
  EXPORTS_BUCKET,
  POLICY_VERSION_PATTERN,
  SECRET_KEY_NAME,
  SIGNED_URL_SECONDS,
} from "./account.constants.ts";

// §7.3's four account routes: `POST /account/onboarding`, `POST /account/delete`,
// `POST /account/export` and `GET /account/export/:id`. The handler chain is §13.4's, and
// everything about eligibility, the limiter and the kill switch lives inside each route's one
// Postgres call (§12.2, §17.1).
//
// Nothing here logs. A date of birth and an email address are both on §9.8's never-log list,
// and §17.1 adds that an `AGE_RESTRICTED` refusal must not be written against a user id —
// which is what onboarding answers an under-13 account.
const db = secretKeyClient(SECRET_KEY_NAME);
export const app = new Hono().basePath("/account");

// §17 `O37`: §4.1's app is "iOS · Android · web", so a browser preflights every call. §11.3
// requires account deletion to be in the app, and a web build is one of the apps.
app.use("*", browserOrigins());

app.post("/onboarding", async (c) => {
  const userId = await requiredCaller(db, c.req.header("Authorization"));
  if (userId instanceof Response) return userId;

  const body = await readJsonObject(c.req.raw);
  if (body === null) return fail("VALIDATION_FAILED", "body");

  const bad = firstOnboardingProblem(body);
  if (bad) return fail("VALIDATION_FAILED", bad);

  // No `Idempotency-Key` and no limit arguments: §17.1 records that §7.3's "once" is enforced
  // by §5.4's profile row rather than by a counter, because no window the limiter holds can
  // express a lifetime cap.
  const { data, error } = await db.rpc("onboard_account", {
    p_user_id: userId,
    p_display_name: body.display_name,
    p_date_of_birth: body.date_of_birth,
    p_terms_version: body.terms_version,
    p_privacy_version: body.privacy_version,
  });
  // Not logged: the Postgres DETAIL would carry the date of birth (§9.8).
  if (error) return fail("INTERNAL");

  const answer = data as Record<string, unknown>;
  const refused = refusal(answer);
  if (refused) return refused;

  // 201 for the account this call created, 200 for one that was already onboarded — the same
  // split §17.1 gives the three idempotent creates, reached here through §5.4's gate rather
  // than through a stored key.
  return Response.json(
    { profile: answer.profile },
    { status: answer.onboarded ? 201 : 200 },
  );
});

app.post("/delete", async (c) => {
  const userId = await requiredCaller(db, c.req.header("Authorization"));
  if (userId instanceof Response) return userId;

  const { data, error } = await db.rpc("request_account_deletion", {
    ...limitArgs("account.delete", userId, userId),
  });
  if (error) return fail("INTERNAL");

  const answer = data as Record<string, unknown>;
  const refused = refusal(answer);
  if (refused) return refused;

  // §7.3 gives this route no status of its own. **202**, matching the one §7.3 does fix for
  // the export, because this route schedules rather than performs: §5.4's deletion touches
  // Storage and Auth, so the work is the operations worker's. A deletion already pending
  // answers 202 as well — it is scheduled either way, and §17.1 puts this route among the
  // creates that store no `idempotency_key`, so there is no replay to distinguish. Only a
  // request that has already finished, or failed and not been retried, answers 200.
  return Response.json(
    { deletion: { status: answer.status, requested_at: answer.requested_at } },
    { status: answer.status === "pending" ? 202 : 200 },
  );
});

app.post("/export", async (c) => {
  const userId = await requiredCaller(db, c.req.header("Authorization"));
  if (userId instanceof Response) return userId;

  const { data, error } = await db.rpc("request_account_export", {
    ...limitArgs("account.export", userId, userId),
  });
  if (error) return fail("INTERNAL");

  const answer = data as Record<string, unknown>;
  const refused = refusal(answer);
  if (refused) return refused;

  // §7.3 fixes this one exactly: "Queues an export; returns `202 { export_id }`".
  return Response.json({ export_id: answer.export_id }, { status: 202 });
});

app.get("/export/:id", async (c) => {
  const userId = await requiredCaller(db, c.req.header("Authorization"));
  if (userId instanceof Response) return userId;

  const exportId = c.req.param("id");
  if (!isUuid(exportId)) return fail("VALIDATION_FAILED", "id");

  const { data, error } = await db.rpc("read_account_export", {
    p_export_id: exportId,
    ...limitArgs("account.export.read", userId, userId),
  });
  if (error) return fail("INTERNAL");

  const answer = data as Record<string, unknown>;
  const refused = refusal(answer);
  if (refused) return refused;

  // §7.3: "Returns `{ status, url? }`; the URL is signed for 1 hour". The path comes back only
  // for an export that is ready and inside its seven days, so this never signs an object that
  // has gone — measured, `createSignedUrl` errors on one that is not there.
  const path = answer.file_path;
  if (typeof path !== "string") {
    return Response.json({ status: answer.status });
  }

  const signed = await db.storage
    .from(EXPORTS_BUCKET)
    .createSignedUrl(path, SIGNED_URL_SECONDS);
  // A signature that cannot be minted is not the caller's fault and not a missing export: the
  // status is still true, so it is answered without a URL rather than as a 500. The Storage
  // error is not inspected, because its message carries the object path (§9.8).
  if (signed.error || !signed.data) {
    return Response.json({ status: answer.status });
  }

  return Response.json({ status: answer.status, url: signed.data.signedUrl });
});

// The name of the first field that is missing or the wrong shape, or null. Exported so §5.2.1's
// bounds are tested as the pure function they are: through the chain, §13.4's token step
// answers first and a request could never show which field was refused.
export function firstOnboardingProblem(body: Record<string, unknown>): string | null {
  if (!isTextWithin(body.display_name, DISPLAY_NAME_LENGTH)) return "display_name";
  // §5.2.1 checks the two policy versions against `^\d{4}-\d{2}-\d{2}$`, and `isIsoDate` adds
  // what that pattern cannot say: that the day exists, and that the year is one Postgres has.
  if (!isPolicyVersion(body.terms_version)) return "terms_version";
  if (!isPolicyVersion(body.privacy_version)) return "privacy_version";
  // The date of birth is checked for shape only. Whether it clears D9's 13 is
  // `onboard_account`'s, because §9.6 keeps the date itself inside Postgres and §17.1 forbids
  // this side even learning which band the answer was about.
  if (!isIsoDate(body.date_of_birth)) return "date_of_birth";
  return null;
}

function isPolicyVersion(value: unknown): value is string {
  return typeof value === "string" && POLICY_VERSION_PATTERN.test(value) && isIsoDate(value);
}

// §7.1 gives every function error one shape, including the two Hono would otherwise answer in
// its own words.
app.notFound(() => fail("NOT_FOUND"));
app.onError(() => fail("INTERNAL"));

if (import.meta.main) Deno.serve(app.fetch);
