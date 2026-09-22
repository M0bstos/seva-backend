create extension pgmq;

select pgmq.create('moderation');
select pgmq.create('email');
select pgmq.create('ops');

-- §5.1: pgmq grants to PUBLIC on the way in, and revoking from PUBLIC also strips
-- service_role, so the two grants back are required rather than optional.
revoke usage on schema pgmq from public;
revoke execute on all functions in schema pgmq from public;
grant usage on schema pgmq to service_role;
grant execute on all functions in schema pgmq to service_role;

-- The block in §5.1 stops at the functions, but pgmq's own functions are security
-- invoker, so they touch the queue tables as the caller. Without these the workers
-- get `permission denied for table q_ops` on the first send.
grant select on table pgmq.meta to service_role;
grant select, insert, update, delete on table
  pgmq.q_moderation, pgmq.q_email, pgmq.q_ops
  to service_role;
-- Archives are written once and read by the §8.4 alarm. Nothing updates or deletes
-- one, and granting that would be the ability §8.4 says the design does not have.
grant select, insert on table
  pgmq.a_moderation, pgmq.a_email, pgmq.a_ops
  to service_role;
-- `select` here is what pgmq.metrics() reads last_value through; rewinding a message
-- id needs `update`, which is withheld, so the read costs nothing.
grant usage, select on sequence
  pgmq.q_moderation_msg_id_seq, pgmq.q_email_msg_id_seq, pgmq.q_ops_msg_id_seq
  to service_role;
