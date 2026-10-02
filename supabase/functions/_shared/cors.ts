import { cors } from "npm:hono@4.13.9/cors";
import {
  ALLOWED_HEADERS,
  ALLOWED_METHODS,
  ALLOWED_ORIGINS_VARIABLE,
  PREFLIGHT_MAX_AGE_SECONDS,
} from "./cors.constants.ts";

// §17 `O37`: the four route groups a browser reaches mount this. `sms-hook` does not —
// Supabase Auth is its caller — and neither do the workers, which the ops host's cron
// calls (§4.1).
//
// Hono's own middleware rather than headers written by hand: `hono` is already a §3.3
// dependency, and it answers the preflight and decorates the real response from one
// declaration. Nothing here logs, and an origin is a request header, not a body (§9.8).
export function browserOrigins() {
  // Read per request rather than at boot, so adding an origin is a secret change and
  // not a redeploy — and so a function with none set serves a native client exactly as
  // it did before `O37`.
  return cors({
    origin: (origin) => allowed().includes(origin) ? origin : null,
    allowHeaders: [...ALLOWED_HEADERS],
    allowMethods: [...ALLOWED_METHODS],
    maxAge: PREFLIGHT_MAX_AGE_SECONDS,
  });
}

function allowed(): string[] {
  return (Deno.env.get(ALLOWED_ORIGINS_VARIABLE) ?? "")
    .split(",")
    .map((origin) => origin.trim())
    .filter((origin) => origin.length > 0);
}
