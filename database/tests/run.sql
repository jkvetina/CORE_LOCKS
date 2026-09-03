--
-- Run the CORE_LOCKS suites and fail the session when they are not green.
--
--     sqlplus core_locks/core_locks@<host>:<port>/<service> @database/tests/run.sql
--
-- utPLSQL reports failures and returns normally, so `whenever sqlerror` sees a
-- clean run and exits 0 with a suite full of red. This block reads the reporter's
-- own summary line and raises on the three ways a run can lie:
--
--   failed or errored above zero   the obvious one
--   no summary line at all         the run never finished
--   a summary reporting 0 tests    a test package stopped compiling, so it
--                                  stopped being discovered, and an empty green
--                                  run is exactly what that looks like
--
set serveroutput on size unlimited
set lines 200 pages 0 feed off verify off
whenever sqlerror exit failure

DECLARE
    c_summary_pattern   CONSTANT VARCHAR2(200) := '^(\d+) tests?, (\d+) failed, (\d+) errored';
    --
    v_summary           VARCHAR2(4000);
    v_tests             PLS_INTEGER;
    v_failed            PLS_INTEGER;
    v_errored           PLS_INTEGER;
BEGIN
    FOR c IN (
        SELECT column_value AS line
        FROM TABLE(ut.run())
    ) LOOP
        DBMS_OUTPUT.PUT_LINE(c.line);
        --
        IF REGEXP_LIKE(c.line, c_summary_pattern) THEN
            v_summary := c.line;
        END IF;
    END LOOP;
    --
    IF v_summary IS NULL THEN
        RAISE_APPLICATION_ERROR(-20998, 'UT3: no summary line - the run did not complete.');
    END IF;
    --
    v_tests     := TO_NUMBER(REGEXP_SUBSTR(v_summary, c_summary_pattern, 1, 1, NULL, 1));
    v_failed    := TO_NUMBER(REGEXP_SUBSTR(v_summary, c_summary_pattern, 1, 1, NULL, 2));
    v_errored   := TO_NUMBER(REGEXP_SUBSTR(v_summary, c_summary_pattern, 1, 1, NULL, 3));
    --
    IF v_tests = 0 THEN
        RAISE_APPLICATION_ERROR(-20998, 'UT3: 0 tests ran - no suite installed, or a test package is INVALID.');
    END IF;
    --
    IF v_failed > 0 OR v_errored > 0 THEN
        RAISE_APPLICATION_ERROR(-20999,
            'UT3: ' || v_failed || ' failed, ' || v_errored || ' errored of ' || v_tests || '.');
    END IF;
END;
/

EXIT;
