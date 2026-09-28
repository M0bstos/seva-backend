begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

select ok(
  not has_function_privilege('anon', 'private.encode_cursor(timestamptz,uuid)', 'execute')
  and not has_function_privilege('authenticated',
        'private.encode_cursor(timestamptz,uuid)', 'execute')
  and not has_function_privilege('anon', 'private.decode_cursor(text)', 'execute')
  and not has_function_privilege('authenticated', 'private.decode_cursor(text)', 'execute'),
  'no client role reaches the cursor functions (§9.1)'
);

select ok(
  has_function_privilege('service_role', 'private.encode_cursor(timestamptz,uuid)', 'execute')
  and has_function_privilege('service_role', 'private.decode_cursor(text)', 'execute'),
  'the route functions reach them on their secret key (§5.1)'
);

set local role service_role;

select is(
  (select c.cursor_at from private.decode_cursor(
     private.encode_cursor('2026-10-21T07:00:00+05:30'::timestamptz,
       '11111111-1111-1111-1111-111111111111')) c),
  '2026-10-21T07:00:00+05:30'::timestamptz,
  'a cursor round-trips the instant it was made from'
);

select is(
  (select c.cursor_id from private.decode_cursor(
     private.encode_cursor('2026-10-21T07:00:00+05:30'::timestamptz,
       '11111111-1111-1111-1111-111111111111')) c),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'and the row it pointed at'
);

-- Microseconds survive, or two rows inside one second would page onto each other.
select is(
  (select c.cursor_at from private.decode_cursor(
     private.encode_cursor('2026-10-21 01:30:00.123456+00'::timestamptz,
       '11111111-1111-1111-1111-111111111111')) c),
  '2026-10-21 01:30:00.123456+00'::timestamptz,
  'to the microsecond'
);

select ok(
  (select c.cursor_at is null and c.cursor_id is null
   from private.decode_cursor('not a cursor') c),
  'a cursor that is not base64 decodes to nothing rather than raising (§7.4)'
);

select ok(
  (select c.cursor_at is null and c.cursor_id is null
   from private.decode_cursor(encode(convert_to('one part', 'utf8'), 'base64')) c),
  'so does one with the wrong number of parts'
);

select ok(
  (select c.cursor_at is null and c.cursor_id is null
   from private.decode_cursor(
     encode(convert_to('2026-10-21 01:30:00|not-a-uuid', 'utf8'), 'base64')) c),
  'and one whose halves do not cast'
);

-- The same row must always give the same cursor: §7.3 puts it in the cache key, so a
-- session reading in IST and one reading in UTC must not write two entries for one
-- page. Each half sets its own timezone before encoding the same instant.
select is(
  (select private.encode_cursor('2026-10-21T07:00:00+05:30'::timestamptz,
     '11111111-1111-1111-1111-111111111111')
   from (select set_config('timezone', 'Asia/Kolkata', true)) s),
  (select private.encode_cursor('2026-10-21T01:30:00+00'::timestamptz,
     '11111111-1111-1111-1111-111111111111')
   from (select set_config('timezone', 'UTC', true)) s),
  'the session timezone does not change the cursor (§7.3)'
);

select * from finish();
rollback;
