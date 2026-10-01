import { assertEquals, assertRejects } from "jsr:@std/assert@1.0.19";
import { addressSubject, clientAddress, limitArgs } from "./limits.ts";
import { LIMITS, type Window } from "./limits.constants.ts";

const USER = "11111111-1111-1111-1111-111111111111";

// §7.3's route table, all nineteen rows, transcribed from the spec rather than from
// LIMITS — so a route left out, invented or renumbered fails here. `limit: null` is a
// route §7.3 does not rate limit; two routes may name one entry only where §7.3 says
// they share a budget.
const SPEC: Array<{ route: string; limit: string | null; window: Window }> = [
  { route: "POST /acts", limit: "acts.create", window: { perHour: 10, perDay: 30 } },
  { route: "PATCH /acts/:id", limit: "acts.update", window: { perHour: 30 } },
  { route: "POST /activities", limit: "activities.create", window: { perDay: 5 } },
  { route: "POST /activities/:id/join", limit: "activities.join", window: { perHour: 30 } },
  // "shares join limit"
  { route: "POST /activities/:id/leave", limit: "activities.join", window: { perHour: 30 } },
  { route: "POST /activities/:id/cancel", limit: "activities.cancel", window: { perDay: 5 } },
  { route: "POST /uploads", limit: "uploads.create", window: { perHour: 30, perDay: 100 } },
  { route: "POST /uploads/:id/complete", limit: "uploads.complete", window: { perHour: 60 } },
  { route: "POST /reports", limit: "reports.create", window: { perDay: 20 } },
  // "once" — §5.4 makes the profile row the gate, not a counter
  { route: "POST /account/onboarding", limit: null, window: {} },
  { route: "POST /account/delete", limit: "account.delete", window: { perDay: 3 } },
  { route: "POST /account/export", limit: "account.export", window: { perDay: 2 } },
  { route: "GET /account/export/:id", limit: "account.export.read", window: { perHour: 30 } },
  { route: "GET /discover", limit: "discover", window: { perMinute: 60 } },
  { route: "GET /discover/activities/:id", limit: "discover.activity", window: { perMinute: 60 } },
  { route: "GET /discover/campaigns", limit: "discover.campaigns", window: { perMinute: 60 } },
  { route: "GET /discover/campaigns/:id", limit: "discover.campaign", window: { perMinute: 60 } },
  // exempt (§12.5)
  { route: "GET /discover/health", limit: null, window: {} },
  { route: "GET /feed", limit: "feed", window: { perMinute: 60 } },
  // Not a §7.3 route. §9.3 gives the Send SMS hook a cap of its own, and §12.2 makes
  // this file the only place a limit is named, so it is listed and pinned here like
  // any other. §9.3: "start it at 15,000/day".
  { route: "Auth Send SMS hook", limit: "sms.send", window: { perDay: 15000 } },
];

Deno.test("every rate-limited route in §7.3 is here, with the numbers the spec gives", () => {
  for (const { route, limit, window } of SPEC) {
    if (limit === null) continue;
    const got = limitArgs(limit as keyof typeof LIMITS, USER, USER);
    assertEquals({
      perMinute: got.p_per_minute,
      perHour: got.p_per_hour,
      perDay: got.p_per_day,
    }, {
      perMinute: window.perMinute ?? null,
      perHour: window.perHour ?? null,
      perDay: window.perDay ?? null,
    }, route);
  }
});

Deno.test("and nothing is here that no section of the spec limits", () => {
  const named = new Set(SPEC.map((row) => row.limit).filter((name) => name !== null));
  assertEquals(Object.keys(LIMITS).sort(), [...named].sort());
});

// §7.3 gives each discover route its own row reading 60/min. One shared counter would
// refuse a caller who spent 40 on browsing and 25 on a shared link, though neither
// route reached the limit the spec states for it.
Deno.test("the four discover routes count separately, as §7.3 lists them", () => {
  const buckets = SPEC
    .filter((row) => row.route.startsWith("GET /discover") && row.limit !== null)
    .map((row) => limitArgs(row.limit as keyof typeof LIMITS, USER, null).p_bucket);
  assertEquals(buckets.length, 4);
  assertEquals(new Set(buckets).size, 4, "each discover route needs its own counter");
});

// §7.3: "POST /activities/:id/leave | Frees the place | Participant | shares join
// limit". The type is what enforces it — LimitName is keyof typeof LIMITS, so a leave
// handler cannot name anything else without failing deno check.
Deno.test("leaving an activity spends the join budget, having none of its own", () => {
  const join = SPEC.find((row) => row.route.endsWith("/join"));
  const leave = SPEC.find((row) => row.route.endsWith("/leave"));
  assertEquals(leave?.limit, join?.limit);
  assertEquals(Object.keys(LIMITS).includes("activities.leave"), false);
  assertEquals(
    limitArgs("activities.join", USER, USER).p_bucket,
    `activities.join:${USER}`,
  );
});

Deno.test("each route counts in its own bucket, and each person in their own", () => {
  const other = "22222222-2222-2222-2222-222222222222";
  assertEquals(limitArgs("acts.create", USER, USER).p_bucket, `acts.create:${USER}`);
  assertEquals(limitArgs("acts.update", USER, USER).p_bucket, `acts.update:${USER}`);
  assertEquals(limitArgs("acts.create", other, other).p_bucket, `acts.create:${other}`);
});

// §7.3 limits discover "per person or IP", and serves logged-out callers, where there
// is no account for the 72-hour halving to read (§17.1).
Deno.test("an anonymous caller is counted by subject and is never treated as young", () => {
  const args = limitArgs("discover", "opaque-subject", null);
  assertEquals(args.p_bucket, "discover:opaque-subject");
  assertEquals(args.p_user_id, null);
  assertEquals(args.p_per_minute, 60);
});

