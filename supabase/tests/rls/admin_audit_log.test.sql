begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111');
insert into profiles (id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'anand');
insert into admin_audit_log (actor, staff_id, action, subject_type, subject_id, reason) values
  ('staff', '11111111-1111-1111-1111-111111111111', 'set_content_status',
   'act', '99999999-9999-9999-9999-999999999999', 'removed for unsafe content');

select ok(
  not has_table_privilege('authenticated', 'admin_audit_log',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('authenticated', 'admin_audit_log',
    'SELECT, INSERT, UPDATE, REFERENCES'),
  'the audit log is written and read only inside definer functions'
);

select ok(
  not has_table_privilege('service_role', 'admin_audit_log',
    'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
  and not has_any_column_privilege('service_role', 'admin_audit_log',
    'SELECT, INSERT, UPDATE, REFERENCES')
  and not has_sequence_privilege('service_role', 'admin_audit_log_id_seq',
    'USAGE, SELECT, UPDATE'),
  'no role holds the table or its identity sequence, so nothing can forge or renumber a row'
);

select is_empty(
  $$ select conname from pg_constraint
     where conrelid = 'public.admin_audit_log'::regclass and contype = 'f' $$,
  'the audit log has no foreign keys, so its rows never change when anything else is deleted'
);

select throws_ok(
  $$ insert into admin_audit_log (actor, action, subject_type, subject_id, reason)
     values ('staff', 'x', 'act', '99999999-9999-9999-9999-999999999999', 'no staff id') $$,
  '23514',
  null,
  'a staff action must name the staff member'
);

select throws_ok(
  $$ insert into admin_audit_log (actor, staff_id, action, subject_type, subject_id, reason)
     values ('system', '11111111-1111-1111-1111-111111111111', 'auto_hold',
             'act', '99999999-9999-9999-9999-999999999999', 'threshold reached') $$,
  '23514',
  null,
  'a system action must not name one'
);

select lives_ok(
  $$ delete from profiles where id = '11111111-1111-1111-1111-111111111111' $$,
  'the staff member is deleted'
);

select results_eq(
  $$ select count(*)::int from admin_audit_log $$,
  $$ values (1) $$,
  'and the audit row is untouched, because the log has no foreign keys'
);

select is_empty(
  $$ select policyname from pg_policies
     where schemaname = 'public' and tablename = 'admin_audit_log' $$,
  'admin_audit_log carries no policy, because no client can reach it to be policed'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.admin_audit_log'::regclass),
  'row level security is on regardless, so a later grant cannot open the table by itself'
);

select * from finish();
rollback;
