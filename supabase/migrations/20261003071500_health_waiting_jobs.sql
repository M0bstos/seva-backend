-- §12.5 has `/discover/health` report `degraded` on "any of the §10.4 alarm conditions
-- or an archived job", and the archived-job arm turned out to see less than it looks.
--
-- **Measured:** pgmq archives on *read count*, so a queue with no consumer never
-- increments one, never archives, and shows nothing. The moderation queue is drained
-- by §8's worker, so its backlog surfaces through the pending-15-minutes arm. `ops`
-- and `email` have no consumer until weeks 4–5, and neither has a symptom of its own:
-- an orphaned file (§5.4) or an unsent cancellation email (§2.1) is invisible from
-- every other arm. A previous version of `queue_media_deletion`'s comment claimed the
-- archived-job arm covered that backlog. It did not, which is why this exists.
--
-- A **waiting** job rather than a deep queue: `enqueued_at` older than fifteen minutes
-- with `vt` in the past is a job nobody has taken, which is the same fifteen minutes
-- §10.4 gives stuck screening and the same meaning — work that should have moved and
-- has not. A job mid-retry is hidden for 60 seconds at a time and §8.4 archives it
-- after five, so five minutes of retries cannot reach this threshold.
--
-- Rolled forward as a replacement (§13.3); the eight arms before it are unchanged.
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
    -- §10.4, stuck screening: "any item pending 15 minutes".
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
    select 1 from public.acts
    where status = 'held' and status_changed_at < now() - interval '20 hours'
    union all
    select 1 from public.activities
    where status = 'held' and status_changed_at < now() - interval '20 hours'
    union all
    select 1 from public.media
    where status = 'held' and status_changed_at < now() - interval '20 hours'
    union all
    -- §10.4, the two-hour deadline: "any such report open 45 minutes".
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
    -- §10.4's two report rows at once: §5.3 cannot tell an unlawful-content grievance
    -- from any other open report, so 18 hours covers both (`O35`).
    select 1 from public.reports
    where status = 'open' and created_at < now() - interval '18 hours'
    union all
    -- §8.4: "after that they are archived and an alarm fires; nothing is silently
    -- dropped." A job that failed five times.
    select 1 from pgmq.a_moderation
    union all
    select 1 from pgmq.a_email
    union all
    select 1 from pgmq.a_ops
    union all
    -- And a job nobody has taken at all, which the archive can never show.
    select 1 from pgmq.q_moderation
    where enqueued_at < now() - interval '15 minutes' and vt <= now()
    union all
    select 1 from pgmq.q_email
    where enqueued_at < now() - interval '15 minutes' and vt <= now()
    union all
    select 1 from pgmq.q_ops
    where enqueued_at < now() - interval '15 minutes' and vt <= now()
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
