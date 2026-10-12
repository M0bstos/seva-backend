-- §10.2: "`admin_hide_profile_text` | Moderator | Replaces a display name and hides a bio
-- pending review." §8.2 fixes the mechanism — "If flagged, the moderation worker sets
-- `profiles.text_hidden`, the display name shows as 'SEVA member' and the bio is hidden
-- until staff review it" — so the substitution is the client's, driven by the flag, and
-- what a staff function owns is the flag itself.
--
-- **This function clears it as well as sets it, which closes `O14`'s open half.** §8.2
-- leaves that path unbuilt in as many words: "The worker sets the flag and never clears
-- it … One boolean cannot tell the two holds apart, so clearing it belongs to a staff
-- function — and §10.2 lists none that does, which lands with the staff functions in week
-- 4–5." **Decided during the build, 5 October 2026:** the clear belongs inside this
-- function rather than in a tenth §10.2 does not list. One name, one audited call, and the
-- audit row's `before`/`after` say which direction it went — where a separate
-- `admin_show_profile_text` would be surface §10.2 never asked for.
--
-- Why the worker still must not clear it, unchanged by this: an author could otherwise
-- lift a staff hide by editing their bio until something benign passed.
--
-- `security definer`: §5.2 gives `authenticated` `update (display_name, bio)` on `profiles`
-- and nothing else, and `text_hidden` is `service_role`'s through `O14`'s column grant —
-- neither reaches a staff caller, who arrives as `authenticated` (§10.3).
create function admin_hide_profile_text(
  p_user_id uuid,
  p_hidden boolean,
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
  -- §10.1: "Moderator | … hide profile text".
  v_staff := private.staff_actor('moderator');
  if v_staff is null then
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  if char_length(coalesce(p_reason, '')) not between 3 and 500 then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'reason');
  end if;

  if p_hidden is null then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'hidden');
  end if;

  -- Locked before the flag is read, so two moderators cannot each record a change from a
  -- value the other has already moved.
  select text_hidden into v_before from public.profiles
  where id = p_user_id for update;
  if not found then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  update public.profiles set text_hidden = p_hidden where id = p_user_id;

  -- §9.8 twice over on this one: the row records the flag either side and never the name
  -- or the bio, which are the text being hidden, and §10.3 renders this log on screen.
  insert into public.admin_audit_log (
    actor, staff_id, action, subject_type, subject_id, reason, before, after
  ) values (
    'staff', v_staff, 'hide_profile_text', 'profile', p_user_id, p_reason,
    jsonb_build_object('text_hidden', v_before),
    jsonb_build_object('text_hidden', p_hidden)
  );

  return jsonb_build_object('text_hidden', p_hidden);
end;
$$;

revoke execute on function admin_hide_profile_text(uuid, boolean, text)
  from public, anon, authenticated, service_role;
grant execute on function admin_hide_profile_text(uuid, boolean, text)
  to authenticated;
