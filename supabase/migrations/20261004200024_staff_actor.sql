-- §10's opening rule, which every one of §10.2's nine functions has to obey: "Every staff
-- action is a Postgres function that **checks the person's role and MFA**, requires a
-- reason, and writes the audit log in the same transaction." §9.1 puts that check on a
-- definer function's first line, and §9.3 fixes what MFA means here — "Staff accounts:
-- Authenticator-app MFA required; staff functions require `aal2`".
--
-- One function rather than nine copies, because §9.7's callout makes this check
-- load-bearing in a way nothing in CI can see: gate 3 excludes `admin\_%` by design and
-- gate 4 only checks that `search_path` is pinned, "so for any `admin_*` function … the
-- first-line role and MFA check required by §9.1 and §10 is the only control". Nine
-- hand-written copies of the only control is how one of them ends up subtly different.
--
-- Returns the staff member's own id, which §5.2.1 wants in `admin_audit_log.staff_id`
-- ("set exactly when actor = 'staff'"), or null when the caller is not staff, is not
-- senior enough, or has not completed MFA. Null rather than a raise: the callers answer
-- §7.4's `FORBIDDEN`, and a raise would reach Appsmith as a 500.
--
-- `security invoker` and `stable`: it reads `public.staff` and the request's own claims
-- and writes nothing. It is reached only from the `admin_*` definer bodies, which run as
-- their owner, so it needs no grant of its own — and `auth.uid()` and `auth.jwt()` read
-- a session setting rather than anything role-dependent, so the answer is the caller's
-- either way.
--
-- The enum comparison is what §10.1's two rows mean: §5.3 declares `staff_role` as
-- ('moderator', 'admin') in that order, so `role >= 'moderator'` is "a moderator or an
-- admin" and `role >= 'admin'` is admin alone. §10.1 gives an admin "everything a
-- moderator can, plus …", which is exactly that ordering.
create function private.staff_actor(p_minimum staff_role) returns uuid
language sql
security invoker
stable
set search_path = ''
as $$
  select s.user_id
  from public.staff s
  -- **A suspended account holds no staff power**, which was a gap found in review and is the
  -- safest reading rather than a stated rule: nothing in §10.1 says suspension strips the role,
  -- and §5.4's "staff are demoted, never deleted" points at demotion as the intended lever. But
  -- measured, without this an admin could suspend a moderator indefinitely and that moderator
  -- could immediately suspend the admin back for §10.1's seven days — and `admin_suspend_user`'s
  -- own note records that nothing in Auth reads `profiles.status`, so the queued sign-out does
  -- not stop them signing in again with a fresh `aal2` token. The only containment that worked
  -- was `admin_set_staff`, which needs an admin session nobody would still have. `O33` already
  -- bars a suspended account from writing, and a staff action is a write.
  join public.profiles p on p.id = s.user_id and p.status = 'active'
  where s.user_id = (select auth.uid())
    and s.role >= p_minimum
    -- §9.3's `aal2`. Compared against the claim rather than against a list, so a session
    -- carrying no `aal` at all — which is what a token issued before MFA was enrolled
    -- looks like — fails closed.
    and coalesce(auth.jwt() ->> 'aal', '') = 'aal2';
$$;

revoke execute on function private.staff_actor(staff_role)
  from public, anon, authenticated, service_role;
