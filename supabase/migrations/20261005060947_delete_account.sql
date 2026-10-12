-- §5.5 and §5.4's deletion: "Account deletion removes the profile, private record, Acts,
-- photos, participations, supports, blocks and filed reports, **after** copying anything
-- `removed` or `held` into `private.preserved_content` and the registration details into
-- `private.retained_registrations` (§11.6)."
--
-- `security definer`, and §11.6 says why in as many words: "The account deletion function is
-- definer for the same reason, and writes both retention tables in its own frame … and
-- `service_role` holds nothing on either." It lives in `public` so gate 4 sees the pinned
-- `search_path`, every name is schema-qualified, and there is no dynamic SQL (§9.1).
--
-- **It is the one function in `public` that reads a phone number, and the `auth.users` lint
-- names it as the single exception.** §11.6 compels that read: "`private.retained_registrations`
-- is the one place a phone number exists outside Supabase Auth", and the values are about to
-- be destroyed in Auth by the delete below, so there is no later moment to copy them. §11.6's
-- own constraint on this frame is obeyed — "neither function may return or log `phone` or
-- `email`" — and `tests/security/auth_users_grant.test.sql` asserts both: the exception list
-- is exactly one function, and this function's answer carries neither value.
--
-- **The deletion is one `delete from auth.users`.** §5.2.1 points `profiles.id` at it `on
-- delete cascade`, so one statement erases the profile, the private record, the Acts and
-- their metrics, the photos, the participations, the supports, the blocks and the reports
-- they filed — in one transaction with the retention writes, which is what makes §11.6's
-- copy-first ordering airtight rather than a sequence something could interrupt. §17.1
-- records that `postgres` holds `d` on `auth.users` by grant from `supabase_auth_admin`.
-- §5.4's ledger rule rides on the same cascade: "`user_id` and `act_id` are set to null by
-- the foreign keys themselves, so campaign totals stay correct with no extra code."
create function delete_account(p_user_id uuid) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_registration record;
  v_preserved int := 0;
  v_cancelled int := 0;
  v_notified int := 0;
