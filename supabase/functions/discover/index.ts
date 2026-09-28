import { Hono } from "npm:hono@4.13.9";
import { optionalCaller } from "../_shared/auth.ts";
import { secretKeyClient } from "../_shared/db.ts";
import { fail, refusal } from "../_shared/errors.ts";
import {
  isCategory,
  isInt4,
  isIsoDate,
  isLatitude,
  isLongitude,
  isStorableText,
  isUuid,
} from "../_shared/fields.ts";
import { addressSubject, clientAddress, limitArgs } from "../_shared/limits.ts";
import {
  HEALTH_DEGRADED,
  HEALTH_OK,
  MAX_PAGE_LIMIT,
  SECRET_KEY_NAME,
} from "./discover.constants.ts";

// §7.3's five public routes. This is the only function §7.3 gives to logged-out
// callers — `anon` has no table grant at all (§9.1), so every anonymous read comes
// through here and is rate limited, which the Data API could not do.
//
// `verify_jwt = false` in config.toml, because the platform check would refuse a
// logged-out caller at the door (§7.3). A token that *is* sent still has to verify:
// `optionalCaller` answers UNAUTHENTICATED for one that does not, rather than
// quietly serving that person anonymously.
//
// Nothing here logs. §9.8's list carries coordinates and, since `O27`, IP addresses —
// and the address never reaches Postgres either: §12.2 keys the counter by an HMAC of
// it (`O26`, `_shared/limits.ts`).
const db = secretKeyClient(SECRET_KEY_NAME);

export const app = new Hono().basePath("/discover");

// §12.5: `{"status":"ok"}` or `{"status":"degraded"}` "and nothing else — never
// details", with the status code saying why (below). Exempt from the limiter, and
// cached for 30 seconds inside `health_status()`, because §12.5 now points two Route
// 53 checks here, each every 30 seconds from three regions.
app.get("/health", async () => {
  const { data, error } = await db.rpc("health_status");

  // Two signals, one route. Owner decision, 28 September 2026: a 503 means this route
  // could not get an answer out of the database at all — unreachable, refused,
  // timed out — because §12.5 also points Route 53 here and §12.4 has the app show
  // its offline state when the check fails. A report waiting for a moderator would
  // otherwise take the app's banner down while every route was serving, so a §10.4
  // backlog answers 200 with `degraded`. §12.5 names two Route 53 checks for that
  // reason: a plain HTTPS one for availability, and a string match on `ok` that this
  // body fails while still answering 200.
  //
  // The error is not logged: the 503 is what Route 53 counts, three in a row.
  if (error) return Response.json(HEALTH_DEGRADED, { status: 503 });
  return Response.json(data === "degraded" ? HEALTH_DEGRADED : HEALTH_OK);
});

// §7.3 `GET /discover`: nearby upcoming Activities.
app.get("/", async (c) => {
  const subject = await whoIsAsking(c.req.raw);
  if (subject instanceof Response) return subject;

  const query = c.req.query();
  const point = geography(query);
  if (typeof point === "string") return fail("VALIDATION_FAILED", point);

  const page = pageOf(query);
  if (typeof page === "string") return fail("VALIDATION_FAILED", page);

  if (query.category !== undefined && !isCategory(query.category)) {
    return fail("VALIDATION_FAILED", "category");
  }
  if (query.from !== undefined && !isIsoDate(query.from)) return fail("VALIDATION_FAILED", "from");
  if (query.to !== undefined && !isIsoDate(query.to)) return fail("VALIDATION_FAILED", "to");

  return await answer("discover_activities", {
    p_lon: point.lon,
    p_lat: point.lat,
    p_radius_km: point.radiusKm,
    p_category: query.category ?? null,
    p_from: query.from ?? null,
    p_to: query.to ?? null,
    p_cursor: page.cursor,
    p_limit: page.limit,
    ...limitArgs("discover", subject.bucket, subject.userId),
  });
});

// §7.3 `GET /discover/campaigns`: active campaigns with progress.
app.get("/campaigns", async (c) => {
  const subject = await whoIsAsking(c.req.raw);
  if (subject instanceof Response) return subject;

  const page = pageOf(c.req.query());
  if (typeof page === "string") return fail("VALIDATION_FAILED", page);

  return await answer("discover_campaigns", {
    p_cursor: page.cursor,
    p_limit: page.limit,
    ...limitArgs("discover.campaigns", subject.bucket, subject.userId),
  });
});

