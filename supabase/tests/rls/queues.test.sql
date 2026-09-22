begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

select ok(
  not has_schema_privilege('anon', 'pgmq', 'usage')
  and not has_schema_privilege('authenticated', 'pgmq', 'usage')
  and has_schema_privilege('service_role', 'pgmq', 'usage'),
  'the queue schema is reachable by the workers and by no client'
);

select is_empty(
  $$ select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'pgmq'
       and (has_function_privilege('anon', p.oid, 'execute')
         or has_function_privilege('authenticated', p.oid, 'execute')) $$,
  'no client can execute a queue function, which the revoke of the PUBLIC grant buys'
);

select ok(
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'pgmq' and has_function_privilege('service_role', p.oid, 'execute')) = 40,
  'while the workers keep every one of them'
);

select is_empty(
  $$ select a.name from (values ('pgmq.a_moderation'), ('pgmq.a_email'),
                               ('pgmq.a_ops')) as a (name)
     where has_table_privilege('service_role', a.name, 'UPDATE, DELETE, TRUNCATE') $$,
  'an archived job cannot be altered or dropped, so nothing is silently lost'
);

select is_empty(
  $$ select s.name from (values ('pgmq.q_moderation_msg_id_seq'),
                               ('pgmq.q_email_msg_id_seq'),
                               ('pgmq.q_ops_msg_id_seq')) as s (name)
     where has_sequence_privilege('service_role', s.name, 'UPDATE') $$,
  'and message ids cannot be rewound'
);

set local role service_role;

select lives_ok(
  $$ select pgmq.send('ops', '{"job":"purge"}'::jsonb);
     select pgmq.read('ops', 30, 1);
     select pgmq.archive('ops', 1);
     select pgmq.list_queues();
     select pgmq.metrics('ops') $$,
  'a worker can send, read and archive a job, and read the metrics 12.5 alarms on'
);

reset role;
select * from finish();
rollback;
