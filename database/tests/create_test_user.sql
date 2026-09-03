--
-- The throwaway schema the CORE_LOCKS test suite installs into. Run as SYSDBA.
--
--     sqlplus "sys/<password>@<host>:<port>/<service> as sysdba" @create_test_user.sql
--
-- CORE_LOCKS is a schema-wide AFTER DDL trigger, so it governs every CREATE,
-- ALTER and DROP in whatever schema it is installed in. That is the whole point
-- of the feature, and it is also why the suite gets a schema of its own. Install
-- it beside other work and that work inherits the trigger; an INVALID core_lock
-- package there means no DDL succeeds at all until somebody drops it.
--
-- The password is a fixed throwaway and is deliberately in plain sight. This
-- schema holds test fixtures and nothing else, and the suite recreates its probe
-- objects on every run.
--
-- Prerequisites this script cannot grant itself:
--   - utPLSQL v3, conventionally in a UT3 schema. The grants at the bottom
--     assume that layout and report rather than fail when it is not there.
--   - APEX, for the APEX_STRING public synonym core_lock splits CLOBs with.
--
set serveroutput on size unlimited
set verify off feed off
whenever sqlerror exit failure

-- the PDB to create the schema in; pass another as the first argument
DEFINE pdb = FREEPDB1

ALTER SESSION SET CONTAINER = &pdb;

BEGIN
    EXECUTE IMMEDIATE 'DROP USER core_locks CASCADE';
EXCEPTION
WHEN OTHERS THEN
    IF SQLCODE != -1918 THEN  -- user does not exist
        RAISE;
    END IF;
END;
/

CREATE USER core_locks IDENTIFIED BY "core_locks";

ALTER USER core_locks QUOTA UNLIMITED ON users;

GRANT CONNECT                   TO core_locks;
GRANT ALTER SESSION             TO core_locks;
GRANT CREATE TABLE              TO core_locks;
GRANT CREATE VIEW               TO core_locks;
GRANT CREATE MATERIALIZED VIEW  TO core_locks;
GRANT CREATE TRIGGER            TO core_locks;
GRANT CREATE SEQUENCE           TO core_locks;
GRANT CREATE PROCEDURE          TO core_locks;
GRANT CREATE JOB                TO core_locks;
GRANT CREATE SYNONYM            TO core_locks;
GRANT CREATE TYPE               TO core_locks;

-- The account the proxy suite connects through. It owns nothing and may do
-- nothing but connect: a session authenticating as CLUT_PROXY runs as
-- CORE_LOCKS, with SYS_CONTEXT('USERENV','PROXY_USER') naming the account that
-- vouched for it. That is the top rung of get_user's ladder and the one rung no
-- session can set for itself, so testing it needs a second account rather than
-- a fixture. The password is a throwaway for the same reason the schema's is.
BEGIN
    EXECUTE IMMEDIATE 'DROP USER clut_proxy CASCADE';
EXCEPTION
WHEN OTHERS THEN
    IF SQLCODE != -1918 THEN  -- user does not exist
        RAISE;
    END IF;
END;
/

CREATE USER clut_proxy IDENTIFIED BY "clut_proxy";

GRANT CREATE SESSION TO clut_proxy;

ALTER USER core_locks GRANT CONNECT THROUGH clut_proxy;

-- core_lock hashes CLOBs, names the session's user, reads the dictionary
-- and registers the purge job. DBMS_SESSION also carries SLEEP, which is how the
-- concurrency suite waits for the session it borrowed from the scheduler
GRANT EXECUTE ON DBMS_CRYPTO            TO core_locks;
GRANT EXECUTE ON DBMS_SESSION           TO core_locks;
GRANT EXECUTE ON DBMS_METADATA          TO core_locks;
GRANT EXECUTE ON DBMS_SCHEDULER         TO core_locks;
GRANT EXECUTE ON DBMS_APPLICATION_INFO  TO core_locks;

-- utPLSQL in its own schema. A missing synonym surfaces as a compile error in
-- every test package at once, so say plainly which half is absent
DECLARE
    v_ut            PLS_INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_ut FROM dba_users WHERE username = 'UT3';
    --
    IF v_ut = 0 THEN
        DBMS_OUTPUT.PUT_LINE('WARNING: no UT3 schema. Install utPLSQL v3 and grant');
        DBMS_OUTPUT.PUT_LINE('         EXECUTE on ut and ut_runner to core_locks yourself.');
        RETURN;
    END IF;
    --
    EXECUTE IMMEDIATE 'GRANT EXECUTE ON ut3.ut TO core_locks';
    EXECUTE IMMEDIATE 'GRANT EXECUTE ON ut3.ut_runner TO core_locks';
    --
    DBMS_OUTPUT.PUT_LINE('utPLSQL grants applied from UT3.');
END;
/

PROMPT
PROMPT CORE_LOCKS test schema created. Install the suite with:
PROMPT     sqlplus core_locks/core_locks@<host>:<port>/<service> @database/tests/install.sql
PROMPT

EXIT;
