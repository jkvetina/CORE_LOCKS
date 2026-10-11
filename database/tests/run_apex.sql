--
-- Run the apex suite, which needs the APEX fixture from create_test_apex.sql and
-- install_apex.sql, on APEX 26.2 or newer.
--
--     sqlplus core_locks/core_locks@<host>:<port>/<service> @database/tests/run_apex.sql
--
-- run.sql excludes the tag; this file asks for it by name, and raises on a failure,
-- no summary line, and fewer tests than the suite declares.
--
set serveroutput on size unlimited
set lines 200 pages 0 feed off verify off
whenever sqlerror exit failure

DECLARE
    c_summary_pattern   CONSTANT VARCHAR2(200) := '^(\d+) tests?, (\d+) failed, (\d+) errored';
    --
    -- the apex suite's own test count, so a tag that stops matching cannot pass
    c_expected          CONSTANT PLS_INTEGER := 22;
    --
    v_summary           VARCHAR2(4000);
    v_tests             PLS_INTEGER;
    v_failed            PLS_INTEGER;
    v_errored           PLS_INTEGER;
BEGIN
    FOR c IN (
        SELECT column_value AS line
        FROM TABLE(ut.run(a_tags => 'apex'))
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
    IF v_tests < c_expected THEN
        RAISE_APPLICATION_ERROR(-20998,
            'UT3: ' || v_tests || ' apex test(s) ran, expected ' || c_expected
            || ' - the tag no longer matches, or the suite is not installed.');
    END IF;
    --
    IF v_failed > 0 OR v_errored > 0 THEN
        RAISE_APPLICATION_ERROR(-20999,
            'UT3: ' || v_failed || ' failed, ' || v_errored || ' errored of ' || v_tests || '.');
    END IF;
END;
/

EXIT;
