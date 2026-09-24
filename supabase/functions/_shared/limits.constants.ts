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
