-- §10.2: "`admin_set_verified` | Admin | Sets the verified badge and organisation name and
-- type." §2.3's `D7` is why it is a staff function rather than a flow: "Evidence required
-- for metrics; staff set a verified flag on organisations" — "most of the trust value
-- without organisation accounts".
--
-- §9.2 puts verification among the things with "no client write path: no column grant, no
-- policy, no public function", so this is `security definer` and `authenticated` holds
-- nothing on any of the three columns.
create function admin_set_verified(
  p_user_id uuid,
  p_is_verified boolean,
  p_org_name text,
  p_org_type org_type,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff uuid;
  v_profile public.profiles%rowtype;
begin
  -- §10.1 reserves verifying to an admin: "Admin | Everything a moderator can, plus
  -- verify organisations".
  v_staff := private.staff_actor('admin');
  if v_staff is null then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  if char_length(coalesce(p_reason, '')) not between 3 and 500 then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'reason');
  end if;

  if p_is_verified is null then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'is_verified');
  end if;

  -- §5.2.1's own check, named here rather than left to fire: "verified ⇒ org_name and
  -- org_type set". A 23514 reaching Appsmith could only say which row failed.
  if p_is_verified and (p_org_name is null or p_org_type is null) then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'org_name');
  end if;

  select * into v_profile from public.profiles where id = p_user_id for update;
  if not found then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  begin
    update public.profiles
    set is_verified = p_is_verified,
        org_name = p_org_name,
        org_type = p_org_type
    where id = p_user_id;
  exception when check_violation then
    -- §5.2.1 bounds `org_name` at 100. The backstop, so a long name is a named field
    -- rather than a 500 whose DETAIL carries the row into the log (§9.8).
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'org_name');
  end;

  insert into public.admin_audit_log (
    actor, staff_id, action, subject_type, subject_id, reason, before, after
  ) values (
    'staff', v_staff, 'set_verified', 'profile', p_user_id, p_reason,
    jsonb_build_object('is_verified', v_profile.is_verified,
                       'org_name', v_profile.org_name, 'org_type', v_profile.org_type),
    jsonb_build_object('is_verified', p_is_verified,
                       'org_name', p_org_name, 'org_type', p_org_type)
  );

  return jsonb_build_object('is_verified', p_is_verified);
end;
$$;

revoke execute on function admin_set_verified(uuid, boolean, text, org_type, text)
  from public, anon, authenticated, service_role;
grant execute on function admin_set_verified(uuid, boolean, text, org_type, text)
  to authenticated;
