-- §7.3: "The operations worker calls `export_account(user_id)`, one Postgres call returning
-- jsonb, and writes `exports/{user_id}/{export_id}.json` to the private `exports` bucket.
-- Published photos appear as public URLs; unpublished ones are listed without a URL." §11.2
-- makes it the access right — "Access and correction | `GET /account/export`; profile edits".
--
-- **`security invoker`, not definer, which is a deliberate departure from the brief for this
-- phase.** §5.2 grants `service_role` `select` on every table this reads — `profiles`,
-- `profile_private`, `acts`, `act_metrics`, `media`, `activity_participants`, `activities`,
-- `supports`, `blocks`, `reports`, `impact_entries`, `impact_totals` — so definer buys
-- nothing and costs the thing §9.1 warns about: "a definer body owned by `postgres` is the
-- one place a flaw escalates past the schema it writes", and this body reads every column of
-- one person's whole account. CLAUDE.md's rule is `security invoker` unless definer is
-- required, and here it is not. The two functions §11.6 *does* require to be definer are the
-- retention purge and the deletion, because `service_role` holds nothing on the two
-- retention tables.
--
-- **The base URL is an argument** because the database does not know the project's URL and
-- §7.3 asks for public URLs rather than paths. The alternative is the worker rewriting a
-- large jsonb document after the fact; this way the one place that knows which photos are
-- published is the one that writes their URLs. It is not a secret — §7.3 publishes those
-- objects to anybody.
--
-- **What it does not carry: the phone number and the email address.** They live in Supabase
-- Auth (§5.4), not in a SEVA table, so including them would mean this body reading
-- `auth.users` — which §17's `O16` grant does not cover and which the definer-body lint in
-- `tests/security/auth_users_grant.test.sql` exists to keep out of `public`. Whether DPDP's
-- access right reaches the contact details Auth holds is a legal reading, recorded in §17.1
-- and listed as an open item; a person can see both in the app's own account screen today.
create function export_account(p_user_id uuid, p_media_base_url text) returns jsonb
language sql
security invoker
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'exported_at', now(),
    'user_id', p_user_id,
    -- §7.2's own two profile resources, which are what §11.2's correction right edits.
    'profile', (
      select to_jsonb(p) - 'avatar_path' || jsonb_build_object(
        'avatar_url', case
                        when p.avatar_path is not null
                        then p_media_base_url || '/' || p.avatar_path
                      end)
      from public.profiles p where p.id = p_user_id
    ),
    'private', (
      select to_jsonb(pp) from public.profile_private pp where pp.user_id = p_user_id
    ),
    -- Every Act with its claims and its photos. §7.3: "Published photos appear as public
    -- URLs; unpublished ones are listed without a URL" — a photo is published exactly when
    -- it is `ready` and carries a `public_path`, which §8.1's invariant pairs.
    'acts', coalesce((
      select jsonb_agg(
        -- The coarse grid as coordinates rather than PostGIS's hex, and not dropped: it is the
        -- person's own data and §5.4 has already coarsened it to about 5 km at write time, so
        -- withholding it refuses §11.2's access right without protecting anything. The export
        -- goes to the person themselves over a signed URL that `O7` expires in seven days.
        to_jsonb(a) - 'location_coarse' || jsonb_build_object(
          'location_coarse', case when a.location_coarse is null then null else
            jsonb_build_object(
              'lon', extensions.st_x(a.location_coarse::extensions.geometry),
              'lat', extensions.st_y(a.location_coarse::extensions.geometry))
          end,
          'metrics', coalesce((
            select jsonb_object_agg(m.metric::text, m.value)
            from public.act_metrics m where m.act_id = a.id
          ), '{}'::jsonb),
          'photos', coalesce((
            select jsonb_agg(jsonb_build_object(
              'id', d.id, 'position', d.position, 'status', d.status,
              'url', case
                       when d.status = 'ready' and d.public_path is not null
                       then p_media_base_url || '/' || d.public_path
                     end))
            from public.media d where d.act_id = a.id
          ), '[]'::jsonb)
        )
        order by a.created_at
      )
      from public.acts a where a.author_id = p_user_id
    ), '[]'::jsonb),
    -- Activities they organised, and the ones they joined. §9.6 keeps a minor off other
    -- people's participant lists; this is their own, which is the one list they may see.
    'activities_organised', coalesce((
      -- With the meeting point. §5.4 makes an Activity's location exact and public precisely so
      -- people can be told where to turn up, so the organiser getting nothing back for their own
      -- event was the clearest case of the omission review found.
      select jsonb_agg(
        to_jsonb(c) - 'location' || jsonb_build_object(
          'location', case when c.location is null then null else
            jsonb_build_object(
              'lon', extensions.st_x(c.location::extensions.geometry),
              'lat', extensions.st_y(c.location::extensions.geometry))
          end)
        order by c.created_at)
      from public.activities c where c.organiser_id = p_user_id
    ), '[]'::jsonb),
    'activities_joined', coalesce((
      select jsonb_agg(to_jsonb(ap) order by ap.joined_at)
      from public.activity_participants ap where ap.user_id = p_user_id
    ), '[]'::jsonb),
    'supports', coalesce((
      select jsonb_agg(to_jsonb(sp) order by sp.id)
      from public.supports sp where sp.user_id = p_user_id
    ), '[]'::jsonb),
    'blocks', coalesce((
      select jsonb_agg(to_jsonb(b)) from public.blocks b where b.blocker_id = p_user_id
    ), '[]'::jsonb),
    -- Reports they filed, and nothing about reports filed against them: those are somebody
    -- else's text about them, and §7.2 gives no client a read on `reports` at all. The
    -- resolution columns go with them, because a moderator's note is not the reporter's.
    --
    -- **The subject ids are in the list**, which they were not: an export read "a report about
    -- a profile, for spam" with no way to tell which, found in review and unintended rather
    -- than decided. They disclose nothing new — the person supplied each id when they filed —
    -- and without them §11.2's access right returns a list its subject cannot read.
    'reports_filed', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'subject_type', r.subject_type, 'reason', r.reason,
        'details', r.details, 'status', r.status, 'created_at', r.created_at,
        'act_id', r.act_id, 'activity_id', r.activity_id,
        'reported_user_id', r.reported_user_id)
        order by r.created_at)
      from public.reports r where r.reporter_id = p_user_id
    ), '[]'::jsonb),
    -- §6.4: "every point traces back to an Act, a rule and a time", so the ledger is part of
    -- the export, with the same coarse coordinates as the Acts above.
    'points', jsonb_build_object(
      'totals', (
        select to_jsonb(t) from public.impact_totals t where t.user_id = p_user_id
      ),
      'entries', coalesce((
        select jsonb_agg(
          to_jsonb(e) - 'location_coarse' || jsonb_build_object(
            'location_coarse', case when e.location_coarse is null then null else
              jsonb_build_object(
                'lon', extensions.st_x(e.location_coarse::extensions.geometry),
                'lat', extensions.st_y(e.location_coarse::extensions.geometry))
            end)
          order by e.created_at)
        from public.impact_entries e where e.user_id = p_user_id
      ), '[]'::jsonb)
    )
  );
$$;

revoke execute on function export_account(uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function export_account(uuid, text) to service_role;
