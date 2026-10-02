-- §8.3's first row, and the only path out of `pending` that is not a person's
-- decision: "pending → visible | Text passes and every photo is `ready`. Points are
-- awarded (§6.1)". §8 states it twice over — "An Act or Activity leaves `pending`
-- only when its text and every one of its photos have passed."
--
-- Both completion functions call it, because either half can be the last to arrive:
-- the text may pass after the photos or before them. Written once so the two cannot
-- drift on the rule that decides what becomes public and what earns points.
--
-- It does not award anything itself. §6.1's trigger fires on the status change, so
-- the award and the publication cannot come apart.
--
-- Two nullable arguments rather than a kind and an id, mirroring the shape §5.1 gives
-- `media` for the same reason: each statement is then a real match on a real key.
--
-- `security invoker`: the callers run as `service_role`, which holds `update (status,
-- text_checked, published_at)` on `acts` and `update (status, text_checked,
-- cancelled_at)` on `activities` (§5.2).
create function private.publish_if_screened(p_act_id uuid, p_activity_id uuid)
returns void
language sql
security invoker
set search_path = ''
as $$
  -- `published_at` is coalesced because §5.2.1 records first publication: §8.3 sends
  -- an edited Act back through `pending`, and the second visit is not a first.
  update public.acts
  set status = 'visible', published_at = coalesce(published_at, now())
  where id = p_act_id
    and status = 'pending'
    and text_checked
    and not exists (
      select 1 from public.media m where m.act_id = p_act_id and m.status <> 'ready'
    );

  update public.activities
  set status = 'visible'
  where id = p_activity_id
    and status = 'pending'
    and text_checked
    and not exists (
      select 1 from public.media m
      where m.activity_id = p_activity_id and m.status <> 'ready'
    );
$$;

revoke execute on function private.publish_if_screened(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function private.publish_if_screened(uuid, uuid) to service_role;
