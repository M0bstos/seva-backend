import { Hono } from "npm:hono@4.13.9";
import { requiredCaller } from "../_shared/auth.ts";
import { secretKeyClient } from "../_shared/db.ts";
import { browserOrigins } from "../_shared/cors.ts";
import { fail, refusal } from "../_shared/errors.ts";
import { isCategory, isInt4, isLatitude, isLongitude, isStorableText } from "../_shared/fields.ts";
import { limitArgs } from "../_shared/limits.ts";
import { MAX_PAGE_LIMIT, SECRET_KEY_NAME } from "./feed.constants.ts";

// §7.3 `GET /feed`: "Recent visible Acts nearby", for a signed-in caller. One route,
// one Postgres call — the limiter, the 60-second cache, the radius snap and the
// removal of blocked authors all live in `feed_acts` (§12.2, §7.3).
//
// `verify_jwt = true` in config.toml and the handler still calls getClaims(): the
// platform check proves a token was signed by this project, and §9.2 needs the user
// id out of the verified claims rather than from anything the caller sent.
//
// Nothing here logs; §9.8's list carries coordinates.
const db = secretKeyClient(SECRET_KEY_NAME);

export const app = new Hono().basePath("/feed");

// §17 `O37`: §4.1's app is "iOS · Android · web", so a browser preflights every call
// here — §7.1 puts `apikey` on all of them. Before routing, so an OPTIONS is answered
// rather than falling through to the 404 below.
app.use("*", browserOrigins());

app.get("/", async (c) => {
  const userId = await requiredCaller(db, c.req.header("Authorization"));
  if (userId instanceof Response) return userId;

  const asked = readQuery(c.req.query());
  if (typeof asked === "string") return fail("VALIDATION_FAILED", asked);

  const { data, error } = await db.rpc("feed_acts", {
    p_lon: asked.lon,
    p_lat: asked.lat,
    p_radius_km: asked.radiusKm,
    p_category: asked.category,
    p_cursor: asked.cursor,
    p_limit: asked.limit,
    ...limitArgs("feed", userId, userId),
  });
  // The Postgres error is not logged: its DETAIL can carry the coordinates the
  // request came with, which §9.8 keeps out of logs. The 5xx is the signal (§12.5).
  if (error) return fail("INTERNAL");

  const payload = data as Record<string, unknown>;
  return refusal(payload) ?? Response.json(payload);
});

// Exported for the tests. Unlike `discover`, every path here is behind a session, so
// a test cannot reach validation through `app.request()` without a token — the same
// reason `acts` and `activities` export their own.
//
// The query as `feed_acts` takes it, or the name of the field that is wrong. The
// radius rung and the page length are both snapped or clamped inside that function
// (§7.3, §17.1); what this settles is the shape, so §7.4's message can name a field.
export function readQuery(
  query: Record<string, string>,
): {
  lon: number;
  lat: number;
  radiusKm: number | null;
  category: string | null;
  cursor: string | null;
  limit: number | null;
} | string {
  const lon = Number(query.lon);
  const lat = Number(query.lat);
  if (query.lon === undefined || !isLongitude(lon)) return "lon";
  if (query.lat === undefined || !isLatitude(lat)) return "lat";

  let radiusKm: number | null = null;
  if (query.radius_km !== undefined) {
    radiusKm = Number(query.radius_km);
    // What the `int` column takes. Which rung it lands on is `feed_acts`' rule, so
    // 2 km snaps to O30's 5 km cell; outside int4 it raises before the limiter.
    if (!isInt4(radiusKm)) return "radius_km";
  }

  let limit: number | null = null;
  if (query.limit !== undefined) {
    limit = Number(query.limit);
    if (!isInt4(limit) || limit > MAX_PAGE_LIMIT) return "limit";
  }

  if (query.category !== undefined && !isCategory(query.category)) return "category";

  // Opaque to the client, not to Postgres: `%00` survives query decoding, and a NUL
  // reaching the `text` parameter raises before `private.decode_cursor` can answer
  // VALIDATION_FAILED for it (§9.8, §12.2). Only what Postgres can hold is checked
  // here; the cursor's format belongs to the function that issues it.
  if (query.cursor !== undefined && !isStorableText(query.cursor)) return "cursor";

  return {
    lon,
    lat,
    radiusKm,
    category: query.category ?? null,
    cursor: query.cursor ?? null,
    limit,
  };
}

// §7.1 gives every function error one shape, which includes the two Hono would
// otherwise answer itself. A path this function does not serve is "missing" (§7.4),
// and an unexpected throw must not reach a client as a stack trace — §9.8 keeps
// request content out of anything we emit, and the 5xx is what §12.5 counts.
app.notFound(() => fail("NOT_FOUND"));
app.onError(() => fail("INTERNAL"));

if (import.meta.main) Deno.serve(app.fetch);