// §17 O26: the address itself never reaches the database.
Deno.test("an address is keyed by HMAC, never written through", async () => {
  Deno.env.set("SEVA_RATE_LIMIT_SALT", "a-test-salt");
  const subject = await addressSubject("203.0.113.7");
  assertEquals(subject.length, 64);
  assertEquals(/^[0-9a-f]+$/.test(subject), true);
  assertEquals(subject.includes("203.0.113.7"), false);
  assertEquals(await addressSubject("203.0.113.7"), subject, "same address, same bucket");
  assertEquals(
    (await addressSubject("203.0.113.8")) === subject,
    false,
    "different addresses are counted apart",
  );

  // A different deployment must not produce the same pseudonym for the same address.
  Deno.env.set("SEVA_RATE_LIMIT_SALT", "another-salt");
  assertEquals((await addressSubject("203.0.113.7")) === subject, false);
});

// One client, one bucket: a /64 is an ordinary residential IPv6 allocation, so
// without normalising, varying the low half buys a fresh budget every request.
Deno.test("one client gets one bucket, whatever they vary below the /64", async () => {
  Deno.env.set("SEVA_RATE_LIMIT_SALT", "a-test-salt");
  const first = await addressSubject("2001:db8:abcd:1234::1");
  for (
    const variant of [
      "2001:db8:abcd:1234::2",
      "2001:db8:abcd:1234:ffff:ffff:ffff:ffff",
      "2001:DB8:ABCD:1234::9",
      "2001:db8:abcd:1234::1%eth0",
    ]
  ) {
    assertEquals(await addressSubject(variant), first, variant);
  }
  // A different /64 is a different client.
  assertEquals((await addressSubject("2001:db8:abcd:9999::1")) === first, false);
});

Deno.test("an address written two ways is one client", async () => {
  Deno.env.set("SEVA_RATE_LIMIT_SALT", "a-test-salt");
  assertEquals(
    await addressSubject("::ffff:203.0.113.7"),
    await addressSubject("203.0.113.7"),
    "an IPv4-mapped address is the IPv4 it wraps",
  );
  assertEquals(
    await addressSubject(" 203.0.113.7 "),
    await addressSubject("203.0.113.7"),
    "and surrounding space is not a second client",
  );
});

// Defaulting the salt would make the hash a lookup table over the IPv4 space.
Deno.test("a missing salt fails loudly rather than hashing with a constant", async () => {
  Deno.env.delete("SEVA_RATE_LIMIT_SALT");
  await assertRejects(() => addressSubject("203.0.113.7"), Error, "SEVA_RATE_LIMIT_SALT");
});

Deno.test("the two routes §7.3 does not rate limit have no entry", () => {
  const unlimited = SPEC.filter((row) => row.limit === null).map((row) => row.route);
  assertEquals(unlimited, ["POST /account/onboarding", "GET /discover/health"]);
  const names = Object.keys(LIMITS);
  assertEquals(names.includes("account.onboarding"), false);
  assertEquals(names.includes("discover.health"), false);
});

// Measured against the hosted platform, 29 September 2026. Every header below is
// overwritten or discarded if a caller sends one, and `x-forwarded-for` arrives as
// `<caller>,<caller>, <hop>` — so what must never be read is its last entry.
Deno.test("the address comes from the platform's own header first (§17 O26)", () => {
  assertEquals(
    clientAddress(
      new Headers({
        "sb-forwarded-for": "171.79.48.145",
        "cf-connecting-ip": "171.79.48.145",
        "x-forwarded-for": "171.79.48.145,171.79.48.145, 99.82.173.173",
      }),
    ),
    "171.79.48.145",
  );
  // Cloudflare's, when Supabase's own is absent.
  assertEquals(
    clientAddress(new Headers({ "cf-connecting-ip": "203.0.113.7" })),
    "203.0.113.7",
  );
});

// The bug this replaced: the last entry is an AWS hop that rotates between requests,
// so every anonymous caller in the world shared a handful of buckets.
Deno.test("the last x-forwarded-for entry is never the caller", () => {
  const bucketed = clientAddress(
    new Headers({ "x-forwarded-for": "171.79.48.145,171.79.48.145, 99.82.173.173" }),
  );
  assertEquals(bucketed, "171.79.48.145");
  assertEquals(bucketed === "99.82.173.173", false, "the rotating hop, not the caller");
});

Deno.test("a local stack sends one entry, and it is the caller", () => {
  assertEquals(clientAddress(new Headers({ "x-forwarded-for": "192.168.65.1" })), "192.168.65.1");
});

Deno.test("an authority is unwrapped to the address inside it", () => {
  assertEquals(
    clientAddress(new Headers({ "sb-forwarded-for": "203.0.113.7:41234" })),
    "203.0.113.7",
  );
  assertEquals(
    clientAddress(new Headers({ "x-forwarded-for": "[2001:db8::1]:443" })),
    "2001:db8::1",
  );
});

Deno.test("no header at all means one shared bucket, not a refusal (§7.3)", () => {
  assertEquals(clientAddress(new Headers()), "unknown");
  assertEquals(clientAddress(new Headers({ "x-forwarded-for": "  " })), "unknown");
});

Deno.test("one /64 is one bucket however its zeros are written (§12.2)", async () => {
  Deno.env.set("SEVA_RATE_LIMIT_SALT", "a-test-salt");
  const padded = await addressSubject("2001:0db8:abcd:1234::1");
  const short = await addressSubject("2001:db8:abcd:1234::1");
  const expanded = await addressSubject("2001:db8:abcd:1234:0:0:0:1");
  assertEquals(padded, short);
  assertEquals(short, expanded);
});
