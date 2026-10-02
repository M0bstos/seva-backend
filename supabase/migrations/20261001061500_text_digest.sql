-- What the screening verdict is *about*, so a verdict cannot land on text nobody
-- screened. §8 is the rule it protects: "An Act or Activity leaves `pending` only when
-- its text and every one of its photos have passed."
--
-- Why it exists, reproduced on the local stack, 2 October 2026. The queue message
-- carries a kind and a content id and nothing about the text, so a verdict was keyed
-- on the id alone:
--
--   1. The create-time job is claimed and the title passes. The verdict is in flight.
--   2. The author calls `PATCH /acts/:id` and replaces the title with abusive text.
--      The row goes `text_checked = false`, stays `pending`, and queues a new job.
--   3. The in-flight **pass** arrives, sets `text_checked = true`, and the Act
--      publishes — abusive title visible, and §6.1's points awarded.
--   4. The real job for the abusive title is screened and **flagged**, but the row is
--      now `visible` rather than `pending`, so the hold was skipped and the flag
--      discarded. Permanently.
--
-- Every edit queues another job, so the window recurred on demand. That is the hole
-- §8.3's `visible → pending` row was added to close, reopened from the other end.
--
-- One function used by both the claim and the completion, so the two cannot drift on
-- what "the same text" means — which is the whole value of it.
--
-- `sha256` and `convert_to` are `pg_catalog`, so nothing here needs `extensions`.
-- Returns null when the content is gone, which the callers read as "nothing to do".
create function private.text_digest(p_kind text, p_id uuid) returns text
language sql
security invoker
stable
set search_path = ''
as $$
  select encode(
    pg_catalog.sha256(
      pg_catalog.convert_to(
        -- The separator matters: without it a title ending in "ab" with a story
        -- starting "c" digests the same as "a" and "bc", and an author could edit
        -- across the boundary without changing the digest.
        pg_catalog.concat_ws(
          e'\037',
          case p_kind
            when 'act_text' then (select a.title from public.acts a where a.id = p_id)
            when 'activity_text' then
              (select c.title from public.activities c where c.id = p_id)
            when 'profile_text' then
              (select p.display_name from public.profiles p where p.id = p_id)
          end,
          case p_kind
            when 'act_text' then (select a.story from public.acts a where a.id = p_id)
            when 'activity_text' then
              (select c.description from public.activities c where c.id = p_id)
            when 'profile_text' then (select p.bio from public.profiles p where p.id = p_id)
          end,
          case p_kind
            when 'activity_text' then
              (select c.location_label from public.activities c where c.id = p_id)
          end,
          case p_kind
            when 'activity_text' then
              (select c.what_to_bring from public.activities c where c.id = p_id)
          end
        ),
        'UTF8'
      )
    ),
    'hex'
  )
  -- A kind with no row, or a content id that no longer exists, digests to nothing
  -- rather than to the digest of an empty string.
  where exists (
    select 1 from public.acts a where p_kind = 'act_text' and a.id = p_id
    union all
    select 1 from public.activities c where p_kind = 'activity_text' and c.id = p_id
    union all
    select 1 from public.profiles p where p_kind = 'profile_text' and p.id = p_id
  );
$$;

revoke execute on function private.text_digest(text, uuid)
  from public, anon, authenticated, service_role;
grant execute on function private.text_digest(text, uuid) to service_role;
