-- §10.2's first staff function: "`admin_set_content_status` | Moderator | Approves, holds
-- or removes an Act, Activity or photo. Removal reverses points."
--
-- The reversal, the snapshot, the quarantine jobs and §8.3's transitions are all
-- `set_content_status`'s, which §8.5 requires this function to share with
-- `submit_report`. What this one owns is the three things §10 asks of every staff
-- function — "checks the person's role and MFA, requires a reason, and writes the audit
-- log in the same transaction" — plus refusing an argument that would otherwise raise.
--
-- `security definer` and granted to `authenticated`, which §9.1 allows for `admin_*` and
-- only for `admin_*`: §10.3 has staff "sign in to their own SEVA staff account … inside"
-- Appsmith, and "every call runs as that person, so the audit log records who acted".
-- Nothing but these nine functions is callable by a client (gate 3).
--
-- §9.7's callout is the reason the first line is what it is: gate 3 excludes `admin\_%`
-- by design and gate 4 only checks that `search_path` is pinned, "so for any `admin_*`
-- function … the first-line role and MFA check required by §9.1 and §10 is the only
-- control". `private.staff_actor` is that check, written once for all nine.
create function admin_set_content_status(
  p_act_id uuid,
  p_activity_id uuid,
  p_media_id uuid,
  p_status content_status,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff uuid;
begin
  -- §10.1: "Moderator | Review held content and reports, approve or remove content".
  v_staff := private.staff_actor('moderator');
  if v_staff is null then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  -- §10: "requires a reason". §5.2.1 bounds it 3–500, and checking it here rather than
  -- letting the audit row's own check fire keeps a staff mistake a named field rather
  -- than a 500 in Appsmith.
  if char_length(coalesce(p_reason, '')) not between 3 and 500 then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'reason');
  end if;

  if num_nonnulls(p_act_id, p_activity_id, p_media_id) <> 1 then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'subject');
  end if;

  -- §10.2 gives this function three verbs, and `pending` — the fourth value of §5.3's enum — is
  -- not one of them: §8.3 reaches `pending` by screening and by an author's edit, never by a staff
  -- decision.
  --
  -- **There is no guard here for it**, which is a deletion rather than an omission.
  -- `set_content_status`'s transition rule already refuses `pending` with the identical code and
  -- the identical field, so a guard above it was unreachable in effect: review showed the test
  -- that claimed to cover it passed with the guard deleted, because it could not tell the two
  -- refusals apart. A second check that no test can distinguish from the first is not defence in
  -- depth, it is a line that reads as a control and is not one. The comment here was also wrong
  -- about the mechanism — it said `set_content_status` *raises*, where that function's own comment
  -- says correctly that "`pending` needs no guard of its own: the transition rule refuses it as
  -- `VALIDATION_FAILED`".
  return public.set_content_status(
    'staff', v_staff, p_act_id, p_activity_id, p_media_id, p_status, p_reason
  );
end;
$$;

revoke execute on function admin_set_content_status(uuid, uuid, uuid, content_status, text)
  from public, anon, authenticated, service_role;
grant execute on function admin_set_content_status(uuid, uuid, uuid, content_status, text)
  to authenticated;
