import { assertEquals, assertRejects } from "jsr:@std/assert@1.0.19";
import { AuthRetryableFetchError } from "npm:@supabase/supabase-js@2.116.0";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.116.0";
import { verifiedUserId } from "./auth.ts";
import { VERIFIABLE_ALGORITHMS } from "./auth.constants.ts";

type Verifier = { auth: Pick<SupabaseClient["auth"], "getClaims"> };
type Result = Awaited<ReturnType<SupabaseClient["auth"]["getClaims"]>>;

const USER = "11111111-1111-1111-1111-111111111111";

// getClaims resolves a header and a raw signature alongside the claims; the stub
// only ever feeds the one field verifiedUserId reads, hence the widening.
function verifier(
  outcome: {
    claims?: Record<string, unknown>;
    fails?: boolean;
    throws?: Error;
    returnsError?: Error;
  },
) {
  const seen: string[] = [];
  const stub: Verifier & { seen: string[] } = {
    seen,
    auth: {
      getClaims: (jwt?: string): Promise<Result> => {
        if (jwt !== undefined) seen.push(jwt);
        if (outcome.throws) throw outcome.throws;
        const answer = outcome.returnsError
          ? { data: null, error: outcome.returnsError }
          : outcome.fails
          ? { data: null, error: new Error("signature does not verify") }
          : { data: { claims: outcome.claims }, error: null };
        return Promise.resolve(answer as unknown as Result);
      },
    },
  };
  return stub;
}

Deno.test("a verified token yields its subject", async () => {
  const v = verifier({ claims: { sub: USER, role: "authenticated" } });
  assertEquals(await verifiedUserId(v, token({ alg: "ES256", kid: "k1" })), USER);
  assertEquals(v.seen.length, 1);
});

Deno.test("no header, a blank one or the wrong scheme never reaches verification", async () => {
  for (const header of [undefined, "", "abc.def.ghi", "Basic abc", "Bearer", "Bearer "]) {
    const v = verifier({ claims: { sub: USER } });
    assertEquals(await verifiedUserId(v, header), null, JSON.stringify(header));
    assertEquals(v.seen, [], "a malformed header is rejected before the JWKS check");
  }
});

Deno.test("a token that fails verification is not a user", async () => {
  assertEquals(
    await verifiedUserId(verifier({ fails: true }), token({ alg: "ES256", kid: "k1" })),
    null,
  );
});

// A token shaped like a JWT whose parts do not decode makes getClaims raise rather
// than return, and an unauthenticated caller must still get 401 and not a retryable
// 500 (§7.4). "Bearer aaa.bbb.ccc" is the real case, measured against auth-js 2.116.0.
Deno.test("a token that raises instead of returning is not a user either", async () => {
  const decodeFault = new Error("Invalid UTF-8 sequence");
  assertEquals(await verifiedUserId(verifier({ throws: decodeFault }), "Bearer aaa.bbb.ccc"), null);
});

const b64 = (value: unknown) =>
  btoa(JSON.stringify(value)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const token = (header: Record<string, unknown>) =>
  `Bearer ${b64(header)}.${b64({ sub: USER, exp: 9999999999 })}.AAAA`;

// §9.3 gives the project asymmetric keys, so a token naming HS256 or carrying no kid
// is not one it issued. getClaims cannot verify those locally and falls back to an
// Auth round trip whose 5xx is indistinguishable from a real outage — so they are
// refused here, before any network call is made.
Deno.test("a token this project could not have issued never reaches the verifier", async () => {
  for (
    const header of [
      { alg: "HS256", typ: "JWT" },
      { alg: "HS512", typ: "JWT", kid: "k" },
      // A deny-list on "HS" misses each of these, and every one still reaches the
      // Auth round trip the check exists to avoid.
      { alg: "hs256", typ: "JWT", kid: "k" },
      { alg: "Hs256", typ: "JWT", kid: "k" },
      { alg: "none", typ: "JWT", kid: "k" },
      { alg: "", typ: "JWT", kid: "k" },
      { alg: 256, typ: "JWT", kid: "k" },
      { alg: "ES256", typ: "JWT", kid: 7 },
      // Asymmetric, but not something getClaims can verify.
      { alg: "EdDSA", typ: "JWT", kid: "k" },
      { alg: "PS256", typ: "JWT", kid: "k" },
      { alg: "ES384", typ: "JWT", kid: "k" },
      { alg: "ES256", typ: "JWT" },
      { alg: "ES256", typ: "JWT", kid: "" },
      { typ: "JWT", kid: "k" },
    ]
  ) {
    const v = verifier({ claims: { sub: USER } });
    assertEquals(await verifiedUserId(v, token(header)), null, JSON.stringify(header));
    assertEquals(v.seen, [], "and costs no round trip");
  }
});

Deno.test("a header that is not decodable JSON is refused the same way", async () => {
  for (const bad of ["Bearer !!!.bbb.ccc", "Bearer aaa.bbb.ccc", "Bearer .b.c"]) {
    const v = verifier({ claims: { sub: USER } });
    assertEquals(await verifiedUserId(v, bad), null, bad);
    assertEquals(v.seen, []);
  }
});

Deno.test("a token shaped like this project's does reach the verifier", async () => {
  for (const alg of VERIFIABLE_ALGORITHMS) {
    const v = verifier({ claims: { sub: USER } });
    assertEquals(await verifiedUserId(v, token({ alg, typ: "JWT", kid: "k1" })), USER, alg);
    assertEquals(v.seen.length, 1);
  }
});

// §9.3's binding clause is "functions verify with `getClaims()`", and getAlgorithm in
// auth-js 2.116.0 is a switch over exactly these two. The other eight asymmetric JWS
// algorithms cost the same Auth round trips while never being verifiable.
Deno.test("the allowed algorithms are the ones getClaims can verify, and only those", () => {
  assertEquals([...VERIFIABLE_ALGORITHMS].sort(), ["ES256", "RS256"]);
});

// The one fault that is unambiguously ours. getClaims resolves every auth error
// rather than throwing it — measured against an unreachable Auth host — so this is
// the branch that actually fires in production, and the thrown one was dead.
Deno.test("a transport failure verifying a plausible token is raised, not a 401", async () => {
  const outage = new AuthRetryableFetchError("network error", 0);
  await assertRejects(
    () =>
      verifiedUserId(
        verifier({ returnsError: outage }),
        token({ alg: "ES256", kid: "k1" }),
      ),
    AuthRetryableFetchError,
  );
});

// And a fault that arrives by being thrown is not one of those, so it is a 401.
Deno.test("anything getClaims throws is the caller's token, not our transport", async () => {
  for (
    const thrown of [
      new Error("Invalid UTF-8 sequence"),
      new DOMException("'kty' property of JsonWebKey must be 'RSA'", "DataError"),
    ]
  ) {
    assertEquals(
      await verifiedUserId(verifier({ throws: thrown }), token({ alg: "ES256", kid: "k1" })),
      null,
      thrown.constructor.name,
    );
  }
});

Deno.test("verified claims without a usable subject are not a user", async () => {
  for (const claims of [{}, { sub: "" }, { sub: 7 }, { role: "service_role" }]) {
    const v = verifier({ claims });
    assertEquals(
      await verifiedUserId(v, token({ alg: "ES256", kid: "k1" })),
      null,
      JSON.stringify(claims),
    );
  }
});
