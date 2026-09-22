-- §5.1: supautils pins pg_cron to pg_catalog and brings its own cron schema, so
-- `with schema` is ignored here. Gate 8 keeps clients out of that schema.
create extension pg_cron;
