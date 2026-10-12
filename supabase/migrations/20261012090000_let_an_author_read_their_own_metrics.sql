-- §17 `O19`, decided during the build on 12 October 2026. §7.2's `acts` row reads "Visible minus
-- blocked authors, **plus your own**. Embed `act_metrics` and `media`" — so an author reads their
-- own Act in any status, and the row tells a client to embed its metrics. `act_metrics_select`
-- allowed only `status = 'visible'`, so the embed came back empty for exactly the rows "plus your
-- own" was written for: an author whose Act was still in screening saw no metrics on their own
-- claim.
--
-- **The policy now defers entirely to `acts_select` rather than restating it**, which mutation
-- testing is what found. The first version of this fix repeated `acts_select`'s two arms — own, or
-- visible and not blocked — and removing the blocked arm changed nothing I could measure. The
-- reason is a Postgres behaviour worth recording: **a table referenced inside an RLS policy's
-- `using` expression is itself subject to that table's RLS** for a role that does not bypass it. So
-- `exists (select 1 from acts where acts.id = act_metrics.act_id)` already means "the parent Act is
-- one I can read", which is §7.2's rule exactly — and the two policies can no longer drift, where
-- a restated condition would have to be kept in step by hand.
--
-- `media_select` already relies on the same behaviour: its arm for a photo on an Act is a bare
-- `exists (select 1 from acts where acts.id = media.act_id)` with no status test of its own. This
-- brings `act_metrics` into line with it rather than inventing a shape.
--
-- Measured, with the bare `exists`: an author reads their own pending Act's metrics; a reader who
-- has blocked the author reads neither the visible Act's metrics nor the pending one's; and nothing
-- else changed, which the existing assertions in `tests/rls/act_metrics.test.sql` cover.
--
-- `media` needed no change — an author's own photo is reachable through `media_select`'s
-- `owner_id = auth.uid()` arm, since §8.1 accepts only photos the caller owns, so the owner and the
-- author are the same person.
--
-- Dropped and recreated rather than edited: §5.2.1's migration is applied, and §13.3's roll-forward
-- rule is what every other policy change in this build has followed.
drop policy act_metrics_select on act_metrics;

create policy act_metrics_select on act_metrics
  for select to authenticated
  using (
    exists (
      select 1 from acts
      where acts.id = act_metrics.act_id
    )
  );
