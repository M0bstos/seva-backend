// The algorithms `getClaims()` can actually verify. §9.3 says "Asymmetric JWT signing
// keys; functions verify with `getClaims()`", and the second clause is the binding
// one: auth-js 2.116.0's `getAlgorithm` is a switch over RS256 and ES256 and throws
// on everything else, which matches the two key types Supabase's signing keys offer.
//
// An allow-list rather than a deny-list, because a deny-list on `HS` misses `hs256`,
// `Hs256` and `none`, each of which still reaches the Auth round trip the list exists
// to avoid — measured at two outbound calls each. And only these two, because the
// eight other asymmetric JWS algorithms cost the same round trips while never being
// verifiable. If Supabase ever signs with a third, this list is the one line to
// change, and the symptom would be a 401 rather than anything silent-but-accepted.
export const VERIFIABLE_ALGORITHMS = ["RS256", "ES256"] as const;

// §17 `O31`. Measured from auth-js 2.116.0's own source, 1 October 2026: `fetchJwk`
// returns a cached key only when the `kid` is present *and* the cache is under
// `JWKS_TTL` (10 minutes); on any miss it fetches `/.well-known/jwks.json` again, with
// no negative cache and no cooldown, and `getClaims` then falls back to `getUser()`.
// So a token bearing an unknown `kid` with a future `exp` costs **two outbound round
// trips per rejected request**, chosen by the caller, on a path reachable with only
// the publishable key. §12.2's D5 note budgets a rejected request at "one cheap
// indexed write", and §17.1 puts the limiter's count inside the route's Postgres
// function, after the token check — so nothing meters this.
//
// Caching the miss by `kid` does not help: the caller picks the `kid`, so they vary
// it. What bounds it is knowing the valid set, which is why `_shared/auth.ts` holds
// the JWKS itself and hands it to `getClaims`.
//
// The TTL is how long a set is trusted without asking again; the cooldown is how often
// an unknown `kid` is allowed to make it ask. A flood therefore costs one fetch per
// cooldown rather than two per request, and a genuine key rotation is picked up within
// the cooldown rather than within the TTL.
export const JWKS_TTL_MS = 10 * 60 * 1000;
export const JWKS_MISS_COOLDOWN_MS = 60 * 1000;

export const JWKS_PATH = "/auth/v1/.well-known/jwks.json";
