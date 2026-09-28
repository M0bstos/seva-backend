-- §7.3 GET /discover/health, the check §12.5 points two Route 53 checks at. It
-- answers "ok" or "degraded" and nothing else — never details. This returns the word;
-- the route decides the status code, and a word from here is always a 200, because
-- §12.5 keeps 503 for a database that gave no answer at all.
--
-- §12.5: "reports `degraded` on any of the §10.4 alarm conditions or an archived job".
-- Most of those conditions are measurable against the schema as frozen. Three are
-- not; `O35` records them and nothing here guesses at them:
--
--   * **Held content, reviewed within 24 hours, alarm at 20.** Nothing records *when*
--     content was held. §5.2.1 gives `acts` and `activities` a `status` and no
--     timestamp beside it, and §5.4 freezes the schema. The audit row a staff hold
--     writes (§8.5) carries the time, but its `action` text is the staff functions'
--     to define and they are week 4–5.
--   * **An archived job.** §8.4 archives a job after five failures, and §5.1 grants
--     `service_role` `execute` on pgmq's functions rather than `select` on its
--     tables, so an invoker function cannot count `pgmq.a_*`. Nothing can archive a
--     job until a worker exists to fail one, so the check lands with that worker.
--   * **An unlawful-content grievance at 18 hours.** §5.3's `report_reason` has no
--     value for it, so such a report cannot be told apart from any other open one.
--     What ships is the 20-hour rule that covers every open report, which is two
--     hours later than §10.4 asks for this class.
--
-- §12.5 caches the result for 30 seconds, and the cache lives here rather than in the
-- route: §9.4 exposes only `public` to the Data API, so `private.discover_cache` is
-- unreachable from an Edge Function except through a function like this one. That
-- also keeps §13.4's one round trip per request — §12.5 points two Route 53 checks
-- here, each every 30 seconds from three regions, and an uncached check is six scans:
-- `reports` three times, and `acts`, `activities` and `media` once each.
--
-- `security invoker`: the route calls it on the discover function's secret key, and
-- `service_role` already holds `select` on all four tables and `insert, update` on
-- the cache (§12.2). The route is exempt from the limiter (§12.5), so this takes no
-- bucket.
create function health_status() returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_status text;
begin
  select payload ->> 'status' into v_status
  from private.discover_cache
  where cache_key = 'discover:health' and expires_at > now();
  if found then
    return v_status;
  end if;

  select case when exists (
    -- §10.4, stuck screening: "Any item pending 15 minutes". §8.3 calls this the
    -- pending → pending state, which is what a screening service being down looks
    -- like from here.
    select 1 from public.acts
    where status = 'pending' and created_at < now() - interval '15 minutes'
    union all
    select 1 from public.activities
    where status = 'pending' and created_at < now() - interval '15 minutes'
    union all
    select 1 from public.media
    where status = 'processing' and created_at < now() - interval '15 minutes'
    union all
    -- §10.4, the two-hour deadline: "Any such report open 45 minutes". §8.5 holds the
    -- content on the first such report, so what is left is a person having to look.
    select 1 from public.reports
    where status = 'open'
      and reason = 'intimate_imagery'
      and created_at < now() - interval '45 minutes'
    union all
    -- §11.6 gives `impersonation` its own alarm, at 60 minutes rather than §10.4's 45.
    -- Owner decision, 28 September 2026: each section keeps its own number, because
    -- §10.4's 45 is written about intimate imagery and its two-hour deadline.
    select 1 from public.reports
    where status = 'open'
      and reason = 'impersonation'
      and created_at < now() - interval '60 minutes'
    union all
    -- §10.4, open reports: "Any report open 20 hours".
    select 1 from public.reports
    where status = 'open' and created_at < now() - interval '20 hours'
  ) then 'degraded' else 'ok' end into v_status;

  insert into private.discover_cache (cache_key, payload, expires_at)
  values (
    'discover:health', jsonb_build_object('status', v_status), now() + interval '30 seconds'
  )
  on conflict (cache_key) do update
    set payload = excluded.payload, expires_at = excluded.expires_at;

  return v_status;
end;
$$;

revoke execute on function health_status() from public, anon, authenticated, service_role;
grant execute on function health_status() to service_role;
