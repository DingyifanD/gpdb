-- Test scenarios covering crash recovery for some specific DTM point.
--
-- start_matchsubs
--
-- # create a match/subs expression
--
-- s/\s+\(.*\.[ch]:\d+\)/ (SOMEFILE:SOMEFUNC)/
-- m/(PANIC):.*unable to complete*/
--
-- m/^DETAIL:.*gid=.*/
-- s/gid=\d+-\d+/gid DUMMY/
--
-- m/^ERROR:  Error on receive from seg0.*: server closed the connection unexpectedly/
-- s/^ERROR:  Error on receive from seg0.*: server closed the connection unexpectedly/ERROR: server closed the connection unexpectedly/
--
-- end_matchsubs

include: helpers/server_helpers.sql;

-- Make the test faster and also make some queries fail as expected after
-- 2pc retry PANIC (do not finish earlier before PANIC happens).
alter system set dtx_phase2_retry_second to 5;
select pg_reload_conf();

-- This function is used to loop until master shutsdown, to make sure
-- next command executed is only after restart and doesn't go through
-- while PANIC is still being processed by master, as master continues
-- to accept connections for a while despite undergoing PANIC.
CREATE OR REPLACE FUNCTION wait_till_master_shutsdown()
RETURNS void AS
$$
  DECLARE
    i int; /* in func */
  BEGIN
    i := 0; /* in func */
    while i < 120 loop
      i := i + 1; /* in func */
      PERFORM pg_sleep(.5); /* in func */
    end loop; /* in func */
  END; /* in func */
$$ LANGUAGE plpgsql;

1:SELECT role, preferred_role, content, mode, status FROM gp_segment_configuration;
-- Scenario 1: Test to fail broadcasting of COMMIT PREPARED to one
-- segment and hence trigger PANIC in master while after completing
-- phase 2 of 2PC. Master's recovery cycle should correctly broadcast
-- COMMIT PREPARED again because master should find distributed commit
-- record in its xlog during recovery. Verify that the transaction is
-- committed after recovery. This scenario used to create cluster
-- inconsistency due to bug fixed now, as transaction used to get
-- committed on all segments except one where COMMIT PREPARED
-- broadcast failed before recovery. Master used to miss sending the
-- COMMIT PREPARED across restart and instead abort the transaction
-- after querying in-doubt prepared transactions from segments.
-- Inject fault to fail the COMMIT PREPARED always on one segment, till fault is not reset
1: SELECT gp_inject_fault_infinite('finish_prepared_start_of_function', 'error', dbid)
   from gp_segment_configuration where content=0 and role='p';
-- Start looping in background, till master panics and closes the session
3&: SELECT wait_till_master_shutsdown();
-- Start transaction which should hit PANIC as COMMIT PREPARED will fail to one segment
1: CREATE TABLE commit_phase1_panic(a int, b int);
-- Reset the fault in utility mode because normal mode connection will
-- not be accepted until DTX recovery is finished.
-1U: SELECT gp_inject_fault('finish_prepared_start_of_function', 'reset', dbid)
     from gp_segment_configuration where content=0 and role='p';
-1Uq:
-- Join back to know master has completed postmaster reset.
3<:
-- Start a session on master which would complete the DTM recovery and hence COMMIT PREPARED
4: SELECT * from commit_phase1_panic;
4: INSERT INTO commit_phase1_panic select i,i from generate_series(1, 10)i;
4: SELECT count(*) from commit_phase1_panic;

-- Scenario 2: Inject FATAL on master after recording commit but
-- before broadcasting COMMIT_PREPARED to segments. FATAL must convert
-- to PANIC and make sure to complete the 2PC processing and not leave
-- dangling prepared transaction. There used to bug as a result the
-- master backend process would just die, leaving dangling prepared
-- transaction on segment but commited on master.

-- Start looping in background, till master panics and closes the
-- session
5&: SELECT wait_till_master_shutsdown();
6: SELECT gp_inject_fault('dtm_broadcast_commit_prepared', 'fatal', dbid)
   from gp_segment_configuration where role='p' and content=-1;
6: CREATE TABLE commit_fatal_fault_test_table(a int, b int);
5<:
-- Start a session on master which would complete the DTM recovery and hence COMMIT PREPARED
7: SELECT count(*) from commit_fatal_fault_test_table;
7: SELECT * FROM gp_dist_random('pg_prepared_xacts');
7: SELECT gp_inject_fault('dtm_broadcast_commit_prepared', 'reset', dbid)
   from gp_segment_configuration where role='p' and content=-1;

-- Scenario 3: Inject ERROR after prepare phase has completed to
-- trigger abort. Then on abort inject FATAL on master before sending
-- ABORT_PREPARED. FATAL must convert to PANIC and make sure to
-- complete the 2PC processing and not leave dangling prepared
-- transaction. There used to bug as a result the master backend
-- process would just die, leaving dangling prepared transaction on
-- segment but aborted on master.

-- Start looping in background, till master panics and closes the
-- session
8&: SELECT wait_till_master_shutsdown();
9: SELECT gp_inject_fault('transaction_abort_after_distributed_prepared', 'error', dbid)
   from gp_segment_configuration where role='p' and content=-1;
9: SELECT gp_inject_fault('dtm_broadcast_abort_prepared', 'fatal', dbid)
   from gp_segment_configuration where role='p' and content=-1;
