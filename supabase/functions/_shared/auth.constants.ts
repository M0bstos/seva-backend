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
