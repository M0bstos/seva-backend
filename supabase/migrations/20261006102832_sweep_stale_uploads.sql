-- §8.1's last sentence about the upload flow: "Uploads still sitting in `uploading` after 24
-- hours are deleted by the operations worker." That is a signed URL the app never used, or an
-- upload that completed in Storage and never reached `POST /uploads/:id/complete` — §17.1
-- records that a failed Storage check on that route deliberately leaves the row here rather
-- than parking it in `processing` where §12.5's stuck arm would fire.
--
-- **`security definer`, and it has to be: nobody holds `delete` on `media` at all.** §5.2 grants
-- `select`, `insert` and `update` and no more, which is what makes every deletion arrive by
-- cascade — the property `queue_media_deletion`'s own header measures and depends on. A sweep
-- is the one deletion that is not a cascade, so it needs a frame that owns the table.
--
-- §9.1's requirements hold: it lives in `public` so gate 4 sees the pinned `search_path`, every
-- name is schema-qualified, there is no dynamic SQL, and its first line is the only permission
-- check it can have — the predicate itself, which is narrow enough that the worst a stolen
-- secret key can do through it is delete rows §8.1 has already given up on. It takes no
-- arguments for that reason: there is nothing for a caller to widen.
--
-- The files go through §5.4's trigger rather than through this function: deleting the row fires
-- `queue_media_deletion`, which queues the `ops` job the worker drains — and which skips a path
-- §11.6 is retaining, so a sweep cannot destroy a file a retention row names.
create function sweep_stale_uploads() returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_swept int;
begin
  with gone as (
    delete from public.media
    where status = 'uploading'
      and created_at < now() - interval '24 hours'
    returning 1
  )
  select count(*) into v_swept from gone;

  return jsonb_build_object('swept', v_swept);
end;
$$;

revoke execute on function sweep_stale_uploads()
  from public, anon, authenticated, service_role;
grant execute on function sweep_stale_uploads() to service_role;
