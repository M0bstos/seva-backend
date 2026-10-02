// §17 `O37`, decided during the build: **yes, a browser calls these functions.** §4.1's
// own diagram labels the citizen app "iOS · Android · web", which is the thing the open
// item said the spec did not say — it does, in the figure rather than the prose.
//
// Two things measured against the hosted staging project, 2 October 2026:
//
//   * A CORS preflight **reaches the function**, even on one with `verify_jwt = true`
//     and with neither `Authorization` nor `apikey` on the request. The platform does
//     not reject it, so in-function handling is enough and nothing has to change about
//     §7.3's `verify_jwt` settings.
//   * Today every function answers that preflight with its own §7.1 `NOT_FOUND` — the
//     404 body is `{"error":{"code":"NOT_FOUND"…}}`, Hono's unrouted-path answer, not
//     the platform's. So `O37`'s premise held: **every** browser call fails, because
//     §7.1 puts `apikey` on every request and a custom header forces a preflight.

// An allow-list, not `*`. Without cookies CORS is not a security control here — a
// publishable key works from anywhere — so what the list buys is that the browser
// surface is a decision somebody made and can review, rather than a standing
// invitation nobody revisits. Unset or empty allows no origin, which is exactly
// today's behaviour and leaves a native-only client unaffected.
export const ALLOWED_ORIGINS_VARIABLE = "SEVA_ALLOWED_ORIGINS";

// §7.1's headers: `apikey` on every request, `Authorization` on a signed-in one,
// `x-region` on a function call, and `Idempotency-Key` on every create. `content-type`
// because a JSON body is not a simple one.
export const ALLOWED_HEADERS = [
  "apikey",
  "authorization",
  "content-type",
  "x-region",
  "idempotency-key",
] as const;

// The union across §7.3 rather than a list per route group. A preflight only asks
// whether the method it names is allowed; naming one a given route does not serve
// costs nothing, because that route answers 404 on the real request anyway — and a
// per-group option would be a knob where a constant does.
export const ALLOWED_METHODS = ["GET", "POST", "PATCH", "OPTIONS"] as const;

// Long enough that a browsing session preflights each route once, short enough that an
// origin removed from the list stops working the same day.
export const PREFLIGHT_MAX_AGE_SECONDS = 3600;
