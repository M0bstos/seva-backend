create table act_metrics (
  act_id uuid not null references acts (id) on delete cascade,
  metric metric not null,
  value numeric(10,2) not null,
  primary key (act_id, metric),
  constraint act_metrics_value_positive check (value > 0),
  constraint act_metrics_whole_numbers_where_required
    check (metric in ('waste_kg', 'volunteer_hours') or value = trunc(value))
);

revoke all on table act_metrics from public, anon, authenticated, service_role;

grant select on table act_metrics to authenticated;
grant select, insert on table act_metrics to service_role;

alter table act_metrics enable row level security;

create policy act_metrics_select on act_metrics
  for select to authenticated
  using (
    exists (
      select 1 from acts
      where acts.id = act_metrics.act_id
        and acts.status = 'visible'
    )
  );
