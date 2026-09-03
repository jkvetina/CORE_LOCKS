--
-- Run the anon suite, which only means anything on a connection with no address.
--
--     sqlplus core_locks/core_locks@<local IPC descriptor> @database/tests/run_anon.sql
--
-- core_lock.get_user ends its ladder on SYS_CONTEXT('USERENV', 'IP_ADDRESS'), so a
-- session reached over TCP always resolves to somebody and the locksmith's refusal
-- of an anonymous session can never fire. A local connection (IPC or bequeath)
-- carries no address, and the OS user behind it is the database's own account,
-- which clean_user reduces to nobody like any other service account. That is the
-- one connection where this suite tests the product rather than the connection.
--
-- run.sql excludes the tag; this file asks for it by name. run_anon.sh knows how to
-- reach such a connection when the database is in a container, which on this
-- machine it is.
--
-- A sibling of run.sql and run_proxy.sql for the reason given in run_proxy.sql: the
-- three differ in which tests they select and in what an empty result means, and one
-- runner reading a substitution variable would hide all of that behind a symbol.
--
-- It raises on the four ways this run can lie: a failure, no summary line, a summary
-- reporting zero tests, and fewer tests than the suite declares, which is what a
-- renamed tag or a half-installed package looks like from here.
--
set serveroutput on size unlimited
set lines 200 pages 0 feed off verify off
whenever sqlerror exit failure

DECLARE
    c_summary_pattern   CONSTANT VARCHAR2(200) := '^(\d+) tests?, (\d+) failed, (\d+) errored';
    --
    -- the anon suite's own test count. A tag that stops matching reports zero and a
    -- suite that half compiles reports fewer, and both read as a clean run
    c_expected          CONSTANT PLS_INTEGER := 4;
    --
    v_summary           VARCHAR2(4000);
    v_tests             PLS_INTEGER;
    v_failed            PLS_INTEGER;
    v_errored           PLS_INTEGER;
BEGIN
    -- refused up front rather than left to the suite's own control test, so the
    -- reason is a sentence about the connection instead of a failed assertion
    IF SYS_CONTEXT('USERENV', 'IP_ADDRESS') IS NOT NULL THEN
        RAISE_APPLICATION_ERROR(-20998,
            'ANON: this session has an address (' || SYS_CONTEXT('USERENV', 'IP_ADDRESS')
            || '), so it resolves to somebody and the refusal under test cannot fire.'
            || ' Connect locally over IPC or bequeath and run it again.');
    END IF;
    --
    FOR c IN (
        SELECT column_value AS line
        FROM TABLE(ut.run(a_tags => 'anon'))
    ) LOOP
        DBMS_OUTPUT.PUT_LINE(c.line);
        --
        IF REGEXP_LIKE(c.line, c_summary_pattern) THEN
            v_summary := c.line;
        END IF;
    END LOOP;
    --
    IF v_summary IS NULL THEN
        RAISE_APPLICATION_ERROR(-20998, 'UT3: no summary line, the run did not complete.');
    END IF;
    --
    v_tests     := TO_NUMBER(REGEXP_SUBSTR(v_summary, c_summary_pattern, 1, 1, NULL, 1));
    v_failed    := TO_NUMBER(REGEXP_SUBSTR(v_summary, c_summary_pattern, 1, 1, NULL, 2));
    v_errored   := TO_NUMBER(REGEXP_SUBSTR(v_summary, c_summary_pattern, 1, 1, NULL, 3));
    --
    IF v_tests < c_expected THEN
        RAISE_APPLICATION_ERROR(-20998,
            'UT3: ' || v_tests || ' anon test(s) ran, expected ' || c_expected
            || ': the tag no longer matches, or the suite is not installed.');
    END IF;
    --
    IF v_failed > 0 OR v_errored > 0 THEN
        RAISE_APPLICATION_ERROR(-20999,
            'UT3: ' || v_failed || ' failed, ' || v_errored || ' errored of ' || v_tests || '.');
    END IF;
END;
/

EXIT;
