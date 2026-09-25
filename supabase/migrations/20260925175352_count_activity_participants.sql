-- §5.4: "Counters (`participant_count`, `impact_totals`, campaign progress) are
-- updated by triggers in the same transaction as the change, never recomputed on
-- read." This is the first of those three.
--
-- `security definer`, per §17.1: §9.2 gives `participant_count` no client write path,
-- so `activities` grants `service_role` only `status`, `text_checked` and
-- `cancelled_at`. An invoker trigger would need a grant on exactly the column §9.2
-- protects, which is the thing the design does not have. Owned by the migration role,
-- pinned `search_path` and schema-qualified, and in `public` so gate 4 sees it (§9.1).
--
-- §9.1 asks a definer body to check permissions on its first line. A trigger function
-- has no caller to check: Postgres refuses a direct call, and `execute` is revoked
-- below, so the control is the grant on `activity_participants` itself — the join and
-- leave functions are the only writers.
create function count_activity_participants() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status = 'joined' then
      update public.activities
      set participant_count = participant_count + 1
      where id = new.activity_id;
    end if;
  elsif tg_op = 'UPDATE' then
    -- Only a crossing of the joined boundary moves the count; left_at changing on its
    -- own does not.
    if old.status is distinct from new.status then
      -- Written against `joined` in both directions rather than as an else: with a
      -- third participant_status one day, a move between two non-joined values would
      -- otherwise decrement.
      update public.activities
      set participant_count = participant_count
        + case
            when new.status = 'joined' then 1
            when old.status = 'joined' then -1
            else 0
          end
      where id = new.activity_id;
    end if;
  elsif tg_op = 'DELETE' then
    -- §5.4 removes participations when an account is deleted, and the row goes by
    -- cascade rather than through the leave function.
    if old.status = 'joined' then
      update public.activities
      set participant_count = participant_count - 1
      where id = old.activity_id;
    end if;
  end if;
  return null;
end;
$$;

revoke execute on function count_activity_participants()
  from public, anon, authenticated, service_role;

create trigger activity_participants_count
  after insert or update or delete on activity_participants
  for each row execute function count_activity_participants();
