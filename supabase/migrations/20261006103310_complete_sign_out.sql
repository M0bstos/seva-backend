-- §10.2's second half of a suspension: `admin_suspend_user` "queues a sign-out through the
-- operations worker". §12.4 is why it is needed at all — "access tokens last an hour" and nothing
-- in Auth reads `profiles.status`, so §17 `O33`'s write refusal alone would leave a suspended
-- person's existing session working until it expired.
--
-- **Measured, 6 October 2026, because the obvious route does not exist.** GoTrue exposes no admin
-- endpoint for revoking another person's sessions: `POST` and `DELETE` on both
-- `/auth/v1/admin/users/{id}/logout` and `/auth/v1/admin/users/{id}/sessions` answer 404, and
-- `supabase.auth.admin.signOut` takes the *user's own* access token, which a worker does not have.
-- What does work is deleting the person's rows from `auth.sessions`: measured, `postgres` holds
-- `DELETE` there, and after the delete a refresh with the issued token answers 400. So the
-- sign-out is SQL rather than an API call, which is also why it is a `security definer` function
-- owned by `postgres` — no other role may touch that table.
--
-- §9.1's requirements hold: in `public` so gate 4 sees the pinned `search_path`, every name
-- schema-qualified, no dynamic SQL. The body mentions the `auth` schema and deliberately nothing
-- else about it: `auth.sessions` carries no phone, email, password or token column, so the
-- definer-body lint in `tests/security/auth_users_grant.test.sql` stays green and its one
-- exception stays at one. `auth.refresh_tokens` is not touched — the measurement shows the session
-- delete is enough, and naming that table would trip the lint for no gain.
--
-- **The capability is bound to the job rather than granted outright.** It takes a `msg_id` and not
-- a user id, and refuses one that is not a live `sign_out` job — so a secret-key holder can only
-- sign out somebody a staff suspension actually queued, instead of anybody at all. §8.4's
-- `vt > now()` window is what makes that id a capability rather than an integer (§17.1).
create function complete_sign_out(p_msg_id bigint) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_message jsonb;
  v_user_id uuid;
  v_revoked int;
begin
  select q.message into v_message
  from pgmq.q_ops q
  where q.msg_id = p_msg_id and q.vt > now();
  if not found then
    return jsonb_build_object('error', 'NOT_FOUND');
  end if;
  if v_message ->> 'kind' <> 'sign_out' then
    return jsonb_build_object('error', 'VALIDATION_FAILED', 'field', 'msg_id');
  end if;

  v_user_id := (v_message ->> 'user_id')::uuid;

  with revoked as (
    delete from auth.sessions where user_id = v_user_id returning 1
  )
  select count(*) into v_revoked from revoked;

  perform pgmq.delete('ops', p_msg_id);
  -- A count, not a session id. §9.8 identifies people by user id alone, and the worker logs
  -- neither — this is what it reports as work done.
  return jsonb_build_object('revoked', v_revoked);
end;
$$;

revoke execute on function complete_sign_out(bigint)
  from public, anon, authenticated, service_role;
grant execute on function complete_sign_out(bigint) to service_role;
