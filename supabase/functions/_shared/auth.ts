import {
  isAuthRetryableFetchError,
  type JWK,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.116.0";
import {
  JWKS_MISS_COOLDOWN_MS,
  JWKS_PATH,
  JWKS_TTL_MS,
  VERIFIABLE_ALGORITHMS,
} from "./auth.constants.ts";
import { fail } from "./errors.ts";

// Only the one method is needed, and naming it keeps the verifier substitutable in
// tests without casting a whole client.
type ClaimsVerifier = { auth: Pick<SupabaseClient["auth"], "getClaims"> };

// §17 `O31`, decided during the build: **cache the miss, by holding the JWKS here.**
// The constants file carries the measurement — an unknown `kid` with a future `exp`
// costs two outbound round trips per rejected request, caller-chosen, unmetered.
//
// Per isolate, not per client, because that is the lifetime the cost is per. The set
// is refreshed when it is stale, and at most once per cooldown when a `kid` arrives
// that it does not hold. A caller flooding distinct `kid`s therefore pays one fetch
// per cooldown instead of two round trips each, and a genuine key rotation is picked
// up within the cooldown rather than within the TTL.
let keys: JWK[] = [];
let fetchedAt = 0;

// Exported for the tests, which need an isolate that has never fetched.
export function forgetJwks() {
  keys = [];
  fetchedAt = 0;
}

async function signingKeys(kid: string): Promise<JWK[]> {
  const now = Date.now();
  const known = keys.some((key) => key.kid === kid);
  const stale = now - fetchedAt > JWKS_TTL_MS;
  const askedRecently = now - fetchedAt < JWKS_MISS_COOLDOWN_MS;

  // A `kid` the set holds needs nothing: `getClaims` verifies against what it is
  // given, with no network call of its own. A `kid` it does not hold is worth one
  // fetch, unless one was just made — the attacker controls the `kid`, so without
  // that bound they control the fetch rate.
  if (known && !stale) return keys;
  if (!known && askedRecently && fetchedAt !== 0) return keys;

  const url = Deno.env.get("SUPABASE_URL");
  if (!url) throw new Error("SUPABASE_URL is not set");

  // A failure here is a transport failure, which the callers answer INTERNAL rather
  // than 401: telling every signed-in person to sign in again for the length of an
  // outage is what `O32` is the alarm for. The previous set is not discarded.
  const answer = await fetch(`${url}${JWKS_PATH}`);
  if (!answer.ok) throw new Error("the signing keys could not be fetched");
  const body = await answer.json() as { keys?: JWK[] };
  if (!Array.isArray(body.keys) || body.keys.length === 0) {
    throw new Error("the signing keys could not be read");
  }

  keys = body.keys;
  fetchedAt = now;
  return keys;
}

// §9.2: the user id comes from the verified token and never from the request body.
// §9.3 signs tokens asymmetrically, so getClaims verifies against the project's JWKS.
// Nothing here is logged — a token is on §9.8's list.
//
// null means no valid session, which the route answers with UNAUTHENTICATED. Only a
// transport failure while verifying a token this project could have issued is raised,
// for the route to answer INTERNAL (§7.4): answering 401 for that would tell every
// signed-in person to sign in again for the length of the outage.
export async function verifiedUserId(
  db: ClaimsVerifier,
  authorization: string | undefined,
): Promise<string | null> {
  const bearer = authorization?.match(/^Bearer (\S+)$/);
  if (!bearer) return null;

  const kid = ourTokenKid(bearer[1]);
  if (!kid) return null;

  const claims = await verifyClaims(db, bearer[1], kid);
  if (!claims) return null;

  const sub = claims.sub;
  return typeof sub === "string" && sub.length > 0 ? sub : null;
}

// §9.3 has the project sign asymmetrically and verify with getClaims(), so every
// token it issues names an algorithm getClaims can verify, and a `kid`. getClaims cannot verify anything else locally: it
// falls back to an Auth round trip, and a 5xx from there is indistinguishable from a
// real outage — which would let a caller amplify 500s by declaring HS256. Rejecting
// those here costs no network call at all, which is also what makes a flood cheap.
//
// A token naming an allowed algorithm with a `kid` this project never issued used to
// reach that fallback on every request. `O31` is closed: `signingKeys` holds the set
// and bounds how often an unknown `kid` may make it ask again.
function ourTokenKid(token: string): string | null {
  const encoded = token.split(".")[0];
  if (!encoded) return null;
  try {
    const header = JSON.parse(
      atob(encoded.replace(/-/g, "+").replace(/_/g, "/")),
    ) as Record<string, unknown>;
    const { alg, kid } = header;
    const verifiable = typeof alg === "string" &&
      (VERIFIABLE_ALGORITHMS as readonly string[]).includes(alg);
    return verifiable && typeof kid === "string" && kid.length > 0 ? kid : null;
  } catch {
    return null;
  }
}

async function verifyClaims(db: ClaimsVerifier, token: string, kid: string) {
  // Outside the try, deliberately. A JWKS that cannot be fetched is a transport
  // failure for the callers to answer INTERNAL; swallowed here it would read as "this
  // token does not verify" and answer 401 to every signed-in person for the length of
  // the outage, which is exactly what `O32` is the alarm for.
  const current = await signingKeys(kid);

  let result;
  try {
    // The set is passed in, so `getClaims` never fetches: auth-js checks the supplied
    // keys first and returns immediately when the `kid` is there. When it is not, the
    // verification fails locally and the `getUser()` fallback is the one round trip —
    // which is the cost `O31` bounds rather than removes.
    result = await db.auth.getClaims(token, { keys: current });
  } catch {
    // getClaims resolves every auth error and re-throws only what is not one, so
    // nothing reaching here is a transport fault: a token whose parts do not decode
    // raises a plain Error, and a header naming an algorithm the project does not
    // sign with makes Web Crypto refuse the project's own key with a DOMException
    // that looks identical to a broken key. The caller picks the header, so an
    // ambiguous fault on a caller-controlled path is the caller's — calling it ours
    // would let anyone holding the publishable key mint 500s and trip §12.5's alarm.
    return null;
  }

  if (isAuthRetryableFetchError(result.error)) throw result.error;
  return result.error || !result.data ? null : result.data.claims;
}

// The two ways a route asks who is calling. Both answer either a user id or the
// Response to send as it stands, so a handler's first line is the same everywhere
// (§13.4) and no route invents its own reading of §7.4.

// For the routes §7.3 gives to "Signed in" or "Onboarded".
export async function requiredCaller(
  db: ClaimsVerifier,
  authorization: string | undefined,
): Promise<string | Response> {
  return await optionalCaller(db, authorization) ?? fail("UNAUTHENTICATED");
}

// For the four `discover` routes, which §7.3 gives to "Anyone". No header means an
// anonymous caller, which §12.2 counts by address instead (`O26`). A header that does
// not verify is **not** anonymous: §7.4 has UNAUTHENTICATED for "No valid session",
// and serving that caller anonymously would hide a broken session from them.
export async function optionalCaller(
  db: ClaimsVerifier,
  authorization: string | undefined,
): Promise<string | null | Response> {
  if (authorization === undefined) return null;
  try {
    return await verifiedUserId(db, authorization) ?? fail("UNAUTHENTICATED");
  } catch {
    // Only a transport failure while verifying a token this project could have issued
    // reaches here. Answering 401 would tell every signed-in person to sign in again
    // for the length of the outage, which `O32` is the alarm for.
    return fail("INTERNAL");
  }
}
