import { isAuthRetryableFetchError, type SupabaseClient } from "npm:@supabase/supabase-js@2.116.0";
import { VERIFIABLE_ALGORITHMS } from "./auth.constants.ts";
import { fail } from "./errors.ts";

// Only the one method is needed, and naming it keeps the verifier substitutable in
// tests without casting a whole client.
type ClaimsVerifier = { auth: Pick<SupabaseClient["auth"], "getClaims"> };

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
  if (!looksLikeOurToken(bearer[1])) return null;

  const claims = await verifyClaims(db, bearer[1]);
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
// A token naming an allowed algorithm with a `kid` this project never issued still
// reaches that fallback; see `O31`. It cannot be refused here without knowing which
// keys are current, which is the JWKS fetch itself.
function looksLikeOurToken(token: string): boolean {
  const encoded = token.split(".")[0];
  if (!encoded) return false;
  try {
    const header = JSON.parse(
      atob(encoded.replace(/-/g, "+").replace(/_/g, "/")),
    ) as Record<string, unknown>;
    const { alg, kid } = header;
    return typeof alg === "string" &&
      (VERIFIABLE_ALGORITHMS as readonly string[]).includes(alg) &&
      typeof kid === "string" && kid.length > 0;
  } catch {
    return false;
  }
}

async function verifyClaims(db: ClaimsVerifier, token: string) {
  let result;
  try {
    result = await db.auth.getClaims(token);
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
