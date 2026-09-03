--
-- Run the proxy suite, which only means anything on a proxy connection.
--
--     sqlplus CLUT_PROXY[CORE_LOCKS]/clut_proxy@<host>:<port>/<service> @database/tests/run_proxy.sql
--
-- SYS_CONTEXT('USERENV', 'PROXY_USER') is set when the session connects and can
-- never be set afterwards, so this is the one suite that cannot be reached from
-- the ordinary run. run.sql excludes the tag; this file asks for it by name.
--
-- A sibling of run.sql rather than a parameter of it: the two differ in which
-- tests they select and in what an empty result means, and one runner reading a
-- substitution variable would hide both differences behind a symbol.
--
-- It raises on the four ways this run can lie: a failure, no summary line, a
-- summary reporting zero tests, and fewer tests than the suite declares, which is
-- what a renamed tag or a half-installed package looks like from here.
--
set serveroutput on size unlimited
set lines 200 pages 0 feed off verify off
whenever sqlerror exit failure

DECLARE
    c_summary_pattern   CONSTANT VARCHAR2(200) := '^(\d+) tests?, (\d+) failed, (\d+) errored';
    --
    -- the proxy suite's own test count. A tag that stops matching reports zero and
    -- a suite that half compiles reports fewer, and both read as a clean run
    c_expected          CONSTANT PLS_INTEGER := 5;
    --
    v_summary           VARCHAR2(4000);
    v_tests             PLS_INTEGER;
    v_failed            PLS_INTEGER;
    v_errored           PLS_INTEGER;
BEGIN
    IF SYS_CONTEXT('USERENV', 'PROXY_USER') IS NULL THEN
        RAISE_APPLICATION_ERROR(-20998,
            'PROXY: this session has no proxy user. Connect as CLUT_PROXY[CORE_LOCKS] and run it again.');
    END IF;
    --
    FOR c IN (
        SELECT column_value AS line
        FROM TABLE(ut.run(a_tags => 'proxy'))
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
            'UT3: ' || v_tests || ' proxy test(s) ran, expected ' || c_expected
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
