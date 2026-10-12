# Load tests

§12.1's targets, assuming 30,000 registered people and 3,000 at the launch-day peak, tested at 3x
that peak:

- Discover p95 ≤ 400 ms cached, ≤ 900 ms uncached
- Writes p95 ≤ 800 ms
- Error rate below 0.5%

```bash
k6 run -e BASE=https://<ref>.supabase.co -e KEY=<publishable key> tests/load/discover.js
```

Never the secret key. It bypasses every row-level rule, so a load test holding one measures a
system nobody uses.

## What `discover.js` measures, and what it cannot

Discover is the route that takes the crowd, because it is what an unauthenticated person lands on
and the only one callable with no session. The script sends four requests in five to one hot cell —
the shape of a launch, where everyone looks at the same place at once — and the rest to cold cells,
so the cached and uncached targets are measured separately.

**The error-rate target cannot be measured from one source address.** §12.2 limits Discover to 60 a
minute per person or IP, so a single load generator is throttled almost immediately. Measured on a
laptop: at ~2,700 requests a second, **99.7% were refused with `429` and 0% were server errors**.
k6's own `http_req_failed` counts a 429 as a failure and read 99.3% on the first run, which looks
like a catastrophe and is the limiter doing its job — so this script counts only 5xx as an error and
reports the refused share as its own loud metric.

To measure the real error rate, pick one:

- many source addresses (k6 Cloud, or several hosts);
- a pool of signed-in people, each under their own per-person limit;
- the Discover limit raised for the test window **and put back afterwards**. §12.1 expects the limits
  to be re-tuned after this test anyway, so raising it for the test is in keeping — but it has to be
  deliberate and reverted, not a surprise in the results.

That first measurement is worth keeping for its own sake: it is the first evidence for D5's accepted
trade-off, that "a request flood still reaches Postgres" but "each rejected request costs one cheap
indexed write". On a laptop, 40,600 requests in 15 seconds produced no 5xx at all.

## Why there is no write script yet

§12.1's write target needs a different instrument, not a different script, and the reason is a
design decision rather than an omission. §7.3 limits a person to 10 Acts an hour and 30 a day, and
5 Activities a day. So a write load test at 3x a 3,000-person peak needs **thousands of real
onboarded accounts**, each with a session, each spending its own allowance — you cannot generate
write load from a handful of users, because the limiter is the first thing you would measure.

Two ways to do it properly, both needing a hosted staging project (§12.7):

1. **Seed the accounts.** Create a few thousand through the Auth admin API, onboard each once, keep
   the tokens, and have each virtual user spend its own allowance. The seeding is most of the work
   and belongs in a script of its own, run once.
2. **Raise the write limits for the window.** Faster, and it measures the database rather than the
   limiter — which is what the p95 target is actually about. Revert afterwards.

Either way the run has to be against staging rather than a laptop: §12.1's numbers are for Large
compute with 160 direct connections, and `supabase start` is neither.

## Reading the output

| Metric | Means |
| --- | --- |
| `discover_cached` p95 | §12.1's 400 ms target, over answered requests to the hot cell |
| `discover_uncached` p95 | §12.1's 900 ms target, over answered requests to cold cells |
| `server_errors` | 5xx only. This is §12.1's error rate. |
| `rate_limited` | The 429 share. **A high one invalidates the latency figures above**, because so few requests reached a query. |

A refused request records no latency, deliberately: a 429 is the limiter's cost, not the query's,
and mixing the two flatters the p95.
