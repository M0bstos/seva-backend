begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id) values ('b1000000-0000-4000-8000-000000000001');
insert into profiles (id, display_name)
values ('b1000000-0000-4000-8000-000000000001', 'Label owner');
insert into media (id, owner_id, purpose, upload_path, status)
values ('b1000000-0000-4000-8000-0000000000aa',
        'b1000000-0000-4000-8000-000000000001', 'act',
        'uploads/b1000000-0000-4000-8000-000000000001/aa.jpg', 'ready');

-- §17 `O21`: the screening verdict is private. These are the denials that make that
-- true, and they are exhaustive rather than a spot check, because `grant all` is
-- eight privileges and a column grant is invisible to `has_table_privilege`.
select ok(
  not has_table_privilege('authenticated', 'media_labels',
    'select, insert, update, delete, truncate, references, trigger, maintain')
  and not has_any_column_privilege('authenticated', 'media_labels',
    'select, insert, update, references'),
  'a signed-in person cannot read the screening verdict on anyone''s photo'
);

select ok(
  not has_table_privilege('anon', 'media_labels',
    'select, insert, update, delete, truncate, references, trigger, maintain')
  and not has_any_column_privilege('anon', 'media_labels',
    'select, insert, update, references'),
  'and neither can a logged-out caller, which gate 2 also checks'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'media_labels'::regclass),
  'RLS is on, as §9.7 gate 1 requires of every table in public'
);

select is(
  (select count(*)::int from pg_policies
   where schemaname = 'public' and tablename = 'media_labels'),
  0,
  'and it ships no policy: every role that can hold anything here bypasses RLS'
);

-- The worker's flow, run as the role its secret key resolves to.
set local role service_role;

select lives_ok(
  $$insert into media_labels (media_id, labels)
    values ('b1000000-0000-4000-8000-0000000000aa', '{"Alcohol": 62}'::jsonb)$$,
  'the moderation worker can record a verdict'
);

-- §8.4 redelivers a job whose worker died after the write, so the second delivery
-- has to land on its feet rather than raise a unique violation. This is the assertion
-- that found the `select` grant: Postgres requires it for `on conflict do update`,
-- and without it the worker would have failed in production, not here.
select lives_ok(
  $$insert into media_labels (media_id, labels)
    values ('b1000000-0000-4000-8000-0000000000aa', '{"Alcohol": 71}'::jsonb)
    on conflict (media_id) do update set labels = excluded.labels$$,
  'and a redelivered job overwrites its own row rather than failing'
);

-- Exhaustive in both dimensions for the one role that holds anything here, because
-- this table bypasses RLS for every such role: `grant all` is eight privileges, and a
-- column grant is invisible to `has_table_privilege`. `REFERENCES` is the column
-- half, being the one column-grantable privilege no flow needs.
select ok(
  not has_table_privilege('service_role', 'media_labels',
    'delete, truncate, references, trigger, maintain')
  and not has_any_column_privilege('service_role', 'media_labels', 'REFERENCES'),
  'the worker holds nothing beyond the three its upsert needs, table or column'
);

reset role;

select is(
  (select labels ->> 'Alcohol' from media_labels
   where media_id = 'b1000000-0000-4000-8000-0000000000aa'),
  '71',
  'the upsert replaced the verdict rather than keeping the first'
);

select * from finish();
rollback;
