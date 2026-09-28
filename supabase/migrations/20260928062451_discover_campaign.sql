-- §7.3 GET /discover/campaigns/:id: "One campaign, for shared links", for anyone. One
-- Postgres call per request (§13.4), so the limiter runs here (§17.1).
--
-- §17 O17 names this route: it filters `status = 'active'` itself, because `discover`
-- runs on a secret key and `service_role` bypasses the `campaigns_select` policy. An
-- ended campaign is NOT_FOUND, which §7.4 defines as "Missing, or not visible to you".
--
-- No cache, for the same reason as the other by-id route: §7.3's key is cell, radius,
-- category, date range and page, and a primary-key lookup has none of them.
create function discover_campaign(
  p_user_id uuid,
  p_campaign_id uuid,
  p_bucket text,
  p_per_minute int,
  p_per_hour int,
  p_per_day int
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_limited jsonb;
  v_campaign public.campaigns%rowtype;
begin
  v_limited := private.check_rate_limit(
    p_bucket, p_user_id, p_per_minute, p_per_hour, p_per_day
  );
  if v_limited is not null then
    return v_limited;
  end if;

  select * into v_campaign from public.campaigns
  where id = p_campaign_id and status = 'active';
  if not found then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  -- The progress value is read as the trigger left it (§5.4): counters are never
  -- recomputed on read.
  return jsonb_build_object(
    'campaign', jsonb_build_object(
      'id', v_campaign.id,
      'title', v_campaign.title,
      'description', v_campaign.description,
      'goal_metric', v_campaign.goal_metric,
      'goal_value', v_campaign.goal_value,
      'progress_value', v_campaign.progress_value,
      'starts_on', v_campaign.starts_on,
      'ends_on', v_campaign.ends_on
    )
  );
end;
$$;

revoke execute on function discover_campaign(uuid, uuid, text, int, int, int)
  from public, anon, authenticated, service_role;
grant execute on function discover_campaign(uuid, uuid, text, int, int, int)
  to service_role;
