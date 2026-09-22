create table activity_participants (
  activity_id uuid not null references activities (id) on delete cascade,
  user_id uuid not null references profiles (id) on delete cascade,
  status participant_status not null default 'joined',
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  primary key (activity_id, user_id),
  constraint activity_participants_left_at_matches_status
    check ((left_at is not null) = (status = 'left'))
);

create index activity_participants_user_id on activity_participants (user_id);

revoke all on table activity_participants from public, anon, authenticated, service_role;

grant select on table activity_participants to authenticated;
grant select on table activity_participants to service_role;
grant insert (activity_id, user_id) on table activity_participants to service_role;
grant update (status, left_at) on table activity_participants to service_role;

alter table activity_participants enable row level security;

create policy activity_participants_select on activity_participants
  for select to authenticated
  using (user_id = (select auth.uid()));
