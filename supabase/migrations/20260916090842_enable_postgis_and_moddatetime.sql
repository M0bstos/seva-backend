-- §5.1: PostGIS lives in the extensions schema, so locations are
-- extensions.geography(point, 4326) and definer functions schema-qualify every call.
create extension if not exists postgis with schema extensions;

-- §5.1: keeps updated_at current on editable tables.
create extension if not exists moddatetime with schema extensions;
