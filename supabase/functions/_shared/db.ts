import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.116.0";

// §9.5 gives every function and worker its own secret key, so any one can be revoked
// alone. The platform injects them as a JSON dictionary keyed by name, and a function
// names its own entry — the name, never the key, is what appears in this repo.
export function secretKeyClient(keyName: string): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const keys = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (!url) throw new Error("SUPABASE_URL is not set");
  if (!keys) throw new Error("SUPABASE_SECRET_KEYS is not set");

  const key = (JSON.parse(keys) as Record<string, string>)[keyName];
  if (!key) throw new Error(`SUPABASE_SECRET_KEYS has no entry named ${keyName}`);

  // Nothing here is a browser: a persisted session would be shared between requests.
  return createClient(url, key, { auth: { persistSession: false } });
}
