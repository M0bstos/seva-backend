-- §17 `O21`, decided during the build, 30 September 2026: Rekognition's output is
-- private, and moves to a table of its own. §5.1 is the reason it is a table and not
-- a narrower grant — "RLS works on rows, not columns, so private fields always live
-- in a separate table" — and a column grant was measured as well: PostgREST answers
-- 403 `42501` to its own default `select=*` when a role lacks one column, which would
-- break §7.2's `media` embed. The argument is recorded in §17 `O21` and §17.1; this
-- file does not repeat it.
create table media_labels (
  media_id uuid primary key references media (id) on delete cascade,
  labels jsonb not null,
  created_at timestamptz not null default now()
);

revoke all on table media_labels from public, anon, authenticated, service_role;

-- No client holds anything here, which is the whole point of the table. The worker
-- writes through a `security invoker` function on its secret key, and upserts rather
-- than inserts because §8.4 redelivers a job whose worker died after the write.
-- `select` is part of that: Postgres requires it for `on conflict do update`, which
-- the allow test found rather than an API test finding it later.
grant select, insert, update on table media_labels to service_role;

-- §5.2's Access column for this table is "—", so RLS is on and there is no policy:
-- every role that can hold anything here bypasses it anyway (§17.1).
alter table media_labels enable row level security;

-- §13.3 takes a destructive change in two releases: "add the new structure and move
-- the data, then remove the old one in a later release." Moved, then emptied — §10.3
-- reviews held content "with screening labels", so a verdict discarded here is one a
-- moderator never sees again, and a verdict left in place stays readable by every
-- signed-in person for the length of the window `O21` exists to close. The column
-- itself goes in the later release.
insert into media_labels (media_id, labels)
select id, labels from media where labels is not null
on conflict (media_id) do nothing;

update media set labels = null where labels is not null;
revoke update (labels) on table media from service_role;
