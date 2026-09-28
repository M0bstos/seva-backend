import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.116.0";

// §9.5 gives every function and worker its own secret key, so any one can be revoked
// alone. The platform injects them as a JSON dictionary keyed by name, and a function
// names its own entry — the name, never the key, is what appears in this repo.
export function secretKeyClient(keyName: string): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const keys = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (!url) throw new Error("SUPABASE_URL is not set");
  if (!keys) throw new Error("SUPABASE_SECRET_KEYS is not set");

  // The local stack and CI inject one key named `default` and will not let a
  // `.env` override a `SUPABASE_`-prefixed name — measured against
  // supabase-edge-runtime 1.74.3, with and without `--env-file` — so without a
  // fallback no route runs outside a hosted project and §13.1's API tests could
  // never run one.
  //
  // The fallback is gated on the project URL being a local one, so it is the code
  // and not a convention that keeps it out of production. §9.5 buys exactly one
  // property — "any single key can be revoked alone" — and a fallback reachable on
  // a hosted project would quietly undo it: revoking a leaked key would leave the
  // function serving on `default`, and a rotation that removed the old entry before
  // adding the new one would fail open instead of at boot.
  const dictionary = JSON.parse(keys) as Record<string, string>;
  const key = dictionary[keyName] ?? (isLocal(url) ? dictionary.default : undefined);
  if (!key) throw new Error(`SUPABASE_SECRET_KEYS has no entry named ${keyName}`);

  // Nothing here is a browser: a persisted session would be shared between requests.
  return createClient(url, key, { auth: { persistSession: false } });
}

// A hosted project is always `https://<ref>.supabase.co`. `kong` is the hostname the
// local stack injects for its own gateway; the two loopback forms are what
// `supabase functions serve` and the API tests use.
function isLocal(url: string): boolean {
  const { hostname, protocol } = new URL(url);
  return protocol === "http:" &&
    (hostname === "kong" || hostname === "127.0.0.1" || hostname === "localhost");
}
