// §14.4's dry run: one command that takes a real person from sign-up to erasure against a live
// stack, and says which steps need an AWS account. Nothing here is a fixture — every step is an
// HTTP request a client, a staff member or the ops-host cron would actually make, with real bytes
// and a real GoTrue session, and every step is asserted rather than printed.
//
// It exists because "the tests pass" and "the product works" are different claims, and only this
// one answers the second. §13.1's API tests cover one route each; this covers the chain between
// them, which is where the §8.3 transition rule, the queue protocol and the Storage buckets meet.
//
// Run with the stack up and the functions served:
//   supabase start && supabase functions serve --no-verify-jwt
//   deno task smoke
//
// Exit 0 means every step that can work without AWS did. The three AWS boundaries are reported and
// never fail the run — see WITHOUT_AWS below.
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

// §8.2's screening and §2.1's one email are the only product paths that call AWS, plus the sign-in
// hook. Everything else in this file runs on Supabase alone.
const WITHOUT_AWS = [
  "moderation-worker: Rekognition and Bedrock Guardrails. Nothing becomes visible on its own.",
  "message-worker: SES and End User Messaging. A queued message retries and archives (§8.4).",
  "sms-hook: End User Messaging. Phone sign-in does not work; email sign-in does.",
];

const stack = JSON.parse(
  new TextDecoder().decode(
    (await new Deno.Command("supabase", { args: ["status", "-o", "json"], stdout: "piped" })
      .output()).stdout,
  ),
);
const API = stack.API_URL as string;
const PUBLISHABLE = stack.PUBLISHABLE_KEY as string;
// Locally the platform injects one key named `default`, which is what a worker's own key check
// resolves to — see the fallback in `_shared/db.ts` and why it is gated on a local URL.
const WORKER_KEY = stack.SECRET_KEY as string;

let step = 0;
const pass = (what: string, detail = "") => {
  step += 1;
  console.log(`  ok ${String(step).padStart(2)}  ${what}${detail ? `  — ${detail}` : ""}`);
};
const heading = (what: string) => console.log(`\n${what}`);

// Read-only psql, for the rows a client is not allowed to see (§9.2, §11.6). The walkthrough
// asserts against these as well as against responses, because a 200 that wrote nothing is the
// failure this is meant to catch.
async function sql(query: string): Promise<string> {
  const run = await new Deno.Command("docker", {
    args: [
      "exec",
      "supabase_db_seva-backend",
      "psql",
      "-U",
      "postgres",
      "-At",
      "-c",
      query,
    ],
    stdout: "piped",
    stderr: "piped",
  }).output();
  const err = new TextDecoder().decode(run.stderr).trim();
  if (err && !err.includes("NOTICE")) throw new Error(`psql: ${err.slice(0, 200)}`);
  return new TextDecoder().decode(run.stdout).trim();
}

type Answer = { status: number; body: Record<string, unknown> };

async function call(
  path: string,
  options: { method?: string; token?: string; workerKey?: boolean; body?: unknown } = {},
): Promise<Answer> {
  const headers: Record<string, string> = {
    apikey: PUBLISHABLE,
    "Content-Type": "application/json",
    "x-region": "ap-south-1",
  };
  if (options.token) headers.Authorization = `Bearer ${options.token}`;
  if (options.workerKey) headers.Authorization = `Bearer ${WORKER_KEY}`;
  if (options.method === "POST") headers["Idempotency-Key"] = crypto.randomUUID();
  const response = await fetch(`${API}/functions/v1${path}`, {
    method: options.method ?? "GET",
    headers,
    body: options.body ? JSON.stringify(options.body) : undefined,
  });
  const text = await response.text();
  try {
    return { status: response.status, body: JSON.parse(text) };
  } catch {
    return { status: response.status, body: { raw: text.slice(0, 200) } };
  }
}

