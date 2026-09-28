// §7.3's limit column, per person unless stated. These are the full-strength values:
// private.check_rate_limit halves them for an account under 72 hours old, so nothing
// here encodes that rule.
//
// Three of §7.3's nineteen routes are deliberately absent. POST /account/onboarding is
// "once", which §5.4 enforces by the profile row existing rather than by a counter;
// GET /discover/health is exempt (§12.5); and POST /activities/:id/leave shares the
// join limit, so it names that entry rather than one of its own.
//
// Each discover route carries its own 60/min, because §7.3 gives each of them its own
// row. §7.3 says "shares join limit" where it means one budget, and does not say it
// here — so spending on shared links must not exhaust the nearby-activities browse.
export type Window = { perMinute?: number; perHour?: number; perDay?: number };

export const LIMITS = {
  "acts.create": { perHour: 10, perDay: 30 },
  "acts.update": { perHour: 30 },
  "activities.create": { perDay: 5 },
  "activities.join": { perHour: 30 },
  "activities.cancel": { perDay: 5 },
  "uploads.create": { perHour: 30, perDay: 100 },
  "uploads.complete": { perHour: 60 },
  "reports.create": { perDay: 20 },
  "account.delete": { perDay: 3 },
  "account.export": { perDay: 2 },
  "account.export.read": { perHour: 30 },
  "discover": { perMinute: 60 },
  "discover.activity": { perMinute: 60 },
  "discover.campaigns": { perMinute: 60 },
  "discover.campaign": { perMinute: 60 },
  "feed": { perMinute: 60 },
} satisfies Record<string, Window>;

// §7.3 limits four of the five public routes "per person or IP" — `/discover/health`
// is the exempt one (§12.5). The address comes from the
// header the platform's own proxy appends, because the peer address is that proxy:
// measured against supabase-edge-runtime 1.74.3, `Deno.serve`'s conn info gives
// `remoteAddr.hostname = "0.0.0.0"` for every caller, while this header carries the
// real one. A caller may send the header themselves, so only the **last** entry is
// read — a proxy appends, so anything the caller wrote sits to the left of it.
export const FORWARDED_FOR_HEADER = "x-forwarded-for";

// When the header is absent there is no caller to tell apart, and every such request
// shares one bucket. Be clear about what that is: past §7.3's 60/min the shared
// bucket refuses everyone, so it is an outage of the four public routes much like
// refusing outright would be, and the first 60 requests a minute still serve.
//
// It is not self-diagnosing either. This name is hashed like any address (`O26`), so
// the counter row reads `discover:<hmac>` and an operator cannot find it by eye; the
// salt rotates every 90 days (§9.5), after which older rows cannot be attributed to
// it at all. §12.6's "Request flood" step is where that digest has to be recomputed
// to tell this state from an ordinary flood.
export const UNKNOWN_ADDRESS = "unknown";
