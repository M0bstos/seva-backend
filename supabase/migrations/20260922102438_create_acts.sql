create table acts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references profiles (id) on delete cascade,
  activity_id uuid references activities (id) on delete set null,
  title text not null check (char_length(title) between 5 and 100),
  story text not null check (char_length(story) between 20 and 2000),
  category category not null,
  occurred_on date not null,
  location_coarse extensions.geography(point, 4326) not null,
  status content_status not null default 'pending',
  text_checked boolean not null default false,
  published_at timestamptz,
  idempotency_key uuid not null,
  request_hash text not null check (char_length(request_hash) = 64),
  created_at timestamptz not null default now(),
  constraint acts_author_idempotency unique (author_id, idempotency_key)
);

create index acts_location_coarse_visible
  on acts using gist (location_coarse) where status = 'visible';

create index acts_author_created_at on acts (author_id, created_at desc);

revoke all on table acts from public, anon, authenticated, service_role;

grant select on table acts to authenticated;
grant select on table acts to service_role;
grant insert (author_id, activity_id, title, story, category, occurred_on,
              location_coarse, idempotency_key, request_hash)
  on table acts to service_role;
grant update (title, story, status, text_checked, published_at)
  on table acts to service_role;

alter table acts enable row level security;

create policy acts_select on acts
  for select to authenticated
  using (
    author_id = (select auth.uid())
    or (
      status = 'visible'
      and not exists (
        select 1 from blocks
        where blocks.blocker_id = (select auth.uid())
          and blocks.blocked_id = acts.author_id
      )
    )
  );
