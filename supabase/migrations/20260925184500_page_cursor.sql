-- §7.1 pages an Edge Function route with "an opaque `cursor`, `limit` ≤ 50", so the
-- three list routes — `GET /discover`, `GET /discover/campaigns` and `GET /feed`
-- (§7.3) — all hand out a cursor standing for the last row they returned. Every one
-- of them sorts on a timestamp and the primary key, so one pair of functions serves
-- all three: a third copy of the format is the point at which it stops being local
-- detail and becomes something the encoder and the decoder have to agree on.
--
-- Rendered in UTC with an explicit format rather than through `::text`, because the
-- same row must always produce the same cursor: the cursor is part of §7.3's cache
-- key, and a session with a different `TimeZone` or `DateStyle` would otherwise write
-- a second entry for the same page.
--
-- `translate` does two things to the base64, both for the same reason — the cursor
-- travels in a query string (§7.1) and comes back as the cache key. Postgres wraps
-- `encode` at 76 characters, so every cursor this format produces carries a newline
-- at position 77; `decode` ignores it, so the page would still resolve, but a client
-- or proxy that strips it hands back text that keys a second cache entry for the same
-- page — measured. And `+` and `/` are the two base64 characters a query string does
-- not carry safely: `+` reads back as a space. Neither appeared in 5,000 sampled
-- cursors, because this format's bytes and its fixed length pin the sextet alignment,
-- but that is a property of the format rather than a guarantee, and it would go
-- unnoticed if the format ever changed. The padding `=` stays: a query value may
-- carry it, and `decode` refuses base64 without it.
--
-- `private`, not `public`: nothing a client calls, and §5.1 keeps the schema out of
-- the Data API. `stable` and not `immutable` — `to_char` over a timestamp reads
-- `lc_time`.
create function private.encode_cursor(p_at timestamptz, p_id uuid) returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select translate(
    encode(
      convert_to(
        to_char(p_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') || '|' || p_id::text,
        'utf8'
      ),
      'base64'
    ),
    E'+/\n', '-_'
  );
$$;

-- Returns both values or neither, so a caller tests one of them and answers §7.4's
-- VALIDATION_FAILED. Nothing is raised: a cursor is caller text, and letting a cast
-- fail would answer a permanently malformed cursor with a retryable INTERNAL and
-- carry that text into the log through the error DETAIL (§9.8).
create function private.decode_cursor(
  p_cursor text, out cursor_at timestamptz, out cursor_id uuid
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_parts text[];
begin
  v_parts := string_to_array(
    convert_from(decode(translate(p_cursor, '-_', '+/'), 'base64'), 'utf8'), '|'
  );
  if array_length(v_parts, 1) is distinct from 2 then
    return;
  end if;
  cursor_at := v_parts[1]::timestamp at time zone 'UTC';
  cursor_id := v_parts[2]::uuid;
exception when invalid_parameter_value or character_not_in_repertoire
  or invalid_datetime_format or datetime_field_overflow
  or invalid_text_representation then
  cursor_at := null;
  cursor_id := null;
end;
$$;

-- §9.1: revoking from the two client roles alone leaves what PUBLIC granted, and
-- revoking from PUBLIC also strips service_role, which the route functions run as.
revoke execute on function private.encode_cursor(timestamptz, uuid)
  from public, anon, authenticated, service_role;
grant execute on function private.encode_cursor(timestamptz, uuid) to service_role;

revoke execute on function private.decode_cursor(text)
  from public, anon, authenticated, service_role;
grant execute on function private.decode_cursor(text) to service_role;
