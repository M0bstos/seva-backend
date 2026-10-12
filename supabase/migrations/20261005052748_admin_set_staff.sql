-- §10.2: "`admin_set_staff` | Admin | Grants or removes a staff role (but not their own)."
-- The parenthesis is the whole security property, and it is narrower than it first looks: what
-- it prevents is an admin changing their **own** role, not an admin demoting the others. Review
-- corrected the reasoning written here, which claimed the latter — an admin can still demote
-- every other admin and remain the only one, and §10.1 gives them that by design. What the check
-- stops is the self-edit: granting yourself a role you do not have, or stepping out of the one
-- that makes you accountable for what you just did. §9.7's callout already notes that for an
-- `admin_*` function "the first-line role and MFA check … is the only control".
--
-- The residual, recorded in §17.1 rather than guarded: two admins demoting each other
-- concurrently lock different rows, both commit, and no admin is left — and no function can
-- create the first one. It needs two admins acting deliberately at the same moment, and §10.2
-- asks for no such guard, so it is written down instead of built.
--
-- A null `p_role` removes the staff row, which §5.4 calls a demotion: "Staff are demoted,
-- never deleted." §5.2.1's `restrict` foreign key on `staff.user_id` is what makes that
-- distinction real — a profile cannot be deleted while a staff row points at it.
--
-- `security definer`: §5.2's Access column for `staff` is "—", so no role holds anything on
-- it at all, and §9.7 keeps RLS on with no policy for exactly that reason.
create function admin_set_staff(
  p_user_id uuid,
  p_role staff_role,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff uuid;
  v_before public.staff%rowtype;
begin
  -- §10.1: "Admin | … manage staff (but not their own role)".
  v_staff := private.staff_actor('admin');
  if v_staff is null then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  if char_length(coalesce(p_reason, '')) not between 3 and 500 then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'reason');
  end if;

  -- §10.2's parenthesis. `FORBIDDEN` rather than a validation error, because it is a rule
  -- about who may act rather than about the shape of the request (§7.4).
  if p_user_id = v_staff then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  -- §5.2.1 points `staff.user_id` at `profiles`, so a person has to exist before they can
  -- be staff. Checked here so the foreign key cannot raise 23503 into an opaque 500.
  if not exists (select 1 from public.profiles where id = p_user_id) then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  select * into v_before from public.staff where user_id = p_user_id for update;

  if p_role is null then
    delete from public.staff where user_id = p_user_id;
  else
    insert into public.staff (user_id, role) values (p_user_id, p_role)
    on conflict (user_id) do update set role = excluded.role;
  end if;

  insert into public.admin_audit_log (
    actor, staff_id, action, subject_type, subject_id, reason, before, after
  ) values (
    'staff', v_staff, 'set_staff', 'profile', p_user_id, p_reason,
    jsonb_build_object('role', v_before.role),
    jsonb_build_object('role', p_role)
  );

  return jsonb_build_object('role', p_role);
end;
$$;

revoke execute on function admin_set_staff(uuid, staff_role, text)
  from public, anon, authenticated, service_role;
grant execute on function admin_set_staff(uuid, staff_role, text) to authenticated;
