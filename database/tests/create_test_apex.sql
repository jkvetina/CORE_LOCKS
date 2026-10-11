--
-- The APEX half of the test schema, for the apex suite. Run as SYSDBA, after
-- create_test_user.sql, on a database with APEX 26.2 or newer.
--
--     sqlplus "sys/<password>@<host>:<port>/<service> as sysdba" @create_test_apex.sql
--
-- Three things the suite cannot arrange for itself:
--   - a workspace on the CORE_LOCKS schema, so its application is lockable at all
--   - two workspace developers, ALICE and BOB, the names the suites already act as;
--     LOCK_APPLICATION refuses any owner who is not a developer of the workspace
--   - EXECUTE on the internal WWV_FLOW_PROPERTY_DEV, which the page locks call
--
-- The developer passwords are throwaways in plain sight, like the schema's own.
-- The application itself is installed by install_apex.sql as CORE_LOCKS.
--
set serveroutput on size unlimited
set verify off feed off
whenever sqlerror exit failure

-- the PDB to create the workspace in
DEFINE pdb = FREEPDB262

ALTER SESSION SET CONTAINER = &pdb;

DECLARE
    c_workspace         CONSTANT VARCHAR2(30)   := 'CLUT';
    --
    v_apex              dba_synonyms.table_owner%TYPE;
    v_exists            PLS_INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_exists
    FROM apex_workspaces w
    WHERE w.workspace = c_workspace;
    --
    IF v_exists > 0 THEN
        APEX_INSTANCE_ADMIN.REMOVE_WORKSPACE (
            p_workspace         => c_workspace,
            p_drop_users        => 'N',
            p_drop_tablespaces  => 'N'
        );
    END IF;
    --
    APEX_INSTANCE_ADMIN.ADD_WORKSPACE (
        p_workspace         => c_workspace,
        p_primary_schema    => 'CORE_LOCKS'
    );
    --
    APEX_UTIL.SET_WORKSPACE (
        p_workspace         => c_workspace
    );
    --
    FOR c IN (
        SELECT 'ALICE' AS user_name FROM DUAL UNION ALL
        SELECT 'BOB'                FROM DUAL
    ) LOOP
        APEX_UTIL.CREATE_USER (
            p_user_name                     => c.user_name,
            p_web_password                  => 'Clut26ai!',
            p_developer_privs               => 'CREATE:DATA_LOADER:EDIT:HELP:MONITOR:SQL',
            p_default_schema                => 'CORE_LOCKS',
            p_change_password_on_first_use  => 'N'
        );
    END LOOP;

    -- the current release's APEX schema, never one an upgrade left behind
    SELECT s.table_owner
    INTO v_apex
    FROM dba_synonyms s
    WHERE s.owner           = 'PUBLIC'
        AND s.synonym_name  = 'APEX_UTIL';
    --
    EXECUTE IMMEDIATE 'GRANT EXECUTE ON ' || DBMS_ASSERT.SCHEMA_NAME(v_apex) || '.WWV_FLOW_PROPERTY_DEV TO core_locks';
    --
    COMMIT;
    --
    DBMS_OUTPUT.PUT_LINE('Workspace ' || c_workspace || ' on CORE_LOCKS, developers ALICE and BOB, ' || v_apex || '.WWV_FLOW_PROPERTY_DEV granted.');
END;
/

PROMPT
PROMPT Install the fixture application and run the apex suite with:
PROMPT     database/tests/run.sh -c core_locks/core_locks@<host>:<port>/<service> --apex
PROMPT

EXIT;
