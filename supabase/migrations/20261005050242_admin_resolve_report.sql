-- §10.2: "`admin_resolve_report` | Moderator | Closes a report as actioned or dismissed,
-- with a note." This is what stops §10.4's clocks — the 24-hour internal target, and the
-- 18-hour arm `/discover/health` applies to every open report (`O35`).
--
-- **One text argument, written to both columns.** §10.2 asks for "a note" and §10 for a
-- reason; on this one function they are the same sentence, and v1 has no reader for
-- `reports.resolution_note` at all (§7.2 gives clients no read on `reports`), so there is
-- no second audience a separate internal reason would serve. Making staff type the same
-- thing twice is the kind of surface CLAUDE.md rules out. The audit bound is the tighter
-- of the two — §5.2.1 gives the note no floor and the audit reason a floor of 3 — so that
-- is the one checked.
--
-- `security definer`, because §5.2 grants `service_role` only `select` and the nine-column
-- `insert` on `reports` and nothing at all on `admin_audit_log`; `authenticated` holds
-- neither. Granted to `authenticated` as §9.1 allows for `admin_*` alone.
create function admin_resolve_report(
  p_report_id uuid,
  p_status report_status,
  p_note text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff uuid;
  v_report public.reports%rowtype;
begin
  -- §10.1: "Moderator | Review held content and reports".
  v_staff := private.staff_actor('moderator');
  if v_staff is null then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  if char_length(coalesce(p_note, '')) not between 3 and 500 then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'note');
  end if;

  -- §10.2 gives two outcomes. `open` is the third value of §5.3's enum and is where a
  -- report starts, not somewhere a moderator may put one back: §5.2.1's own check pairs
  -- `resolved_at` with a status other than `open`.
  if p_status not in ('actioned', 'dismissed') then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'status');
  end if;

  -- Locked before its status is read, so two moderators clearing the same queue cannot
  -- both pass the check below on their own snapshots.
  select * into v_report from public.reports where id = p_report_id for update;
  if not found then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  -- Only an open report can be closed. §10.3's queue shows the open ones, so a second
  -- call means two moderators acted on one report — and overwriting the first one's
  -- decision, name and time silently is worse than refusing the second. §5.2.1 makes
  -- `resolved_by` and `resolved_at` single-valued, so there is nowhere to record both.
  if v_report.status <> 'open' then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'status');
  end if;

  update public.reports
  set status = p_status,
      resolved_by = v_staff,
      resolved_at = now(),
      resolution_note = p_note
  where id = p_report_id;

  insert into public.admin_audit_log (
    actor, staff_id, action, subject_type, subject_id, reason, before, after
  ) values (
    'staff', v_staff, 'resolve_report', 'report', p_report_id, p_note,
    jsonb_build_object('status', v_report.status),
    jsonb_build_object('status', p_status)
  );

  return jsonb_build_object('status', p_status, 'resolved_at', now());
end;
$$;

revoke execute on function admin_resolve_report(uuid, report_status, text)
  from public, anon, authenticated, service_role;
grant execute on function admin_resolve_report(uuid, report_status, text)
  to authenticated;
