-- §10.2: "`admin_upsert_campaign` | Admin | Creates or edits a campaign." §2.1 gives them
-- to staff — "Campaigns | Created by staff. Activities attach to them" — and §6.1 ties
-- every `campaign_goal` to a source in the ledger.
--
-- **The `goal_metric` guard §17.1 recorded as latent is here.** That row: "`admin_upsert_campaign`
-- must not change `goal_metric` on a campaign that already has progress. §6.2's reversal
-- subtracts against the campaign's *current* goal, so a changed goal makes the delete
-- subtract a quantity the insert never added, raising 23514 against `progress_value >= 0`
-- and failing the staff removal." §11.6 puts a legal clock on a removal, so "staff cannot
-- remove content" is not a small failure.
--
-- `progress_value` is never an argument. §9.2 gives campaign progress no client write path,
-- and §6.1 maintains it from the ledger through `update_campaign_progress`; a staff
-- function that could set it would make §6.4's rebuild property false.
--
-- `security definer`: §5.2 grants `authenticated` and `service_role` `select` on
-- `campaigns` and nothing else.
create function admin_upsert_campaign(
  p_campaign_id uuid,
  p_title text,
  p_description text,
  p_goal_metric campaign_goal,
  p_goal_value numeric,
  p_starts_on date,
  p_ends_on date,
  p_status campaign_status,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff uuid;
  v_before public.campaigns%rowtype;
  v_id uuid;
begin
  -- §10.1: "Admin | … manage campaigns".
  v_staff := private.staff_actor('admin');
  if v_staff is null then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  if char_length(coalesce(p_reason, '')) not between 3 and 500 then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'reason');
  end if;

  -- §5.2.1's bounds and cross-column checks, named here rather than left to fire as one
  -- `check_violation` the function could only answer with the table's name (§17.1).
  if p_goal_value is null or p_goal_value <= 0 then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'goal_value');
  end if;
  if p_starts_on is null or p_ends_on is null or p_ends_on < p_starts_on then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'ends_on');
  end if;
  if p_goal_metric is null then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'goal_metric');
  end if;
  if p_status is null then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'status');
  end if;

  if p_campaign_id is not null then
    -- Locked before `progress_value` is read, because the guard below turns on it and
    -- §6.1's ledger triggers move it from another transaction.
    select * into v_before from public.campaigns where id = p_campaign_id for update;
    if not found then
      return jsonb_build_object('error', 'NOT_FOUND');
    end if;

    -- The guard. Only when the goal would actually change, and only once progress exists:
    -- a campaign at zero can still be re-aimed, which is what an admin fixing a typo on
    -- the day they created it needs.
    if v_before.goal_metric <> p_goal_metric and v_before.progress_value <> 0 then
      return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'goal_metric');
    end if;
  end if;

  begin
    if p_campaign_id is null then
      insert into public.campaigns (
        title, description, goal_metric, goal_value, starts_on, ends_on, status
      ) values (
        p_title, p_description, p_goal_metric, p_goal_value, p_starts_on, p_ends_on, p_status
      )
      returning id into v_id;
    else
      update public.campaigns
      set title = p_title, description = p_description, goal_metric = p_goal_metric,
          goal_value = p_goal_value, starts_on = p_starts_on, ends_on = p_ends_on,
          status = p_status
      where id = p_campaign_id;
      v_id := p_campaign_id;
    end if;
  exception when check_violation then
    -- §5.2.1 bounds the title 5–100 and the description at 2000.
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'title');
  end;

  insert into public.admin_audit_log (
    actor, staff_id, action, subject_type, subject_id, reason, before, after
  ) values (
    'staff', v_staff, 'upsert_campaign', 'campaign', v_id, p_reason,
    case when v_before.id is null then null else
      jsonb_build_object('title', v_before.title, 'description', v_before.description,
                         'goal_metric', v_before.goal_metric,
                         'goal_value', v_before.goal_value, 'status', v_before.status,
                         'starts_on', v_before.starts_on, 'ends_on', v_before.ends_on) end,
    -- `description` included, which review found missing: it is the one column these nine
    -- functions write without the log being able to show it changed. §10's "writes the audit log
    -- in the same transaction" is about what happened, and a blanked description happened.
    jsonb_build_object('title', p_title, 'description', p_description,
                       'goal_metric', p_goal_metric,
                       'goal_value', p_goal_value, 'status', p_status,
                       'starts_on', p_starts_on, 'ends_on', p_ends_on)
  );

  return jsonb_build_object('campaign_id', v_id, 'status', p_status);
end;
$$;

revoke execute on function admin_upsert_campaign(
  uuid, text, text, campaign_goal, numeric, date, date, campaign_status, text
) from public, anon, authenticated, service_role;
grant execute on function admin_upsert_campaign(
  uuid, text, text, campaign_goal, numeric, date, date, campaign_status, text
) to authenticated;
