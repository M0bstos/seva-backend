-- §10.4 alarms on "any item held 20 hours" and "any item pending 15 minutes", and
-- §12.5 has `/discover/health` report `degraded` on either. Neither was measurable:
-- §5.2.1 gives `acts`, `activities` and `media` a `status` with no timestamp beside
-- it, so `health_status` measured both from `created_at`, which is when the row was
-- made and not when it entered the status.
--
-- That is a live defect, not only a gap. **Measured against the local stack,
-- 30 September 2026:** an Act created 20 minutes ago and published reads `ok`; the
-- same Act after its author edits it through `PATCH /acts/:id` — §8.3's visible →
-- pending — reads `degraded` immediately, because the row's `created_at` is already
-- older than the 15-minute threshold. §12.5 points an `HTTPS_STR_MATCH` Route 53
-- check at that word and pages the on-call rota after three failed checks, so every
-- ordinary Act edit in production would have paged someone at 90 seconds.
--
-- This is the column §17's `O35` names as one of the two ways to measure a hold. No
-- grant accompanies it and none is needed: a `before update` trigger assigning to NEW
-- runs after the statement's column privileges are checked.
--
-- The trigger fires on **every** update rather than only on one naming `status`, and
-- restores the old value when the status has not moved. Without that, the column is
-- writable after all by the one role no grant can stop — the table's owner, which
-- §9.1 also requires every `security definer` function to be owned by. Measured:
-- `update acts set status_changed_at = <future>` as the owner leaves the row `held`,
-- moves its clock forward, and §10.4's 20-hour held arm then never fires. Antedating
-- would only make an alarm noisy; forward-dating makes it silent, which is the
-- evasion this column exists to prevent, and week 4–5's staff hold functions are
-- exactly the `postgres`-owned definer bodies that could do it by accident.
alter table acts add column status_changed_at timestamptz not null default now();
alter table activities add column status_changed_at timestamptz not null default now();
alter table media add column status_changed_at timestamptz not null default now();

create function stamp_status_changed_at() returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.status is distinct from old.status then
    new.status_changed_at := now();
  else
    new.status_changed_at := old.status_changed_at;
  end if;
  return new;
end;
$$;

revoke execute on function stamp_status_changed_at()
  from public, anon, authenticated, service_role;

create trigger acts_stamp_status_changed_at
  before update on acts
  for each row execute function stamp_status_changed_at();

create trigger activities_stamp_status_changed_at
  before update on activities
  for each row execute function stamp_status_changed_at();

create trigger media_stamp_status_changed_at
  before update on media
  for each row execute function stamp_status_changed_at();

-- One index per table serves both §10.4 arms, and any status a later one asks about.
create index acts_status_changed_at on acts (status, status_changed_at);
create index activities_status_changed_at on activities (status, status_changed_at);
create index media_status_changed_at on media (status, status_changed_at);

-- §5.5's two partial indexes were added for the stuck-screening arm alone and are
-- superseded by the pair above, which answer it from the right column.
drop index acts_pending_created_at;
drop index activities_pending_created_at;
