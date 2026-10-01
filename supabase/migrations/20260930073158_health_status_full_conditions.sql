-- §12.5 has `/discover/health` report `degraded` on "any of the §10.4 alarm
-- conditions or an archived job". The first version shipped five arms and recorded
-- three it could not measure as §17's `O35`. This replaces it with all eight, and
-- `O35` closes. Rolled forward as a new migration rather than an edit (§12.6).
--
-- What changed, and why each was open:
--
--   * **The two `status_changed_at` arms.** Both were measured from `created_at`,
--     which is when the row was made. §8.3's visible → pending made that a live false
--     alarm — measured, an author's edit of an Act older than 15 minutes read
--     `degraded` at once — and "held 20 hours" had no column at all. The column
--     landed in the migration before this one.
--   * **Held content, §10.4's 20 hours.** Now measurable, for Acts, Activities and
--     photos alike: §10.3's review queue is all three.
--   * **An archived job.** `O35` said an invoker function could not count `pgmq.a_*`
--     because §5.1 grants `service_role` `execute` on pgmq's functions and not
--     `select` on its tables. That premise was wrong: the queues migration grants
--     `select, insert` on all three archives, precisely so §8.4's alarm has something
--     to read. §8.4 archives a job after five failures and says "nothing is silently
--     dropped" — this is what stops it being dropped silently.
--   * **The unlawful-content grievance, §10.4's 18 hours.** §5.3's `report_reason`
--     still has no value for it, so such a report cannot be told from any other open
--     one. `O35` gave two ways out and this takes the second: **every** open report
--     alarms at 18 hours rather than 20. It costs two hours of earlier `degraded`
--     across the board and needs no legal reading of which reasons are unlawful
--     content — a reading that belongs to the program, not to this function. It is
--     strictly tighter than §10.4's internal 24-hour target, so the row it replaces
--     is still met.
--
-- Everything else is unchanged: `security invoker` on the discover function's secret
-- key, the answer cached 30 seconds in `private.discover_cache`, and the word alone —
-- never a detail about which arm fired (§12.5).
create or replace function health_status() returns text
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
    -- §10.4, stuck screening: "any item pending 15 minutes". §8.3 calls this the
    -- pending → pending state, which is what a screening service being down looks
    -- like from here.
    select 1 from public.acts
    where status = 'pending' and status_changed_at < now() - interval '15 minutes'
    union all
    select 1 from public.activities
    where status = 'pending' and status_changed_at < now() - interval '15 minutes'
    union all
    select 1 from public.media
    where status = 'processing' and status_changed_at < now() - interval '15 minutes'
    union all
    -- §10.4, held content: "reviewed within 24 hours, any item held 20 hours".
    -- §10.3's queue is Acts, Activities and photos, so all three are counted.
    select 1 from public.acts
    where status = 'held' and status_changed_at < now() - interval '20 hours'
    union all
    select 1 from public.activities
    where status = 'held' and status_changed_at < now() - interval '20 hours'
    union all
    select 1 from public.media
    where status = 'held' and status_changed_at < now() - interval '20 hours'
    union all
    -- §10.4, the two-hour deadline: "any such report open 45 minutes". §8.5 holds the
    -- content on the first such report, so what is left is a person having to look.
    select 1 from public.reports
    where status = 'open'
      and reason = 'intimate_imagery'
      and created_at < now() - interval '45 minutes'
    union all
    -- §11.6 gives `impersonation` its own alarm, at 60 minutes rather than §10.4's 45.
    select 1 from public.reports
    where status = 'open'
      and reason = 'impersonation'
      and created_at < now() - interval '60 minutes'
    union all
    -- §10.4 has two rows here — "unlawful-content grievance, alarm at 18 hours" and
    -- "any report open 20 hours" — and §5.3 gives no way to tell the first from the
    -- second. 18 covers both.
    select 1 from public.reports
    where status = 'open' and created_at < now() - interval '18 hours'
    union all
    -- §8.4: "after that they are archived and an alarm fires; nothing is silently
    -- dropped". One row in any archive is that alarm.
    select 1 from pgmq.a_moderation
    union all
    select 1 from pgmq.a_email
    union all
    select 1 from pgmq.a_ops
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