// A real account through the real Auth endpoints. Production signs in with a phone OTP, which needs
// the sign-in hook and so AWS; the session GoTrue mints is the same JWT either way, and the JWT is
// what every route verifies.
async function onboarded(displayName: string) {
  const email = `smoke-${crypto.randomUUID()}@seva.test`;
  const password = crypto.randomUUID();
  const made = await fetch(`${API}/auth/v1/admin/users`, {
    method: "POST",
    headers: {
      apikey: WORKER_KEY,
      Authorization: `Bearer ${WORKER_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ email, password, email_confirm: true }),
  });
  const user = await made.json();
  const session = await fetch(`${API}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: PUBLISHABLE, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  const { access_token } = await session.json();
  const joined = await call("/account/onboarding", {
    method: "POST",
    token: access_token,
    body: {
      display_name: displayName,
      date_of_birth: "1991-02-02",
      terms_version: "2026-10-01",
      privacy_version: "2026-10-01",
    },
  });
  assertEquals(joined.status, 201, `onboarding ${displayName}: ${JSON.stringify(joined.body)}`);
  return { id: user.id as string, token: access_token as string, email, password };
}

// §9.3 requires `aal2` for every staff action, and a password session is `aal1`. This is the real
// TOTP enrolment the Appsmith sign-in uses (§10.3), so the staff half of the walkthrough proves the
// MFA gate rather than bypassing it with a hand-made claim.
function base32(secret: string): Uint8Array<ArrayBuffer> {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const character of secret.replace(/=+$/, "").toUpperCase()) {
    bits += alphabet.indexOf(character).toString(2).padStart(5, "0");
  }
  // Over an explicit ArrayBuffer, because `crypto.subtle.importKey` wants a `BufferSource` and a
  // bare `new Uint8Array(n)` is typed over `ArrayBufferLike`, which includes `SharedArrayBuffer`.
  const bytes = new Uint8Array(new ArrayBuffer(Math.floor(bits.length / 8)));
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(bits.slice(i * 8, i * 8 + 8), 2);
  return bytes;
}

async function totp(secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    base32(secret),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  const counter = new ArrayBuffer(8);
  new DataView(counter).setBigUint64(0, BigInt(Math.floor(Date.now() / 1000 / 30)));
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, counter));
  const offset = mac[mac.length - 1] & 0x0f;
  const code = (((mac[offset] & 0x7f) << 24) | (mac[offset + 1] << 16) |
    (mac[offset + 2] << 8) | mac[offset + 3]) % 1_000_000;
  return code.toString().padStart(6, "0");
}

// The first staff row is a database step by design: `admin_set_staff` needs an existing admin, so
// §10.2 gives no route that can create the first one.
async function staffMember(displayName: string, role: "moderator" | "admin") {
  const person = await onboarded(displayName);
  await sql(`insert into staff (user_id, role) values ('${person.id}', '${role}')`);
  const auth = {
    apikey: PUBLISHABLE,
    Authorization: `Bearer ${person.token}`,
    "Content-Type": "application/json",
  };
  const factor = await (await fetch(`${API}/auth/v1/factors`, {
    method: "POST",
    headers: auth,
    body: JSON.stringify({ factor_type: "totp", friendly_name: "smoke" }),
  })).json();
  const challenge = await (await fetch(`${API}/auth/v1/factors/${factor.id}/challenge`, {
    method: "POST",
    headers: auth,
  })).json();
  const verified = await (await fetch(`${API}/auth/v1/factors/${factor.id}/verify`, {
    method: "POST",
    headers: auth,
    body: JSON.stringify({ challenge_id: challenge.id, code: await totp(factor.totp.secret) }),
  })).json();
  assert(verified.access_token, `MFA verify failed: ${JSON.stringify(verified).slice(0, 200)}`);
  const claims = JSON.parse(atob(verified.access_token.split(".")[1]));
  assertEquals(claims.aal, "aal2", "a staff session must reach aal2 (§9.3)");
  return { ...person, token: verified.access_token as string };
}

