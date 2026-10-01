-- §8.2: "Triggers on create and edit queue a text job for: ... profile display name
-- and bio." The Act and Activity halves shipped with the routes that write those
-- columns; this is the third, and it is a function of its own rather than a third
-- branch of `queue_text_screening` because it runs in a different security context.
--
-- §7.2 has clients PATCH `profiles` through the Data API, so this trigger fires as
-- `authenticated`, which holds nothing in `pgmq` (§5.1): an invoker function would
-- raise `permission denied for schema pgmq` on every profile edit. So it is
-- `security definer`, like the counter triggers (§17.1). §9.1 asks a definer function
-- to check permissions on its first line; for a trigger that check has already
-- happened — it fires only on a row the caller's column grants and RLS policy let
-- them write. The rest of §9.1's list holds: `search_path` is pinned, every name is
-- schema-qualified, and there is no dynamic SQL.
--
-- §17 `O14`, decided during the build, 30 September 2026: **the moderation worker
-- writes `text_hidden`, through a column grant.** §5.2 already names the worker as a
-- writer of `profiles`; the narrow reading gave it `avatar_path` alone and left the
-- column §8.2 requires with no writer at all. A grant keeps the path one CI can
-- inspect, where a definer function would not be. §9.2's rule is about a *client*
-- write path, and that is unchanged: `authenticated` still holds `display_name` and
-- `bio` and nothing else.
grant update (text_hidden) on table profiles to service_role;

create function queue_profile_text_screening() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pgmq.send('moderation', jsonb_build_object(
    'kind', 'profile_text',
    'id', new.id
  ));
  return null;
end;
$$;

revoke execute on function queue_profile_text_screening()
  from public, anon, authenticated, service_role;

-- `update of` names only the two columns §8.2 screens, so the worker writing
-- `text_hidden` or `avatar_path` back queues nothing and cannot loop.
--
-- The `when` clause is load-bearing, not tidiness. `update of` fires on a column
-- being **named in the SET list**, not on its value changing, and §7.2 puts
-- `profiles` PATCH on the Data API — the one write path §9.1 says cannot carry a
-- rate limit, since §12.2's buckets are written about §7.3's routes. Measured on the
-- local stack: three `set display_name = display_name` no-ops as `authenticated`
-- queued three jobs, each one a Bedrock `ApplyGuardrail` call (§8.4). This is the
-- first screening trigger reachable from an uncapped write path — `acts` and
-- `activities` are only written through routes §7.3 caps — so the value comparison is
-- what keeps a signed-in person from spending the screening bill by holding a key
-- down. It cannot close the path entirely: a caller who really alternates their bio
-- still queues a job per change, which is what §8.2 asks for.
-- Two triggers and not one, because a `when` clause may not reference OLD on an
-- INSERT: Postgres refuses the combined form outright.
create trigger profiles_queue_text_screening_on_insert
  after insert on profiles
  for each row execute function queue_profile_text_screening();

create trigger profiles_queue_text_screening_on_update
  after update of display_name, bio on profiles
  for each row
  when (
    old.display_name is distinct from new.display_name
    or old.bio is distinct from new.bio
  )
  execute function queue_profile_text_screening();