9: CREATE TABLE abort_fatal_fault_test_table(a int, b int);
8<:
10: SELECT count(*) from abort_fatal_fault_test_table;
10: SELECT * FROM gp_dist_random('pg_prepared_xacts');
10: SELECT gp_inject_fault('transaction_abort_after_distributed_prepared', 'reset', dbid)
    from gp_segment_configuration where role='p' and content=-1;
10: SELECT gp_inject_fault('dtm_broadcast_abort_prepared', 'reset', dbid)
    from gp_segment_configuration where role='p' and content=-1;

-- Scenario 4: QE panics after writing prepare xlog record. This
-- should cause master to broadcast abort and QEs handle the abort in
-- DTX_CONTEXT_LOCAL_ONLY context.
11: CREATE TABLE QE_panic_test_table(a int, b int);
11: INSERT INTO QE_panic_test_table SELECT * from generate_series(0, 9);
-- To help speedy recovery
11: CHECKPOINT;
-- Increase 2PC retry timeout to avoid any failures. Alter
-- system is required to set the GUC and can't be set on session level
-- as session reset happens for every abort retry.
11: alter system set dtx_phase2_retry_second to 600;
11: select pg_reload_conf();
-- skip FTS probes always
11: SELECT gp_inject_fault_infinite('fts_probe', 'skip', dbid)
    from gp_segment_configuration where role='p' and content=-1;
11: SELECT gp_request_fts_probe_scan();
11: select gp_wait_until_triggered_fault('fts_probe', 1, dbid)
    from gp_segment_configuration where role='p' and content=-1;
11: SELECT gp_inject_fault('end_prepare_two_phase', 'infinite_loop', dbid)
    from gp_segment_configuration where role='p' and content=0;
-- statement to trigger fault after writing prepare record
12&: DELETE FROM QE_panic_test_table;
11: SELECT gp_wait_until_triggered_fault('end_prepare_two_phase', 1, dbid)
    from gp_segment_configuration where role='p' and content=0;
11: SELECT pg_ctl(datadir, 'restart') from gp_segment_configuration where role = 'p' and content = 0;
12<:
13: SELECT count(*) from QE_panic_test_table;
13: SELECT * FROM gp_dist_random('pg_prepared_xacts');
13: SELECT gp_inject_fault('fts_probe', 'reset', dbid)
    from gp_segment_configuration where role='p' and content=-1;
13: alter system reset dtx_phase2_retry_second;
13: select pg_reload_conf();

14: alter system reset dtx_phase2_retry_second;
14: select pg_reload_conf();

-- Scenario 5: QD panics when a QE process is doing prepare but not yet finished.
-- This should cause dtx recovery finally aborts the orphaned prepared transaction.
15: CREATE TABLE master_reset(a int);
15: SELECT gp_inject_fault_infinite('before_xlog_xact_prepare', 'suspend', dbid)
   from gp_segment_configuration where role = 'p' and content = 1;
15: SELECT gp_inject_fault_infinite('after_xlog_xact_prepare_flushed', 'skip', dbid)
   from gp_segment_configuration where role = 'p' and content = 1;
16&: INSERT INTO master_reset SELECT a from generate_series(1, 10) a;
15: SELECT gp_wait_until_triggered_fault('before_xlog_xact_prepare', 1, dbid)
   from gp_segment_configuration where role = 'p' and content = 1;

-- set gucs to speed up testing
15: ALTER SYSTEM SET gp_dtx_recovery_prepared_period to 0;
15: ALTER SYSTEM SET gp_dtx_recovery_interval to 5;
15: SELECT pg_reload_conf();

-- trigger master panic and wait until master down before running any new query.
17&: SELECT wait_till_master_shutsdown();
18: SELECT gp_inject_fault('before_read_command', 'panic', 1);
18: SELECT 1;
16<:
17<:

-- wait until master is up for querying.
19: SELECT 1;

-- master suspends before running periodical checking of orphaned prepared transactions.
19: SELECT gp_inject_fault_infinite('before_orphaned_check', 'suspend', dbid)
   from gp_segment_configuration where role = 'p' and content = -1;
19: SELECT gp_wait_until_triggered_fault('before_orphaned_check', 1, dbid)
   from gp_segment_configuration where role = 'p' and content = -1;

-- let prepare finish else dtx recovery can not abort the prepared transaction.
19: SELECT gp_inject_fault_infinite('before_xlog_xact_prepare', 'reset', dbid)
   from gp_segment_configuration where role = 'p' and content = 1;
19: SELECT gp_wait_until_triggered_fault('after_xlog_xact_prepare_flushed', 1, dbid)
   from gp_segment_configuration where role = 'p' and content = 1;
19: SELECT gp_inject_fault_infinite('after_xlog_xact_prepare_flushed', 'reset', dbid)
   from gp_segment_configuration where role = 'p' and content = 1;

-- should exist an orphaned prepared transaction.
1U: SELECT count(*) from pg_prepared_xacts;

-- if there is orphaned prepared transaction, drop would hang since
-- the orphaned prepared transaction holds lock of the table that conflicts
-- with required lock of the drop operation.
19: SELECT gp_inject_fault_infinite('before_orphaned_check', 'reset', dbid)
   from gp_segment_configuration where role = 'p' and content = -1;
19: DROP TABLE master_reset;
19: ALTER SYSTEM RESET gp_dtx_recovery_interval;
19: ALTER SYSTEM RESET gp_dtx_recovery_prepared_period;
19: SELECT pg_reload_conf();

-- ensure the orphaned prepared transaction is gone.
1U: SELECT * from pg_prepared_xacts;
