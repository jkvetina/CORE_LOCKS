--
-- Install the application the apex suite locks. Run FROM THE REPOSITORY ROOT,
-- as CORE_LOCKS, after create_test_apex.sql gave the schema its workspace:
--
--     sqlplus core_locks/core_locks@<host>:<port>/<service> @database/tests/install_apex.sql
--
-- run.sh --apex does this and runs the suite.
--
set serveroutput on size unlimited
set verify off feed off
whenever sqlerror exit failure

BEGIN
    APEX_APPLICATION_INSTALL.SET_WORKSPACE('CLUT');
    APEX_APPLICATION_INSTALL.SET_APPLICATION_ID(9901);
    APEX_APPLICATION_INSTALL.SET_SCHEMA('CORE_LOCKS');
    APEX_APPLICATION_INSTALL.GENERATE_OFFSET;
END;
/

@database/tests/core_lock_apex_app.sql

DECLARE
    v_pages             PLS_INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_pages
    FROM apex_application_pages p
    WHERE p.application_id = 9901;
    --
    IF v_pages != 2 THEN
        RAISE_APPLICATION_ERROR(-20997, 'INSTALL: application 9901 has ' || v_pages || ' page(s), expected 2.');
    END IF;
    --
    DBMS_OUTPUT.PUT_LINE('INSTALL OK: application 9901 with 2 pages in workspace CLUT.');
END;
/

EXIT;