// §7.3 `GET /discover/campaigns/:id`: one campaign, for shared links.
app.get("/campaigns/:id", async (c) => {
  const subject = await whoIsAsking(c.req.raw);
  if (subject instanceof Response) return subject;

  const id = c.req.param("id");
  if (!isUuid(id)) return fail("VALIDATION_FAILED", "id");

  return await answer("discover_campaign", {
    p_campaign_id: id,
    ...limitArgs("discover.campaign", subject.bucket, subject.userId),
  });
});

// §7.3 `GET /discover/activities/:id`: one Activity, for shared links.
app.get("/activities/:id", async (c) => {
  const subject = await whoIsAsking(c.req.raw);
  if (subject instanceof Response) return subject;

  const id = c.req.param("id");
  if (!isUuid(id)) return fail("VALIDATION_FAILED", "id");

  return await answer("discover_activity", {
    p_activity_id: id,
    ...limitArgs("discover.activity", subject.bucket, subject.userId),
  });
});

// Who the limiter counts this request against, and who the block filter runs for.
// §12.2: a user ID when there is a session, and otherwise an HMAC of the address, so
// no raw address ever reaches Postgres (`O26`).
async function whoIsAsking(
  request: Request,
): Promise<{ bucket: string; userId: string | null } | Response> {
  const userId = await optionalCaller(db, request.headers.get("Authorization") ?? undefined);
  if (userId instanceof Response) return userId;
  return userId === null
    ? { bucket: await addressSubject(clientAddress(request.headers)), userId: null }
    : { bucket: userId, userId };
}

async function answer(fn: string, args: Record<string, unknown>): Promise<Response> {
  const { data, error } = await db.rpc(fn, args);
  // The Postgres error is not logged: its DETAIL can carry the coordinates the
  // request came with, which §9.8 keeps out of logs. The 5xx is the signal (§12.5).
  if (error) return fail("INTERNAL");

  const payload = data as Record<string, unknown>;
  return refusal(payload) ?? Response.json(payload);
}

// The name of the field that is wrong, or the point and radius to search from.
function geography(
  query: Record<string, string>,
): { lon: number; lat: number; radiusKm: number | null } | string {
  const lon = Number(query.lon);
  const lat = Number(query.lat);
  if (query.lon === undefined || !isLongitude(lon)) return "lon";
  if (query.lat === undefined || !isLatitude(lat)) return "lat";

  if (query.radius_km === undefined) return { lon, lat, radiusKm: null };
  const radiusKm = Number(query.radius_km);
  // What the `int` column can take, and nothing narrower: which rung the number
  // lands on is `discover_activities`' rule, so 100 snaps to 50 and 0 to 2 rather
  // than being refused here. Outside int4 it is uncastable, and measured, that raise
  // beats the limiter to it.
  if (!isInt4(radiusKm)) return "radius_km";
  return { lon, lat, radiusKm };
}

// §7.1: "an opaque `cursor`, `limit` ≤ 50". The cursor is opaque here too — it is
// passed through, and the Postgres function that issued it is what decodes it, which
// answers VALIDATION_FAILED for anything that does not.
//
// Opaque to the client, though, not to Postgres: `%00` survives query decoding as a
// real NUL, and a NUL reaching the `text` parameter raises 22P05 *before* that
// decode runs — measured, a retryable 500 that the limiter never counted, on the one
// route that is both unauthenticated and bucketed by `O26`'s per-address hash, with a
// slice of the payload logged against §9.8. So the one thing checked here is what
// Postgres can hold, not what the cursor should look like: its format belongs to the
// function that issues it.
function pageOf(
  query: Record<string, string>,
): { cursor: string | null; limit: number | null } | string {
  if (query.cursor !== undefined && !isStorableText(query.cursor)) return "cursor";
  if (query.limit === undefined) return { cursor: query.cursor ?? null, limit: null };

  const limit = Number(query.limit);
  // §7.1 states the ceiling, so the route names the field for it. It states no floor,
  // and the function clamps, so `limit=0` is a page of one rather than a refusal —
  // but a value outside int4 is uncastable and has to be refused here.
  if (!isInt4(limit) || limit > MAX_PAGE_LIMIT) return "limit";
  return { cursor: query.cursor ?? null, limit };
}

// §7.1 gives every function error one shape, which includes the two Hono would
// otherwise answer itself. A path this function does not serve is "missing" (§7.4),
// and an unexpected throw must not reach a client as a stack trace — §9.8 keeps
// request content out of anything we emit, and the 5xx is what §12.5 counts.
app.notFound(() => fail("NOT_FOUND"));
app.onError(() => fail("INTERNAL"));

if (import.meta.main) Deno.serve(app.fetch);
