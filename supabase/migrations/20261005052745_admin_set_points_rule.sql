-- §10.2: "`admin_set_points_rule` | Admin | Changes one scoring rule; applies to new
-- entries only." §6.3 is the contract: "Per-unit values and per-Act maximums live in
-- `points_rules`, so staff can change them without a code release. Changes apply to new
-- entries only; history keeps the points awarded at the time."
--
-- "Applies to new entries only" needs no code: §6.4 keeps every awarded value on its own
-- ledger row, and the award trigger reads `points_rules` at the moment it writes. Nothing
-- here touches `impact_entries`, which is the whole of that guarantee.
--
-- **The two daily caps are not here, and cannot be.** §6.3: "The two daily caps are
-- constants in the award function, not rows: they are a fraud control rather than a tuning
-- knob, and changing one is a migration."
--
-- `security definer`: §5.2 grants `service_role` and `authenticated` `select` on
-- `points_rules` and no write at all.
create function admin_set_points_rule(
  p_rule text,
  p_points_per_unit numeric,
  p_max_per_act numeric,
  p_active boolean,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff uuid;
  v_before public.points_rules%rowtype;
begin
  -- §10.1: "Admin | … change points rules".
  v_staff := private.staff_actor('admin');
  if v_staff is null then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  if char_length(coalesce(p_reason, '')) not between 3 and 500 then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'reason');
  end if;

  if p_active is null then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'active');
  end if;

  -- §5.2.1: "points_per_unit numeric(8,2) not null (≥0)".
  if p_points_per_unit is null or p_points_per_unit < 0 then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'points_per_unit');
  end if;

  -- §5.2.1 fixes the key space: "rule text pk (act_published, activity_documented, or a
  -- metric name)". An unknown rule would insert a row the award function never reads, so
  -- it would look like a change that did nothing.
  if p_rule is null or not (
    p_rule in ('act_published', 'activity_documented')
    or exists (select 1 from unnest(enum_range(null::public.metric)) m where m::text = p_rule)
  ) then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'rule');
  end if;

  select * into v_before from public.points_rules where rule = p_rule for update;

  begin
    insert into public.points_rules (rule, points_per_unit, max_per_act, active)
    values (p_rule, p_points_per_unit, p_max_per_act, p_active)
    on conflict (rule) do update
    set points_per_unit = excluded.points_per_unit,
        max_per_act = excluded.max_per_act,
        active = excluded.active;
  exception when check_violation then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'max_per_act');
  end;

  insert into public.admin_audit_log (
    actor, staff_id, action, subject_type, subject_id, reason, before, after
  ) values (
    -- §5.2.1 gives the audit log a `subject_id uuid not null`, and this subject's key is
    -- text. The rule name is carried in `before`/`after` and the id is a stable digest of
    -- it, so the row still points at one rule and the column keeps its type. §17.1 records
    -- the choice.
    'staff', v_staff, 'set_points_rule', 'points_rule',
    ('00000000-0000-0000-0000-' || substr(md5(p_rule), 1, 12))::uuid, p_reason,
    case when v_before.rule is null then null else
      jsonb_build_object('rule', v_before.rule,
                         'points_per_unit', v_before.points_per_unit,
                         'max_per_act', v_before.max_per_act,
                         'active', v_before.active) end,
    jsonb_build_object('rule', p_rule, 'points_per_unit', p_points_per_unit,
                       'max_per_act', p_max_per_act, 'active', p_active)
  );

  return jsonb_build_object('rule', p_rule, 'active', p_active);
end;
$$;

revoke execute on function admin_set_points_rule(text, numeric, numeric, boolean, text)
  from public, anon, authenticated, service_role;
grant execute on function admin_set_points_rule(text, numeric, numeric, boolean, text)
  to authenticated;
