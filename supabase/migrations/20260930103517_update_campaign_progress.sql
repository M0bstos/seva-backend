-- §6.1's second ledger trigger, and the third of §5.4's three counters: "Triggers on
-- the ledger update `impact_totals` and the campaign's `progress_value` in the same
-- transaction."
--
-- §6.1 fixes both sources: "`acts` counts `act_published` rows carrying a
-- `campaign_id`, and each metric value sums `metric` rows for that metric." Nothing
-- else counts — §2.1 and §6.1 both record that a participant-count goal was
-- considered and dropped, "since joining writes no ledger row, so its progress could
-- never advance, and a second non-ledger source would break the rebuild property in
-- §6.4". This function is what makes that rebuild property true: every campaign's
-- progress is a sum over rows that are still there.
--
-- `security definer` (§17.1), like the other two counters: §9.2 gives campaign
-- progress no client write path, and `campaigns` grants `service_role` `select` alone.
--
-- Insert and delete only, for the reason §5.4 gives — the ledger "is never updated".
-- An account deletion nulls `user_id` and `act_id` but leaves `campaign_id`, so a
-- campaign keeps the progress a since-deleted person contributed, which §5.4 asks for
-- in as many words: "campaign totals stay correct with no extra code".
create function update_campaign_progress() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.impact_entries%rowtype;
  v_sign int;
begin
  if tg_op = 'INSERT' then
    v_row := new;
    v_sign := 1;
  else
    v_row := old;
    v_sign := -1;
  end if;

  if v_row.campaign_id is null then
    return null;
  end if;

  update public.campaigns c
  set progress_value = c.progress_value + v_sign * case
        -- The `activity_documented` bonus row carries the same campaign and counts
        -- towards neither: it is a point, not an act and not a claimed metric.
        when c.goal_metric = 'acts' and v_row.kind = 'act_published' then 1
        when c.goal_metric::text = v_row.metric::text and v_row.kind = 'metric'
          then v_row.value
        else 0
      end
  where c.id = v_row.campaign_id;

  return null;
end;
$$;

revoke execute on function update_campaign_progress()
  from public, anon, authenticated, service_role;

create trigger impact_entries_update_campaign_progress
  after insert or delete on impact_entries
  for each row execute function update_campaign_progress();
