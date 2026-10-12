-- §10.2: "`admin_set_flag` | Admin | Turns a kill switch on or off." The six switches are
-- §5.3's `app_flag` values, and §12.6 reaches for four of them by name — `uploads` and
-- `create_acts` when harmful content is spreading, `read_only` during a suspected breach or
-- a flood, `award_points` on a points exploit.
--
-- `security definer`: §5.2 names "Admin function" as the only writer of `app_flags`, and
-- §5.2.1 gives the table `updated_by` and deliberately no `updated_at` — §17.1 records why,
-- "because the audit log carries the when".
create function admin_set_flag(
  p_key app_flag,
  p_engaged boolean,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff uuid;
  v_before boolean;
begin
  -- §10.1: "Admin | … use kill switches".
  v_staff := private.staff_actor('admin');
  if v_staff is null then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  if char_length(coalesce(p_reason, '')) not between 3 and 500 then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'reason');
  end if;

  if p_engaged is null then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'engaged');
  end if;

  -- §5.2.1 seeds all six switches in the table's own migration, so this updates and never
  -- inserts: a key that is not there is one §5.3 does not have.
  select engaged into v_before from public.app_flags where key = p_key for update;
  if not found then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  update public.app_flags
  set engaged = p_engaged, updated_by = v_staff
  where key = p_key;

  insert into public.admin_audit_log (
    actor, staff_id, action, subject_type, subject_id, reason, before, after
  ) values (
    -- §5.2.1 gives the audit log a `subject_id uuid not null` and this subject's key is an
    -- enum. A stable digest of the key keeps the column's type while still pointing at one
    -- switch, and `before`/`after` carry the name (§17.1).
    'staff', v_staff, 'set_flag', 'app_flag',
    ('00000000-0000-0000-0000-' || substr(md5(p_key::text), 1, 12))::uuid, p_reason,
    jsonb_build_object('key', p_key, 'engaged', v_before),
    jsonb_build_object('key', p_key, 'engaged', p_engaged)
  );

  return jsonb_build_object('key', p_key, 'engaged', p_engaged);
end;
$$;

revoke execute on function admin_set_flag(app_flag, boolean, text)
  from public, anon, authenticated, service_role;
grant execute on function admin_set_flag(app_flag, boolean, text) to authenticated;
