-- **A compliance defect found in review, 5 October 2026: one deleted account could pin
-- `/discover/health` at `degraded` for ever.** §5.2.1 points a report's `act_id`,
-- `activity_id` and `reported_user_id` at their tables `on delete set null`, while its own
-- `reports_resolved_at_matches_status` check will not let `status` leave `open` without a
-- `resolved_at` — so §5.4's account deletion, which removes the person's Acts, leaves open
-- rows that name nothing. No moderator can action one, and all three report arms counted
-- them. §12.5 keeps the reason out of the answer deliberately, so that signal would have
-- masked §10.4's 45- and 60-minute legal arms behind something nobody could clear, with
-- §14.3's Route 53 check feeding it to the on-call rota.
--
-- §5.5's deletion function resolves these rows as it goes; this is the arm's own guard, so
-- a future path that nulls a subject cannot break the alarm again.
--
-- Rolled forward as a replacement (§13.3), carrying the whole body with its comments.
-- **Only the three report arms change**, and each is marked.
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
    --
    -- **Changed, here and in the two arms below: a report whose subject is gone is not
    -- counted.** An open row naming nothing is one no moderator can action, so counting it
    -- made the alarm permanent rather than informative.
    select 1 from public.reports
    where status = 'open'
      and reason = 'intimate_imagery'
      and num_nonnulls(act_id, activity_id, reported_user_id) = 1
      and created_at < now() - interval '45 minutes'
    union all
    -- §11.6 gives `impersonation` its own alarm, at 60 minutes rather than §10.4's 45.
    select 1 from public.reports
    where status = 'open'
      and reason = 'impersonation'
      and num_nonnulls(act_id, activity_id, reported_user_id) = 1
      and created_at < now() - interval '60 minutes'
    union all
    -- §10.4's two report rows at once: §5.3 cannot tell an unlawful-content grievance
    -- from any other open report, so 18 hours covers both (`O35`).
    select 1 from public.reports
    where status = 'open'
      and num_nonnulls(act_id, activity_id, reported_user_id) = 1
      and created_at < now() - interval '18 hours'
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
