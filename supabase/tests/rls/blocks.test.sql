begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222'),
  ('33333333-3333-3333-3333-333333333333');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'anand'),
  ('22222222-2222-2222-2222-222222222222', 'bina'),
  ('33333333-3333-3333-3333-333333333333', 'chandra');
insert into blocks (blocker_id, blocked_id) values
  ('22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333');

select ok(
  has_table_privilege('authenticated', 'blocks', 'SELECT, INSERT, DELETE')
  and not has_table_privilege('authenticated', 'blocks',
    'UPDATE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'blocks', 'UPDATE, REFERENCES'),
  'authenticated adds and removes its own blocks and never updates one'
);

select ok(
  has_table_privilege('service_role', 'blocks', 'SELECT')
  and not has_table_privilege('service_role', 'blocks',
    'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('service_role', 'blocks', 'INSERT, UPDATE, REFERENCES'),
  'feed and discover read blocks to filter, and never write them'
);

select throws_ok(
  $$ insert into blocks (blocker_id, blocked_id)
     values ('11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111') $$,
  '23514',
  null,
  'nobody blocks themselves'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select lives_ok(
  $$ insert into blocks (blocker_id, blocked_id)
     values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222') $$,
  'a signed-in user blocks someone'
);

select results_eq(
  $$ select blocked_id from blocks $$,
  $$ values ('22222222-2222-2222-2222-222222222222'::uuid) $$,
  'and reads only their own blocks, never who blocked whom elsewhere'
);

select throws_ok(
  $$ insert into blocks (blocker_id, blocked_id)
     values ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111') $$,
  '42501',
  null,
  'nobody forges a block on behalf of someone else'
);

select lives_ok(
  $$ delete from blocks
     where blocker_id = '11111111-1111-1111-1111-111111111111' $$,
  'a signed-in user removes their own block'
);

reset role;

select results_eq(
  $$ select count(*)::int from blocks $$,
  $$ values (1) $$,
  'the other block survived, so the delete policy scoped to its owner'
);

select lives_ok(
  $$ delete from profiles where id = '33333333-3333-3333-3333-333333333333' $$,
  'a blocked profile can be deleted'
);

select is_empty(
  $$ select 1 from blocks $$,
  'and the block cascades away with it'
);

select * from finish();
rollback;
