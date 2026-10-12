// §12.1's read targets, against Discover — the one route that takes the launch-day crowd, because
// it is what an unauthenticated person lands on. §12.1: "Discover p95 ≤ 400 ms cached, ≤ 900 ms
// uncached", "error rate below 0.5%", tested at 3x a 3,000-person peak.
//
//   k6 run -e BASE=http://127.0.0.1:54321 -e KEY=<publishable> tests/load/discover.js
//
// **A local run measures a laptop, not the launch.** §12.1's numbers are for Large compute in
// Mumbai with 160 direct connections; this script is the instrument, and the figure that counts is
// the one from a hosted staging project (§12.7).
//
// **§12.1's "error rate below 0.5%" cannot be measured from one source address, and a first run
// will look catastrophic for the wrong reason.** Measured: at ~1,750 requests a second from one
// laptop, k6's own `http_req_failed` read 99.3% — every one of them a `429` from §12.2's limiter,
// which caps Discover at 60 a minute per person or IP and was doing exactly its job. So this script
// counts only 5xx as an error and tracks the refused share separately. To measure the real error
// rate you need one of: many source addresses, a pool of signed-in people each under their own
// per-person limit, or the Discover limit raised for the test window and put back afterwards.
// §12.1 already expects the limits to be re-tuned after this test, so raising them for it is in
// keeping — but it has to be a deliberate, reverted change, not a surprise in the results.
import http from "k6/http";
import { check } from "k6";
import { Rate, Trend } from "k6/metrics";

const cached = new Trend("discover_cached", true);
const uncached = new Trend("discover_uncached", true);
// 5xx only. A 429 is the limiter working and is counted below instead, or the threshold would be
// measuring the rate limit rather than the error rate.
const failed = new Rate("server_errors");
const limited = new Rate("rate_limited");

const BASE = __ENV.BASE || "http://127.0.0.1:54321";
const KEY = __ENV.KEY;
if (!KEY) throw new Error("set -e KEY=<publishable key>; the secret key must never be used here");

// One hot cell every virtual user shares, so the cache is exercised rather than avoided, and a
// spread of cold cells to measure the uncached path. §12.2 keys the cache by cell and radius.
const HOT = { lon: 73.8567, lat: 18.5204 };
const COLD = [
  { lon: 72.8777, lat: 19.076 },
  { lon: 77.5946, lat: 12.9716 },
  { lon: 88.3639, lat: 22.5726 },
  { lon: 80.2707, lat: 13.0827 },
  { lon: 78.4867, lat: 17.385 },
  { lon: 75.7873, lat: 26.9124 },
];

export const options = {
  scenarios: {
    // 3x §12.1's 3,000-person peak, as a rate rather than as virtual users: what the targets are
    // about is requests arriving, not clients existing.
    launch_day: {
      executor: "ramping-arrival-rate",
      startRate: 50,
      timeUnit: "1s",
      preAllocatedVUs: 100,
      maxVUs: 600,
      stages: [
        { target: 150, duration: "30s" },
        { target: 300, duration: "1m" },
        { target: 300, duration: "2m" },
        { target: 0, duration: "30s" },
      ],
    },
  },
  thresholds: {
    // §12.1's three numbers, as pass/fail rather than as something to read off a chart. The
    // latency ones apply to answered requests: a refused one never reached the query.
    discover_cached: ["p(95)<400"],
    discover_uncached: ["p(95)<900"],
    server_errors: ["rate<0.005"],
    // Not a §12.1 number. It is here so the refused share is impossible to miss when reading the
    // output, since a high one invalidates the latency figures above.
    rate_limited: ["rate<1"],
  },
};

export default function () {
  // Four in five hit the hot cell, which is the shape of a launch: everyone looks at the same
  // place at once. The rest go cold, which is what the uncached target is for.
  const hot = Math.random() < 0.8;
  const where = hot ? HOT : COLD[Math.floor(Math.random() * COLD.length)];
  const url = `${BASE}/functions/v1/discover?lon=${where.lon}&lat=${where.lat}&radius_km=10`;

  const response = http.get(url, {
    headers: { apikey: KEY, "x-region": "ap-south-1" },
    tags: { expected: hot ? "cached" : "uncached" },
  });

  failed.add(response.status >= 500);
  limited.add(response.status === 429);
  // Only an answered request carries a latency worth recording; a 429 is the limiter's cost, not
  // the query's, and mixing them would flatter the p95.
  if (response.status === 200) {
    (hot ? cached : uncached).add(response.timings.duration);
  }
  check(response, {
    "answered 200 or 429": (r) => r.status === 200 || r.status === 429,
    "the shape is right": (r) => r.status !== 200 || r.body.includes("activities"),
  });
}
