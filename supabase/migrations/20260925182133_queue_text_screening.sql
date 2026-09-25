-- §8.2: "Triggers on create and edit queue a text job for: Act title and story;
-- Activity title, description, meeting-point label and what to bring."
--
-- This lands with the routes that write those columns rather than with the moderation
-- worker, because without it `PATCH /acts/:id` is a publish path for unscreened text:
-- an author publishes a benign Act, waits for `visible`, then replaces the title and
-- story, and nothing queues a job or reads `text_checked`. On create the same gap is
-- harmless, since §8.2 keeps new content at `pending` and invisible. The worker that
-- drains this queue is §8's own work; until it exists the jobs accumulate, which is
-- the state §8.3 already calls "pending → pending, a screening service is
-- unavailable".
--
-- `security invoker`: the only writers are the route functions, which run as
-- `service_role`, and §5.1's queue grants give that role exactly `pgmq.send`.
create function queue_text_screening() returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform pgmq.send('moderation', jsonb_build_object(
    'kind', case tg_table_name when 'acts' then 'act_text' else 'activity_text' end,
    'id', new.id
  ));
  return null;
end;
$$;

revoke execute on function queue_text_screening()
  from public, anon, authenticated, service_role;

-- `update of` names the screened columns, so an edit that touches nothing screened —
-- the moderation worker setting `text_checked`, or a status change — queues no job and
-- cannot loop.
create trigger acts_queue_text_screening
  after insert or update of title, story on acts
  for each row execute function queue_text_screening();

create trigger activities_queue_text_screening
  after insert or update of title, description, location_label, what_to_bring
  on activities
  for each row execute function queue_text_screening();
