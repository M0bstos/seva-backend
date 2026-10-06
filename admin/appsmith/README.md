# The SEVA admin app

§10.3 of the specification: **Appsmith Community Edition**, self-hosted on the ops host in Mumbai,
with seven screens over the nine `admin_*` functions. "Appsmith stores screen definitions, not SEVA
data. The app is exported to `admin/appsmith/` in git."

## What is in this directory, and what is not

`screens/*.yaml` define every screen: the queries it runs, the parameters each query takes, and the
columns it shows. They are the reviewable part — a reviewer can check from these files alone that no
screen writes anything except through an `admin_*` function, which is the property §10 exists for.

**The Appsmith export JSON is not here, and could not be written by hand honestly.** An export
carries Appsmith's own `clientSchemaVersion` and `serverSchemaVersion` and a layout tree the editor
generates; a file written without an Appsmith to import it into would look like the deliverable and
fail on first import. §14.4 is where it is produced: build the screens from `screens/*.yaml` in
Appsmith once, export the application, and commit the JSON beside these files. §10.3's own words for
the build step are "Screens built by drag-and-drop; no backend code" — these files are the brief for
that drag-and-drop, and the export is its output.

## The two rules every screen follows

1. **Every write is an `admin_*` RPC.** §10: "Staff never edit tables directly. Every staff action is
   a Postgres function that checks the person's role and MFA, requires a reason, and writes the audit
   log in the same transaction. The admin tool is just screens over those functions, so it can't skip
   the audit trail and could be replaced without touching the backend." No screen may `PATCH` or
   `POST` a table through the Data API. A screen that did would be refused anyway — §9.2 gives
   `authenticated` no write on any column these screens change — but the point is that the refusal is
   not what anybody should be relying on.

2. **Every call runs as the staff member, never as a key.** §10.3: "Staff sign in to Appsmith, then
   sign in to their own SEVA staff account (email plus authenticator code) inside it. Every call runs
   as that person, so the audit log records who acted, not 'the admin tool'." So the datasource is
   configured with the **publishable** key and the signed-in staff member's access token, and the
   secret key must never be put in an Appsmith datasource: it would bypass `private.staff_actor`'s
   `auth.uid()` check and leave `staff_id` wrong on every audit row.

## The datasource

One authenticated REST datasource per environment (§12.7 keeps staging and production apart):

| Setting | Value |
| --- | --- |
| URL | `https://<project-ref>.supabase.co` |
| `apikey` header | the **publishable** key (§7.1: "Every request: `apikey: sb_publishable_…`") |
| `Authorization` header | `Bearer {{appsmith.user.sevaAccessToken}}` — the staff member's own token |
| `x-region` header | `ap-south-1` (§7.1) |

Reads go to `/rest/v1/<table>` and every write to `/rest/v1/rpc/admin_<name>`.

**MFA is not optional and not configurable here.** §9.3 requires `aal2` and
`private.staff_actor` refuses a token without it, so a staff member who has not enrolled an
authenticator app gets `FORBIDDEN` from every write on every screen. §14.1's "organisation MFA
enforced" is the Supabase half; this is the SEVA half.

## The screens

§10.3 names seven, and each has a file:

| File | §10.3's name | Writes through |
| --- | --- | --- |
| `screens/held-content.yaml` | held content, oldest first, with screening labels | `admin_set_content_status` |
| `screens/reports.yaml` | reports, with time left on the 24-hour target | `admin_resolve_report`, `admin_set_content_status` |
| `screens/people.yaml` | people (suspend, verify) | `admin_suspend_user`, `admin_set_verified`, `admin_hide_profile_text`, `admin_set_staff` |
| `screens/campaigns.yaml` | campaigns | `admin_upsert_campaign` |
| `screens/points-rules.yaml` | points rules | `admin_set_points_rule` |
| `screens/kill-switches.yaml` | kill switches | `admin_set_flag` |
| `screens/audit-log.yaml` | a read-only audit log | nothing — it is the record of the other six |

## What a moderator cannot see, and why that is deliberate

Three things a screen might reasonably want and must not have:

- **A phone number or an email address.** §5.4 keeps both in Supabase Auth and §9.8 keeps them out of
  logs; the admin app reads SEVA's own tables, which do not carry them. A moderator identifies a
  person by display name and user id.
- **A date of birth.** §9.2 puts it in `profile_private`, readable only by its owner, and §17.1
  records that even an age *band* is a disclosure. No screen reads that table.
- **An exact Act location.** §5.4 coarsens it to a roughly 5 km grid before storing it, so there is
  no exact one to show. An Activity's meeting point is exact and is public (§5.4), so the reports and
  held-content screens may show it.