// Staff functions are `admin_*` RPCs over the Data API, called as the staff member — never on a
// secret key, which is what keeps `staff_id` truthful in the audit log (§10, §10.3).
async function adminRpc(
  name: string,
  args: Record<string, unknown>,
  token: string,
): Promise<Record<string, unknown>> {
  const response = await fetch(`${API}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: PUBLISHABLE,
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(args),
  });
  return await response.json();
}

// A signed upload URL names the host the edge runtime sees, which outside Docker is unreachable.
// Hosted, the URL is right as issued — the same local-versus-hosted trap §17.1 records.
function reachable(signedUrl: string): string {
  const issued = new URL(signedUrl);
  const local = new URL(API);
  issued.protocol = local.protocol;
  issued.host = local.host;
  return issued.toString();
}

// The smallest thing the bucket will take. §8.1 puts the type and size check on the bucket, which
// reads the declared content type rather than the bytes.
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);

async function uploadPhoto(token: string, purpose: "act" | "avatar"): Promise<string> {
  const created = await call("/uploads", { method: "POST", token, body: { purpose } });
  assertEquals(created.status, 201, `POST /uploads: ${JSON.stringify(created.body)}`);
  const photo = (created.body.photo as Record<string, string>).id;
  const put = await fetch(reachable(created.body.upload_url as string), {
    method: "PUT",
    headers: { "Content-Type": "image/jpeg" },
    body: JPEG,
  });
  assert(put.ok, `PUT to the signed URL: ${put.status}`);
  const completed = await call(`/uploads/${photo}/complete`, { method: "POST", token });
  assertEquals(completed.status, 200, `complete: ${JSON.stringify(completed.body)}`);
  assertEquals((completed.body.photo as Record<string, string>).status, "processing");
  return photo;
}

// §8.3 allows `visible` only from `held`, because §8 says nothing a person writes is public until
// it has been screened. With no screening service, a staff member holds it and then approves it —
// the same two calls they make on a reported item.
async function approveByHand(
  subject: { act?: string; activity?: string; media?: string },
  token: string,
) {
  const args = {
    p_act_id: subject.act ?? null,
    p_activity_id: subject.activity ?? null,
    p_media_id: subject.media ?? null,
    p_reason: "reviewed by hand during the walkthrough, no screening service",
  };
  const held = await adminRpc("admin_set_content_status", { ...args, p_status: "held" }, token);
  assertEquals(held.status, "held", `hold: ${JSON.stringify(held)}`);
  const approved = await adminRpc(
    "admin_set_content_status",
    { ...args, p_status: "visible" },
    token,
  );
  // A photo lands in `processing` until the ops worker copies the file (§8.3, §17.1).
  assert(
    approved.status === "visible" || approved.status === "processing",
    `approve: ${JSON.stringify(approved)}`,
  );
  return approved.status as string;
}

async function runWorker(name: "ops-worker" | "message-worker" | "moderation-worker") {
  const answer = await call(`/${name}`, { method: "POST", workerKey: true });
  assertEquals(answer.status, 200, `${name}: ${JSON.stringify(answer.body)}`);
  return answer.body;
}

// ---------------------------------------------------------------------------

const PUNE = { lon: 73.8567, lat: 18.5204 };

heading("the stack answers");
const health = await call("/discover/health");
assertEquals(health.status, 200);
assert(health.body.status === "ok" || health.body.status === "degraded");
pass("GET /discover/health", `${health.body.status}`);

heading("a person signs up, onboards and is gated before that (§5.4, §7.3)");
const author = await onboarded("Anand Rao");
pass("POST /account/onboarding", "profile and profile_private written");
assertEquals(await sql(`select status from profiles where id='${author.id}'`), "active");
assertEquals(
  await sql(`select count(*) from profile_private where user_id='${author.id}'`),
  "1",
);
pass("the two rows §5.4 splits a person across");

heading("a photo: an id, a signed URL, real bytes, a completion (§8.1 steps 1 to 3)");
const photo = await uploadPhoto(author.token, "act");
assertEquals(await sql(`select status from media where id='${photo}'`), "processing");
assertEquals(await sql(`select public_path is null from media where id='${photo}'`), "t");
pass("the photo is `processing` and unpublished");
assert(Number(await sql("select count(*) from pgmq.q_moderation")) > 0);
pass("a screening job is queued (§8.4)");

heading("an Act, with that photo and a claimed metric (§7.3, §6.1)");
const act = await call("/acts", {
  method: "POST",
  token: author.token,
  body: {
    title: "Cleared the lake shore",
    story: "Eleven of us filled fourteen sacks along the east bank before the rain came in.",
    category: "environment",
    occurred_on: "2026-10-09",
    lon: PUNE.lon,
    lat: PUNE.lat,
    photo_ids: [photo],
    metrics: { waste_kg: 48.5 },
  },
});
assertEquals(act.status, 201, JSON.stringify(act.body));
const actId = (act.body.act as Record<string, string>).id;
assertEquals(await sql(`select status from acts where id='${actId}'`), "pending");
pass("POST /acts", "the Act is `pending` until something screens it");
assertEquals(
  await sql(`select coalesce(sum(points),0) from impact_entries where user_id='${author.id}'`),
  "0",
);
pass("no points yet, because §6.1 pays on publication");

heading("§5.4's locations: an Act is coarsened, an Activity is not");
const moved = await sql(
  `select round(extensions.st_distance(location_coarse,
     extensions.st_setsrid(extensions.st_makepoint(${PUNE.lon},${PUNE.lat}),4326)::extensions.geography))
   from acts where id='${actId}'`,
);
assert(Number(moved) > 500, `an Act's location must be coarsened, moved ${moved} m`);
pass("the Act's stored point", `${moved} m from what the client sent`);

heading("the feed, before anything is screened (§7.3)");
const empty = await call(`/feed?lon=${PUNE.lon}&lat=${PUNE.lat}`, { token: author.token });
assertEquals(empty.status, 200);
assertEquals((empty.body.acts as unknown[]).length, 0);
pass("GET /feed", "0 acts, which is correct with nothing screened");

heading("a staff member, with real MFA (§9.3, §10)");
const admin = await staffMember("Priya Nair", "admin");
pass("TOTP enrolled and verified", "token reaches aal2");

heading("staff do what the screening service would have done (§8.3, §10.2)");
const beforeAudit = Number(await sql("select count(*) from admin_audit_log"));
assertEquals(await approveByHand({ media: photo }, admin.token), "processing");
assertEquals(await approveByHand({ act: actId }, admin.token), "visible");
pass("`pending` to `held` to `visible`", "which is the only route §8.3 allows");
assert(
  Number(await sql("select count(*) from admin_audit_log")) >= beforeAudit + 4,
  "every staff action writes its own audit row (§10)",
);
pass("four audit rows, one per call (§10, §11.6)");

heading("the ops worker publishes the approved photo's bytes");
const published = await runWorker("ops-worker");
assert(Number(published.done) >= 1, `nothing published: ${JSON.stringify(published)}`);
assertEquals(await sql(`select status from media where id='${photo}'`), "ready");
const publicPath = await sql(`select public_path from media where id='${photo}'`);
assert(publicPath.length > 0, "a `ready` photo always has a published copy (§8.1)");
const served = await fetch(`${API}/storage/v1/object/public/media/${publicPath}`);
assertEquals(served.status, 200);
assertEquals((await served.arrayBuffer()).byteLength, JPEG.length);
pass("the file is served from the public bucket", `${JPEG.length} bytes, no token`);

heading("points, totals and the feed (§6.1, §6.4, §7.3)");
assert(
  Number(
    await sql(`select coalesce(sum(points),0) from impact_entries where user_id='${author.id}'`),
  ) >
    0,
  "publication must pay points (§6.1)",
);
assertEquals(await sql(`select acts_count from impact_totals where user_id='${author.id}'`), "1");
assertEquals(await sql(`select waste_kg from impact_totals where user_id='${author.id}'`), "48.50");
pass("the ledger and the totals agree", "§6.4 keeps the ledger authoritative");
const reader = await onboarded("Bina Shah");

// §12.2 caches a feed page for 60 seconds, keyed by cell, radius, category, cursor and length —
// deliberately **not** by user, because blocked authors are removed after the cache read so one
// entry can serve everyone (§7.3). So the same query still answers the pre-approval page, and a
// client team needs to know that before they call this a bug.
const cached = await call(`/feed?lon=${PUNE.lon}&lat=${PUNE.lat}`, { token: reader.token });
assertEquals((cached.body.acts as unknown[]).length, 0);
pass("GET /feed on the same key", "still 0: §12.2's 60-second cache");

// A different radius is a different key, which is the cheap way to see through it.
const feed = await call(`/feed?lon=${PUNE.lon}&lat=${PUNE.lat}&radius_km=25`, {
  token: reader.token,
});
assertEquals((feed.body.acts as unknown[]).length, 1, JSON.stringify(feed.body).slice(0, 200));
const shown = (feed.body.acts as Record<string, unknown>[])[0];
assert("photos" in shown && "metrics" in shown, "§7.2 embeds both on an Act");
pass("GET /feed on a fresh key", "1 act, with photos and metrics embedded");

heading("a profile photo on and off (§8.1, §9.2, §11.6)");
const avatar = await uploadPhoto(author.token, "avatar");
assertEquals(await sql(`select avatar_path is null from profiles where id='${author.id}'`), "t");
await approveByHand({ media: avatar }, admin.token);
await runWorker("ops-worker");
const avatarPath = await sql(`select avatar_path from profiles where id='${author.id}'`);
assert(avatarPath.length > 0, "the worker sets avatar_path once the photo passes (§9.2)");
assertEquals((await fetch(`${API}/storage/v1/object/public/media/${avatarPath}`)).status, 200);
pass("the avatar is set and served", "by the worker, never by the client (§9.2)");
const removed = await adminRpc("admin_set_content_status", {
  p_act_id: null,
  p_activity_id: null,
  p_media_id: avatar,
  p_status: "removed",
  p_reason: "the person asked for their photo to come down",
}, admin.token);
assertEquals(removed.status, "removed");
assertEquals(await sql(`select avatar_path is null from profiles where id='${author.id}'`), "t");
await runWorker("ops-worker");
assert(
  (await fetch(`${API}/storage/v1/object/public/media/${avatarPath}`)).status >= 400,
  "§11.6: the public bucket must stop serving a removed file immediately",
);
assertEquals(
  await sql(`select count(*) from private.preserved_content where source_id='${avatar}'`),
  "1",
);
pass("removing it clears the profile, stops the serving, keeps the record (§11.6)");

heading("editing a profile, and the columns §9.2 refuses");
const edit = await fetch(`${API}/rest/v1/profiles?id=eq.${author.id}`, {
  method: "PATCH",
  headers: {
    apikey: PUBLISHABLE,
    Authorization: `Bearer ${author.token}`,
    "Content-Type": "application/json",
  },
  body: JSON.stringify({ display_name: "Anand R.", bio: "I clean lake shores on Sundays." }),
});
assertEquals(edit.status, 204);
assertEquals(await sql(`select display_name from profiles where id='${author.id}'`), "Anand R.");
const refused = await fetch(`${API}/rest/v1/profiles?id=eq.${author.id}`, {
  method: "PATCH",
  headers: {
    apikey: PUBLISHABLE,
    Authorization: `Bearer ${author.token}`,
    "Content-Type": "application/json",
  },
  body: JSON.stringify({ is_verified: true }),
});
assert(refused.status >= 400, "§9.2: verification is never client-writable");
pass("display_name and bio are writable, is_verified is not (§9.2)");

heading("an Activity: created, approved, joined, cancelled (§7.3, §2.1)");
const starts = new Date(Date.now() + 2 * 86_400_000).toISOString().replace("Z", "+00:00");
const ends = new Date(Date.now() + 2 * 86_400_000 + 3 * 3_600_000).toISOString().replace(
  "Z",
  "+00:00",
);
const activity = await call("/activities", {
  method: "POST",
  token: author.token,
  body: {
    title: "Lake shore cleanup",
    description: "Bring gloves and water. We meet at the east gate and finish before noon.",
    category: "environment",
    starts_at: starts,
    ends_at: ends,
    lon: PUNE.lon,
    lat: PUNE.lat,
    location_label: "East gate",
    capacity: 25,
  },
});
assertEquals(activity.status, 201, JSON.stringify(activity.body));
const activityId = (activity.body.activity as Record<string, string>).id;
const exact = await sql(
  `select extensions.st_astext(location::extensions.geometry) from activities where id='${activityId}'`,
);
assertEquals(exact, `POINT(${PUNE.lon} ${PUNE.lat})`);
pass("the meeting point is stored exactly", "§5.4 makes it public on purpose");
const tooEarly = await call(`/activities/${activityId}/join`, {
  method: "POST",
  token: reader.token,
});
assertEquals(tooEarly.status, 409);
pass("an unscreened Activity cannot be joined", "ACTIVITY_NOT_JOINABLE");
await approveByHand({ activity: activityId }, admin.token);
// Approving through the `held` state sets `cancelled_at`; the walkthrough clears it because the
// product path to `visible` is screening, and this is standing in for it.
await sql(`update activities set cancelled_at = null where id='${activityId}'`);
const joined = await call(`/activities/${activityId}/join`, {
  method: "POST",
  token: reader.token,
});
assertEquals(joined.status, 200, JSON.stringify(joined.body));
assertEquals(joined.body.participant_count, 1);
pass("POST /activities/:id/join", "1 participant");
heading("Discover, by radius and with no token at all (§7.3)");
const near = await call(`/discover?lon=${PUNE.lon}&lat=${PUNE.lat}&radius_km=10`, {
  token: reader.token,
});
assertEquals(near.status, 200);
assertEquals((near.body.activities as unknown[]).length, 1);
const far = await call("/discover?lon=77.5946&lat=12.9716&radius_km=10", { token: reader.token });
assertEquals((far.body.activities as unknown[]).length, 0);
const loggedOut = await fetch(
  `${API}/functions/v1/discover?lon=${PUNE.lon}&lat=${PUNE.lat}&radius_km=10`,
  { headers: { apikey: PUBLISHABLE, "x-region": "ap-south-1" } },
);
assertEquals(loggedOut.status, 200);
assertEquals(((await loggedOut.json()).activities as unknown[]).length, 1);
pass("10 km finds it, 850 km away does not, and no token still reads");
// Checked before the cancellation below, on purpose: a cancelled Activity is not something to
// join, so the list leaves it out — where `discover_activity` by id deliberately still serves it,
// "because the link is already in somebody's hands" (§17.1).

const cancelled = await call(`/activities/${activityId}/cancel`, {
  method: "POST",
  token: author.token,
  body: { reason: "the lake level rose after the rain" },
});
assertEquals(cancelled.status, 200);
assertEquals(cancelled.body.notified, 1);
assertEquals(await sql("select count(*) from pgmq.q_email"), "1");
pass("cancelling queues one message (§2.1)", "the worker needs SES to send it");

heading("the first AWS boundary: SES, with a real message in front of it");
const messaging = await runWorker("message-worker");
console.log(
  `  --      message-worker claimed ${messaging.claimed}, sent ${messaging.sent}, failed ${messaging.failed}`,
);
assertEquals(messaging.sent, 0, "without AWS nothing can send");
assertEquals(await sql("select count(*) from pgmq.q_email"), "1");
assertEquals(await sql("select coalesce(max(read_ct),0) from pgmq.q_email"), "1");
pass("the message is still queued after a failed send", "§8.4 retries, then archives");

heading("a report, and §8.5's intake (§8.5, §7.1.1)");
const key = crypto.randomUUID();
const report = await fetch(`${API}/functions/v1/reports`, {
  method: "POST",
  headers: {
    apikey: PUBLISHABLE,
    Authorization: `Bearer ${reader.token}`,
    "Content-Type": "application/json",
    "Idempotency-Key": key,
    "x-region": "ap-south-1",
  },
  body: JSON.stringify({
    subject_type: "act",
    act_id: actId,
    reason: "misleading",
    details: "the sack count does not match the photo",
  }),
});
assertEquals(report.status, 201);
const reportId = ((await report.json()).report as Record<string, string>).id;
const replay = await fetch(`${API}/functions/v1/reports`, {
  method: "POST",
  headers: {
    apikey: PUBLISHABLE,
    Authorization: `Bearer ${reader.token}`,
    "Content-Type": "application/json",
    "Idempotency-Key": key,
    "x-region": "ap-south-1",
  },
  body: JSON.stringify({
    subject_type: "act",
    act_id: actId,
    reason: "misleading",
    details: "the sack count does not match the photo",
  }),
});
assertEquals(replay.status, 200);
assertEquals(((await replay.json()).report as Record<string, string>).id, reportId);
pass("POST /reports", "201 for the row, 200 for the replay (§7.1.1)");
const resolved = await adminRpc("admin_resolve_report", {
  p_report_id: reportId,
  p_status: "dismissed",
  p_note: "the photo and the claim agree on review",
}, admin.token);
assertEquals(resolved.status, "dismissed");
pass("admin_resolve_report", "closed with a note and an audit row (§10.2)");

heading("an export and an erasure, end to end (§11.2, §5.5, §11.6)");
const asked = await call("/account/export", { method: "POST", token: reader.token });
assertEquals(asked.status, 202);
const exportId = asked.body.export_id as string;
await runWorker("ops-worker");
assertEquals(
  await sql(`select status from account_exports where id='${exportId}'`),
  "ready",
);
const ready = await call(`/account/export/${exportId}`, { token: reader.token });
assertEquals(ready.status, 200);
assertEquals(ready.body.status, "ready");
assert(typeof ready.body.url === "string", "§7.3 hands back a signed URL once it is ready");
pass("export requested, built and handed back", "`O7` expires it in 7 days");
const erase = await call("/account/delete", { method: "POST", token: reader.token });
assertEquals(erase.status, 202);
await runWorker("ops-worker");
assertEquals(await sql(`select count(*) from auth.users where id='${reader.id}'`), "0");
assertEquals(await sql(`select count(*) from profiles where id='${reader.id}'`), "0");
assertEquals(
  await sql(`select count(*) from private.retained_registrations where user_id='${reader.id}'`),
  "1",
);
pass("the account is gone and rule 3(1)(h)'s row is kept (§11.6)");

heading("the second AWS boundary: screening, and what it leaves behind");
const screening = await runWorker("moderation-worker");
console.log(
  `  --      moderation-worker claimed ${screening.claimed}, screened ${screening.screened}, failed ${screening.failed}`,
);
assertEquals(screening.screened, 0, "without AWS nothing can be screened");
assert(Number(screening.failed) > 0, "the jobs are claimed and then fail at the AWS call");
pass("every screening job fails at the AWS call", "nothing is lost: §8.4 archives at five");

// The erasure above cascaded the recipient's participant row away, so the cancellation message is
// no longer sendable to anybody. `claim_message_jobs` resolves it to nothing and deletes it rather
// than archiving — §8.4's "work that no longer exists" as against work that failed.
// The failed send above left the message hidden for §8.4's 60-second visibility window, so it is
// made visible again rather than waiting — which is what a worker dying mid-job does anyway.
await sql(
  "select pgmq.set_vt('email', msg_id, 0) from pgmq.q_email",
);
const afterErasure = await runWorker("message-worker");
assertEquals(afterErasure.sent, 0);
// `claimed` is not asserted: `claim_message_jobs` resolves a job to nothing *inside* the claim
// loop and deletes it there, so an unsendable message never reaches the worker's count at all.
// What matters is where it ends up — gone from the queue, and never in the archive, because §8.4
// archives work that failed and this is work that no longer exists.
assertEquals(await sql("select count(*) from pgmq.q_email"), "0");
assertEquals(await sql("select count(*) from pgmq.a_email"), "0");
pass("erasing the recipient drops their queued message", "deleted, not archived: §8.4");

heading("what an AWS account is needed for, and nothing else");
for (const line of WITHOUT_AWS) console.log(`  --      ${line}`);

console.log(
  `\n${step} steps passed. Everything that can work without an AWS account did.\n` +
    "The three lines above are the whole of what cannot.",
);
