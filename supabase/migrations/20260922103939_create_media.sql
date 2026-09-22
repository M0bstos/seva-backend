create table media (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references profiles (id) on delete cascade,
  purpose media_purpose not null,
  act_id uuid references acts (id) on delete cascade,
  activity_id uuid references activities (id) on delete cascade,
  position smallint not null default 0 check (position between 0 and 9),
  upload_path text not null unique,
  public_path text,
  thumb_path text,
  bytes int check (bytes between 1 and 5242880),
  width int check (width > 0),
  height int check (height > 0),
  status media_status not null default 'uploading',
  labels jsonb,
  created_at timestamptz not null default now(),
  constraint media_at_most_one_parent check (num_nonnulls(act_id, activity_id) <= 1),
  -- A photo is uploaded before the Act exists (§8.1), so a parent may be null here.
  -- What the check forbids is a parent that disagrees with the purpose.
  constraint media_parent_matches_purpose check (
    (act_id is null or purpose = 'act')
    and (activity_id is null or purpose = 'activity')
  )
);

create index media_act_id on media (act_id);
create index media_activity_id on media (activity_id);
create index media_status_created_at on media (status, created_at);

revoke all on table media from public, anon, authenticated, service_role;

grant select on table media to authenticated;
grant select on table media to service_role;
grant insert (id, owner_id, purpose, upload_path) on table media to service_role;
grant update (act_id, activity_id, position, public_path, thumb_path,
              bytes, width, height, status, labels)
  on table media to service_role;

alter table media enable row level security;

create policy media_select on media
  for select to authenticated
  using (
    owner_id = (select auth.uid())
    or (
      status = 'ready'
      and (
        exists (select 1 from acts where acts.id = media.act_id)
        or exists (select 1 from activities where activities.id = media.activity_id)
      )
    )
  );
