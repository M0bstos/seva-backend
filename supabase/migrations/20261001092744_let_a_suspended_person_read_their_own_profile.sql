-- §17 `O15`, decided during the build, 1 October 2026: **yes.** §5.2's `profiles` cell
-- said "Read visible" where the cells either side say "and own", so the applied policy
-- was `status = 'active'` and a suspended person could not read their own row.
--
-- Why that is the wrong half of `O15`'s choice. `O33` already decided a suspended
-- account cannot write and answers `FORBIDDEN`, so the client can already tell
-- suspension from being un-onboarded on a *write* — an un-onboarded caller gets
-- `ONBOARDING_REQUIRED`. What it could not do is say anything useful: `status` and
-- `suspended_until` were unreadable, so an app could show a person neither that they
-- were suspended nor until when. §10.2 suspends for up to 7 days, and §11.6's
-- grievance duties assume a person knows what happened to them well enough to
-- complain about it. No new §7.4 code is needed; the row is the answer.
--
-- Only their own row. Everyone else still sees active profiles alone, so a suspended
-- person stays invisible to other people — which is what §5.2's "Read visible" is
-- about, and what §9.6 relies on for minors.
alter policy profiles_select on profiles
  using (status = 'active' or id = (select auth.uid()));
