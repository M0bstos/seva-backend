-- §6.1: "Points are awarded at the moment an Act becomes `visible`, not when it is
-- created." This is that moment. The trigger writes "one ledger row for publishing,
-- one per claimed metric, and one bonus row if the Act documents an Activity the
-- author joined", in that order.
--
-- `security definer` (§17.1), like the counter triggers: `impact_entries` grants
-- `service_role` `select` and nothing else, which is what §9.2 means by points having
-- no client write path — not even the route functions can write one. §9.1's four
-- requirements hold: it lives in `public`, pins `search_path = ''`, builds no dynamic
-- SQL, and a trigger's first-line permission check is the one that already happened —
-- it fires only on a status change the writer held a grant to make.
create function award_act_points() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cap int;
  v_used int;
  v_remaining int;
  v_campaign_id uuid;
  v_documented boolean;
  v_points int;
  v_row record;
begin
  -- §10.2's kill switch. §12.6's "points exploit" step turns it off, fixes, "then
  -- rebuilds the affected totals from the ledger" — so writing no row at all is the
  -- right nothing to do, and the Act still becomes visible.
  if exists (select 1 from public.app_flags where key = 'award_points' and engaged) then
    return null;
  end if;

  -- §8.3 sends an edited Act visible → pending → visible, and §8.3's held → visible
  -- is a moderator approving one. An Act earns once; the ledger is what says so,
  -- rather than a second column that could disagree with it.
  if exists (select 1 from public.impact_entries where act_id = new.id) then
    return null;
  end if;

  -- §6.3 calls the caps "a fraud control rather than a tuning knob", and a control two
  -- concurrent publications can both read before either commits is not one: each would
  -- award against the whole remaining budget and the day would pass 300. The author's
  -- own totals row is what serialises them. Made first if it is missing, because a
  -- first-time author has no row to lock and `update_impact_totals` needs one a moment
  -- later anyway.
  insert into public.impact_totals (user_id)
  values (new.author_id)
  on conflict (user_id) do nothing;

  perform 1 from public.impact_totals where user_id = new.author_id for update;

  -- §6.3's two caps are constants in this function, not rows: "changing one is a
  -- migration". "First 7 days" is 7 × 24 hours from `auth.users.created_at`, "not
  -- from the first Act, so a dormant account cannot wait out the lower cap".
  --
  -- §17 `O16` chose a column grant over a definer helper partly to keep this cap "out
  -- of a definer body CI cannot inspect", and this body is a definer one — §9.2 gives
  -- the ledger no write path at all, so the award has nowhere else to happen. A
  -- `service_role`-owned definer would have restored the privilege boundary, but
  -- ownership needs `create` on the schema and granting that to `service_role` is a
  -- far wider hole than the one it closes (measured). So the compensating control is
  -- a CI assertion over this body's text, in
  -- `supabase/tests/security/auth_users_grant.test.sql`: it may name `id` and
  -- `created_at` and no other column of `auth.users`.
  select case when u.created_at > now() - interval '7 days' then 100 else 300 end
  into v_cap
  from auth.users u
  where u.id = new.author_id;

  -- §6.1: summed from the ledger and not from the rate-limit counters, "which are
  -- unlogged and may reset". The day is §5.1's Asia/Kolkata calendar day.
  select coalesce(sum(e.points), 0) into v_used
  from public.impact_entries e
  where e.user_id = new.author_id
    and e.created_at >=
      date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';

  v_remaining := greatest(v_cap - v_used, 0);

  -- `O17`: an Act carries no `campaign_id`. It reaches a campaign through the
  -- Activity it documents, and this is where that campaign lands on the ledger rows
  -- §6.1 counts campaign progress from.
  --
  -- **Attributed only when the author joined.** `acts.activity_id` is caller-supplied
  -- and this frame holds the one write to `campaigns` that nobody else has, so an
  -- unconditional attribution made a signed-in stranger's claim advance any active
  -- campaign's published `progress_value` — reproduced on the local stack: a user who
  -- joined nothing moved a 5,000 kg goal by 600 kg in three Acts. The daily cap cannot
  -- bound it, because §6.1 keeps `value` at full size while clamping `points`. §2.1
  -- is the rule being enforced — "an Act can link to an Activity the author joined" —
  -- and `create_act` enforces it at the gate as well; this is the same condition at
  -- the place that does the writing.
  select
    case when p.user_id is not null then a.campaign_id end,
    p.user_id is not null
  into v_campaign_id, v_documented
  from public.activities a
  left join public.activity_participants p
    on p.activity_id = a.id and p.user_id = new.author_id and p.status = 'joined'
  where a.id = new.activity_id;

  for v_row in
    -- §6.1's three kinds in the order that section lists them. Every claimed metric
    -- gets a row whether or not its rule is active, because §6.3 gives `active` the
    -- job of governing scoring and not validity (§17.1) — an inactive rule scores
    -- zero, and the real-world impact still reaches `impact_totals`.
    select 1 as ord, null::public.metric as metric,
           'act_published'::public.ledger_kind as kind, null::numeric as value,
           floor(coalesce((select r.points_per_unit from public.points_rules r
                           where r.rule = 'act_published' and r.active), 0))::int as points
    union all
    select 2, m.metric, 'metric'::public.ledger_kind, m.value,
           floor(m.value * coalesce((select r.points_per_unit from public.points_rules r
                                     where r.rule = m.metric::text and r.active), 0))::int
    from public.act_metrics m
    where m.act_id = new.id
    union all
    -- §6.1's bonus row exists only when there is something to document. `joined` and
    -- not merely "has a row": §6.1 gives the bonus for documenting an Activity the
    -- author joined, and a `left` row is the record of having withdrawn from it. §5.3
    -- offers no third status, so withdrawing is the only signal there is.
    select 3, null, 'activity_documented'::public.ledger_kind, null,
           floor(coalesce((select r.points_per_unit from public.points_rules r
                           where r.rule = 'activity_documented' and r.active), 0))::int
    where coalesce(v_documented, false)
    -- §6.1 lists the kinds in this order and says nothing about the metrics among
    -- themselves. Ordered by the enum so the row that carries the cap remainder is
    -- the same one on every run, rather than whatever the planner returns first.
    order by ord, metric
  loop
    -- §6.1: "If the author has reached the daily cap, rows are still written with
    -- `points = 0`. Real-world impact still counts; points stop." The row that
    -- crosses the cap takes what is left of it, so the day lands on 300 exactly
    -- rather than under it — the value and the metric are still on the row, so §6.4's
    -- trace from a point back to an Act and a time survives.
    v_points := least(v_row.points, v_remaining);
    v_remaining := v_remaining - v_points;

    insert into public.impact_entries
      (user_id, act_id, kind, metric, value, points, campaign_id, location_coarse)
    values
      (new.author_id, new.id, v_row.kind, v_row.metric, v_row.value, v_points,
       v_campaign_id, new.location_coarse);
  end loop;

  return null;
end;
$$;

revoke execute on function award_act_points()
  from public, anon, authenticated, service_role;

create trigger acts_award_points
  after update of status on acts
  for each row
  when (new.status = 'visible' and old.status is distinct from 'visible')
  execute function award_act_points();