begin
  -- §5.2.1 gives `account_deletions` a key with no foreign key, so the request row is what
  -- authorises this rather than anything about the account. Locked, because the operations
  -- worker retries (§8.4) and two runs must not both do the work.
  perform 1 from public.account_deletions
  where user_id = p_user_id and status in ('pending', 'failed')
  for update;
  if not found then
    -- Already completed, or never asked for. Either way there is nothing to do, and §8.4's
    -- retry should stop rather than keep trying.
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;

  -- **A staff account cannot be erased, and §5.4 is the authority: "Staff are demoted, never
  -- deleted."** Measured in review: `staff.user_id` is the only `on delete restrict` reaching
  -- `profiles`, so without this check the single delete at the end raises 23503, the whole
  -- transaction rolls back — cleanly, with no partial state — and §8.4 burns five retries before
  -- archiving with an alarm, leaving a §11.2 erasure that never completes and never says why.
  --
  -- Refused here instead, with the request marked `failed` so §7.3's `POST /account/delete` and
  -- §10.3's screens both show it. `admin_set_staff` is the step that unblocks it, which is §5.4's
  -- "demoted" — and it has to be a person's decision, because removing somebody's staff row is
  -- exactly the action §10 requires an audit row for.
  if exists (select 1 from public.staff where user_id = p_user_id) then
    update public.account_deletions
    set status = 'failed'
    where user_id = p_user_id;
    return jsonb_build_object('error', 'FORBIDDEN');
  end if;

  -- **§11.6's copy-first ordering, step one.** "Account deletion copies anything `removed` or
  -- `held` into `private.preserved_content` **before** deleting anything else, so a user
  -- cannot erase the record of their own violation by deleting their account." The snapshot
  -- shape is `set_content_status`'s, so one `source_kind` vocabulary serves both writers.
  --
  -- It has to happen before the delete for a second reason §17.1 records: `queue_media_deletion`
  -- skips a file named in a live retention row, and that check can only pass if the row is
  -- already there when the cascade fires.
  -- **The 180 days run from the removal, not from the erasure**, which took two review rounds
  -- to get right. `private.preserved_content` has no unique key on `(source_kind, source_id)` —
  -- deliberately, so a missing snapshot can never abort an erasure that carries a legal clock —
  -- so `set_content_status` having already preserved a removal meant this wrote a *second* row.
  -- The first fix skipped content with a live snapshot, which left the case the second round
  -- reproduced: content removed 200 days ago, whose snapshot the purge has already released,
  -- got a brand-new 180 days and `file_paths` naming objects that no longer exist.
  --
  -- `purge_after` is therefore computed from the row's own `status_changed_at` — the moment it
  -- became `removed` — and a removal whose window has already closed is not copied at all. It is
  -- what §11.6 and `O7` actually say: 180 days from the removal, which is also where rule
  -- 3(1)(g)'s clock starts. A longer retention is not a safer default but a different one,
  -- against DPDP's storage limitation. The live-snapshot skip stays, so a takedown inside its
  -- window keeps the one row it already has rather than gaining a duplicate. On the hold arm that
  -- skip is unreachable and deliberately kept: `set_content_status` snapshots only a removal,
  -- `removed` is terminal, and a previous erasure cannot have written one — so a `held` row can
  -- never have a live snapshot, and the clause is conservative rather than a deduplication rule
  -- anybody should rely on.
  --
  -- **The clock and the floor apply to `removed` only, not to `held`**, which the third round
  -- corrected. Rule 3(1)(g)'s 180 days run from a *takedown*; a held item has never been
  -- adjudicated, so `status_changed_at` is when the allegation was raised and not when anything
  -- was decided. Applying removal's clock to it is the lenient reading, and §11.6's preamble says
  -- "the backend assumes the strict reading, because the strict reading costs a little storage and
  -- the lenient one costs a takedown deadline" — and measured, the lenient one here destroyed a
  -- six-month-held item with no record at all. A hold therefore gets 180 days from the erasure,
  -- which is what this function did before the clock was introduced.
  --
  -- **Each row carries its own clock, and no snapshot stands in for another**, which is the other
  -- half of that round. The media branch used to skip a photo whose parent was held or removed, on
  -- the grounds that the parent's `file_paths` already named it — true of the *paths* and false of
  -- the *clock* once clocks became per-row. Two measured consequences: a photo held 10 days ago
  -- under an Act held 190 days ago was preserved by nothing and destroyed on day 0, and a photo
  -- held 10 days ago under an Act held 100 days ago had its file released at day 80 instead of day
  -- 170. Both are gone now that the branch preserves every held or removed photo on its own
  -- merits. The duplicate reference that creates — a path named by both the parent's snapshot and
  -- the photo's — is safe because `purge_retained_records` will not delete a path another live
  -- retention row still names, which is the same test `queue_media_deletion` applies.
  with kept as (
    insert into private.preserved_content (source_kind, source_id, snapshot, file_paths,
                                           purge_after)
    select 'act', a.id,
           to_jsonb(a) || jsonb_build_object(
             'metrics',
             (select coalesce(jsonb_object_agg(m.metric::text, m.value), '{}'::jsonb)
              from public.act_metrics m where m.act_id = a.id)),
           -- **Only the files of photos that are themselves held or removed.** Review measured
           -- the last place a parent snapshot stood in for a child: with no status filter, a
           -- `ready` photo of a `held` Act was named by the Act's snapshot, so after the erasure
           -- `queue_media_deletion` found a live retention row naming its path and suppressed the
           -- deletion — and the photo kept being served from the public `media` bucket for 180
           -- days. Nothing moves it to `quarantine`, because that step runs only on `removed`.
           -- §11.6's retention design assumes a retained object sits in a private bucket, and that
           -- photo was never held or removed, so it is not retained content at all: §11.2's
           -- erasure left a publicly fetchable photo of a deleted account. Same principle as the
           -- media branch below — a snapshot names only what it is the record of.
           (select array_agg(distinct pth.path)
            from public.media d
            cross join lateral unnest(
              array_remove(array[d.upload_path, d.public_path, d.thumb_path], null)
            ) as pth (path)
            where d.act_id = a.id and d.status in ('held', 'removed')),
           case when a.status = 'removed'
                then a.status_changed_at + interval '180 days'
                else now() + interval '180 days' end
    from public.acts a
    where a.author_id = p_user_id and a.status in ('removed', 'held')
      and (a.status <> 'removed'
           or a.status_changed_at > now() - interval '180 days')
      and not exists (
        select 1 from private.preserved_content pc
        where pc.source_kind = 'act' and pc.source_id = a.id and pc.purge_after > now()
      )
    union all
    select 'activity', c.id, to_jsonb(c),
           (select array_agg(distinct pth.path)
            from public.media d
            cross join lateral unnest(
              array_remove(array[d.upload_path, d.public_path, d.thumb_path], null)
            ) as pth (path)
            where d.activity_id = c.id and d.status in ('held', 'removed')),
           case when c.status = 'removed'
                then c.status_changed_at + interval '180 days'
                else now() + interval '180 days' end
    from public.activities c
    where c.organiser_id = p_user_id and c.status in ('removed', 'held')
      and (c.status <> 'removed'
           or c.status_changed_at > now() - interval '180 days')
      and not exists (
        select 1 from private.preserved_content pc
        where pc.source_kind = 'activity' and pc.source_id = c.id and pc.purge_after > now()
      )
    union all
    -- Every held or removed photo the two branches above do not already carry. **Not just
    -- the parentless ones**, which was a defect found in review: the test was `act_id is
    -- null and activity_id is null`, so a photo `held` under a *live* parent was preserved
    -- by nothing, `queue_media_deletion` found no retention row naming its files, and the
    -- cascade destroyed them on day 0 — reopening the §11.6 defect of 3 October through a
    -- case its test could not see. Two ordinary paths reach that state: a moderator calling
    -- `admin_set_content_status` on the photo alone, which deliberately does not cascade to
    -- the parent, and `complete_photo_screening` holding both followed by a moderator
    -- approving only the Act. `set_content_status` writes a snapshot on removal and not on a
    -- hold, so nothing else records it either.
    --
    -- The condition is "no parent snapshot covers it", which is what the two branches above
    -- actually guarantee: a parentless avatar passes both tests, and so does a photo whose
    -- parent is `visible` or `pending`.
    select 'media', d.id, to_jsonb(d),
           array_remove(array[d.upload_path, d.public_path, d.thumb_path], null),
           case when d.status = 'removed'
                then d.status_changed_at + interval '180 days'
                else now() + interval '180 days' end
    from public.media d
    where d.owner_id = p_user_id
      and d.status in ('held', 'removed')
      and (d.status <> 'removed'
           or d.status_changed_at > now() - interval '180 days')
      and not exists (
        select 1 from private.preserved_content pc
        where pc.source_kind = 'media' and pc.source_id = d.id and pc.purge_after > now()
      )
    returning 1
  )
  select count(*) into v_preserved from kept;

  -- **Step two: the registration details.** §11.6's table — "phone, email, account created and
  -- deleted dates" — plus the three columns `O23` added: "the policy versions accepted and
  -- their timestamp are kept in the same row". All three are nullable because "an account
  -- deleted before onboarding accepted no policy".
  --
  -- This is the read the lint names an exception for. Nothing below returns or logs either
  -- value, and the record exists so that §11.6's rule 3(1)(h) duty survives the erasure.
  select u.created_at as account_created_at, u.phone, u.email,
         pp.terms_version, pp.privacy_version, pp.accepted_at
  into v_registration
  from auth.users u
  left join public.profile_private pp on pp.user_id = u.id
  where u.id = p_user_id;
  if not found then
    -- The Auth row is gone already, so there is nothing to erase and nothing to retain. The
    -- request is marked completed below rather than retried for ever.
    update public.account_deletions
    set status = 'completed', completed_at = now()
    where user_id = p_user_id;
    return jsonb_build_object('status', 'completed', 'preserved', v_preserved);
  end if;

  insert into private.retained_registrations (
    user_id, phone, email, account_created_at,
    terms_version, privacy_version, accepted_at
  ) values (
    p_user_id, v_registration.phone, v_registration.email,
    v_registration.account_created_at,
    v_registration.terms_version, v_registration.privacy_version,
    v_registration.accepted_at
  );

  -- §5.4: "Future Activities the person organised are cancelled and participants are emailed;
  -- past Activities survive with a null `organiser_id`." The survival is the `set null` on the
  -- foreign key; the cancellation is this, and it must happen before the delete because
  -- afterwards there is no `organiser_id` left to find them by.
  with cancelled as (
    update public.activities
    set cancelled_at = now()
    where organiser_id = p_user_id
      and starts_at > now()
      and cancelled_at is null
    returning id
  ),
  told as (
    select pgmq.send('email', jsonb_build_object(
      'kind', 'activity_cancelled',
      'activity_id', ap.activity_id,
      'user_id', ap.user_id
    )) as sent
    from public.activity_participants ap
    join cancelled c on c.id = ap.activity_id
    where ap.status = 'joined' and ap.user_id <> p_user_id
  )
  select (select count(*) from cancelled), (select count(*) from told)
  into v_cancelled, v_notified;

  -- Open reports about this person's content, which the cascade is about to leave naming
  -- nothing: §5.2.1 nulls the subject `on delete set null` while its own check keeps `status`
  -- at `open` without a `resolved_at`, so they would sit in §12.5's report arms for ever with
  -- no moderator able to action them. `resolved_by` is null because nobody decided — §5.2.1
  -- makes that column nullable, and the note says what happened.
  --
  -- **Activities are not in this list**, which was a defect found in review. The justification
  -- is that the subject is about to stop existing, and that is true of an Act
  -- (`author_id on delete cascade`) and of a profile — but `activities.organiser_id` is
  -- `on delete set null`, so **no Activity is ever deleted here**. The future ones are
  -- cancelled, their `status` stays `visible`, and `discover_activity` deliberately does not
  -- filter `cancelled_at` because "the link is already in somebody's hands" — and it runs with
  -- `verify_jwt = false`. So dismissing those reports discharged a §11.6 grievance deadline
  -- while a logged-out caller could still fetch the reported title, description and exact
  -- meeting point, with the grievance reading "decided by nobody" and off §12.5's 18-hour arm.
  -- Reports about *past* Activities were already left open for the same reason, which is the
  -- asymmetry that gave this away. Whether a cancelled-but-visible Activity should go to
  -- `removed` is for the owner (§17.1).
  update public.reports
  set status = 'dismissed',
      resolved_at = now(),
      resolution_note = 'subject deleted with the account'
  where status = 'open'
    and (reported_user_id = p_user_id
      or act_id in (select id from public.acts where author_id = p_user_id));

  -- **Step three.** One statement, and §5.2.1's cascades do the rest. The `media` delete
  -- trigger fires inside it and skips every file named in a retention row still inside its
  -- 180 days, which is why step one had to come first.
  delete from auth.users where id = p_user_id;

  update public.account_deletions
  set status = 'completed', completed_at = now()
  where user_id = p_user_id;

  -- Counts only. §11.6 forbids this frame returning `phone` or `email`, and a count of
  -- preserved rows is what the worker logs (§9.8 allows a user id and a count, nothing else).
  return jsonb_build_object(
    'status', 'completed',
    'preserved', v_preserved,
    'cancelled', v_cancelled,
    'notified', v_notified
  );
end;
$$;

revoke execute on function delete_account(uuid)
  from public, anon, authenticated, service_role;
-- CLAUDE.md: on the retention tables themselves "`service_role` holds nothing; what it holds
-- is `execute` on the two functions a worker calls — the purge and the account-deletion
-- function (§5.5)". This is the second of those two.
grant execute on function delete_account(uuid) to service_role;
