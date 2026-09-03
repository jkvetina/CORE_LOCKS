--
-- Install CORE_LOCKS and its test suites into the current schema, then prove the
-- install rather than assume it.
--
-- Run it FROM THE REPOSITORY ROOT, because the @ paths below are repo-relative and
-- SQL*Plus resolves @@ against the calling script's folder only for a bare file
-- name and will not follow a subdirectory or a ../ out of it:
--
--     cd <repo>
--     sqlplus core_locks/core_locks@<host>:<port>/<service> @database/tests/install.sql
--
-- The two scheduler jobs are deliberately NOT installed here.
-- CORE_LOCKSMITH_ENABLE re-enables the trigger every five minutes, and the unit
-- suite switches the trigger off while it compiles its probes, so the job would
-- switch it back on mid-run and the suite would be testing something else.
-- CORE_LOCKS_PURGE is daily housekeeping; purge_locks is called directly by the
-- tests that cover it.
--
set define off
set serveroutput on size unlimited
set verify off feed off
whenever sqlerror exit failure

PROMPT
PROMPT ===== product objects
@database/tables/core_locks.sql
@database/packages/core_lock.spec.sql
@database/packages/core_lock.sql
@database/triggers/core_locksmith.sql

PROMPT
PROMPT ===== test fixture and suites
@database/tests/core_lock_fixture.spec.sql
@database/tests/core_lock_fixture.sql
@database/tests/core_lock_ut.spec.sql
@database/tests/core_lock_ut.sql
@database/tests/core_locksmith_ut.spec.sql
@database/tests/core_locksmith_ut.sql
@database/tests/core_lock_conc_ut.spec.sql
@database/tests/core_lock_conc_ut.sql
@database/tests/core_lock_proxy_ut.spec.sql
@database/tests/core_lock_proxy_ut.sql

PROMPT
PROMPT ===== the locksmith starts enabled, whatever a half-finished run left behind
ALTER TRIGGER core_locksmith ENABLE;

PROMPT
PROMPT ===== rebuild the annotation cache
BEGIN
    ut_runner.rebuild_annotation_cache(USER);
END;
/

PROMPT
PROMPT ===== prove the install
DECLARE
    v_invalid           PLS_INTEGER;
    v_suites            PLS_INTEGER;
    v_names             VARCHAR2(4000);
BEGIN
    -- an INVALID test package and an undiscovered one are different faults and
    -- both are silent: the run simply reports fewer tests and reads as a pass
    SELECT COUNT(*), LISTAGG(t.object_name || ' ' || t.object_type, ', ')
    INTO v_invalid, v_names
    FROM user_objects t
    WHERE t.object_name LIKE 'CORE\_LOCK%' ESCAPE '\'
        AND t.status != 'VALID';
    --
    IF v_invalid > 0 THEN
        RAISE_APPLICATION_ERROR(-20997, 'INSTALL: ' || v_invalid || ' invalid object(s): ' || v_names);
    END IF;
    --
    SELECT COUNT(*)
    INTO v_suites
    FROM TABLE(ut_runner.get_suites_info(USER));
    --
    IF v_suites = 0 THEN
        RAISE_APPLICATION_ERROR(-20997, 'INSTALL: no suite was discovered - the annotation cache is empty.');
    END IF;
    --
    DBMS_OUTPUT.PUT_LINE('INSTALL OK: 0 invalid objects, ' || v_suites || ' discovered suite item(s).');
END;
/

PROMPT
PROMPT Installed. Run the suites with:
PROMPT     sqlplus core_locks/core_locks@<host>:<port>/<service> @database/tests/run.sql
PROMPT
PROMPT The proxy suite is tagged out of that run and needs a proxy connection:
PROMPT     sqlplus CLUT_PROXY[CORE_LOCKS]/clut_proxy@<host>:<port>/<service> @database/tests/run_proxy.sql
PROMPT     (run.sh does both)
PROMPT

EXIT;
