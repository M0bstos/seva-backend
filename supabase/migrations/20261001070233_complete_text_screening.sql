-- §8.2's worker side: the text has been through `ApplyGuardrail` and this is what the
-- answer does. §8.3 supplies the two transitions — "pending → visible | Text passes
-- and every photo is `ready`" and "pending → held | Any check flags" — and §8.2
-- supplies the third, for profiles: "Profiles are visible straight away. If flagged,
-- the display name shows as 'SEVA member' and the bio is hidden until staff review it."
--
-- The worker passes the message id, the verdict, and the digest the claim handed it.
--
-- **The kind and the content id are read back out of the queue row**, so there is no
-- content-id argument to confuse and an Act's verdict cannot land on a profile — the
-- same reason §9.2 takes a user id from a verified token rather than from a request
-- body. That alone was not enough: `msg_id` was the only handle, and nothing bound a
-- verdict to the *text* it was about. The digest is what does, and
-- `private.text_digest` carries the reproduction. A stale verdict is dropped rather
-- than applied, because the edit that made it stale queued a job of its own.
--
-- The message must also still be **invisible**, which is what proves the completion
-- is inside the 60 seconds §8.4 hid it for. Past that another worker may have taken
-- it, and a result produced against a lapsed claim is one to discard and let the
-- retry redo.
--
-- `security invoker`: the worker calls it on its own secret key, and `service_role`
-- holds `update (status, text_checked, published_at)` on `acts`, `update (status,
-- text_checked, cancelled_at)` on `activities` and `update (avatar_path, text_hidden)`
-- on `profiles` (§5.2, `O14`).
create function complete_text_screening(
  p_msg_id bigint,
  p_flagged boolean,
  p_digest text
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_message jsonb;
  v_kind text;
  v_id uuid;
begin
  select q.message into v_message
  from pgmq.q_moderation q
  where q.msg_id = p_msg_id and q.vt > now();

  -- Either the job is gone — another worker finished it — or this claim has lapsed.
  -- Both are work to leave alone rather than errors worth retrying.
  if not found then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  v_kind := v_message ->> 'kind';
  v_id := (v_message ->> 'id')::uuid;

  -- A photo job sent to the text completion, before anything else looks at it. The
  -- worker's bug rather than the queue's, so the job is left for §8.4's retry — which
  -- is the reason this comes first: `private.text_digest` has no answer for a photo,
  -- so the check below would read the mismatch as stale text and *delete* the job.
  if v_kind not in ('act_text', 'activity_text', 'profile_text') then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'msg_id');
  end if;

  -- The text has changed since the claim, so this verdict is about text nobody can
  -- see any more. §8.2's trigger queued a job for the new text when it changed, so
  -- dropping this one loses no screening.
  if private.text_digest(v_kind, v_id) is distinct from p_digest then
    perform pgmq.delete('moderation', p_msg_id);
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  if v_kind = 'act_text' then
    -- `text_checked` records that screening happened, whatever it found: a held Act
    -- has been screened, and §8.3 leaves its release to a moderator.
    --
    -- The hold is taken from `pending` **or `visible`**, which §8.3's table did not
    -- list and now does. The digest above means a flag reaching this line is about
    -- the text that is live, and §8 is unconditional that screened-and-flagged text is
    -- not public. `held` and `removed` are left alone: those are a person's to change.
    update public.acts
    set text_checked = true,
        status = case
                   when p_flagged and status in ('pending', 'visible') then 'held'
                   else status
                 end
    where id = v_id;
    if not p_flagged then
      perform private.publish_if_screened(v_id, null);
    end if;
  elsif v_kind = 'activity_text' then
    update public.activities
    set text_checked = true,
        status = case
                   when p_flagged and status in ('pending', 'visible') then 'held'
                   else status
                 end
    where id = v_id;
    if not p_flagged then
      perform private.publish_if_screened(null, v_id);
    end if;
  else
    -- The profile branch; the kind check above has already excluded everything else.
    -- Set and never cleared (`O14`). §8.2's "until staff review it" is what stops an
    -- author lifting an automatic hide by editing until something benign passes, and
    -- what stops this undoing `admin_hide_profile_text`; one boolean cannot tell the
    -- two holds apart.
    if p_flagged then
      update public.profiles set text_hidden = true where id = v_id;
    end if;
  end if;

  perform pgmq.delete('moderation', p_msg_id);
  return jsonb_build_object('kind', v_kind);
end;
$$;

revoke execute on function complete_text_screening(bigint, boolean, text)
  from public, anon, authenticated, service_role;
grant execute on function complete_text_screening(bigint, boolean, text)
  to service_role;
