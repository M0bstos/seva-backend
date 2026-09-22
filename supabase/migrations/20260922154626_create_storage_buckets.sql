-- §8.1 puts the type and size check on the uploads bucket itself. The worker still
-- checks the bytes, and the 2048 px rule is not bucket-enforceable. The other three
-- carry no restriction: the spec sets none, and an allow-list on quarantine could
-- block the §11.6 takedown move, which runs against a legal clock.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('uploads', 'uploads', false, 5242880, array['image/jpeg']),
  ('media', 'media', true, null, null),
  ('quarantine', 'quarantine', false, null, null),
  ('exports', 'exports', false, null, null);
