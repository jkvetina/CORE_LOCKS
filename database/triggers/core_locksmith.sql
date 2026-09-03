CREATE OR REPLACE TRIGGER core_locksmith
AFTER DDL ON SCHEMA
DECLARE
    -- Oracle calls a materialized view a SNAPSHOT in every DDL event it fires
    -- for one, CREATE, ALTER and DROP alike, so a list naming it MATERIALIZED
    -- VIEW reads as tracked and never matches: measured on 26ai, a materialized
    -- view took no lock at all. The dictionary's name is what the filter has to
    -- ask for, and ours is what the row has to record, because object_body
    -- strips a view header under MATERIALIZED VIEW and DBMS_METADATA is asked
    -- for MATERIALIZED_VIEW. One object under one type name is also what lets a
    -- lock taken by a compile and one taken by hand find each other in history
    v_object_type       core_locks.object_type%TYPE;
BEGIN
    -- ignore procedure scanning objects
    IF ORA_DICT_OBJ_TYPE = 'PROCEDURE' AND ORA_DICT_OBJ_NAME LIKE 'DEPSCAN$%' THEN
        RETURN;
    END IF;
    --
    v_object_type := CASE ORA_DICT_OBJ_TYPE
        WHEN 'SNAPSHOT' THEN 'MATERIALIZED VIEW'
        ELSE ORA_DICT_OBJ_TYPE
    END;

    -- evaluate only specific events and specific object types
    IF ORA_SYSEVENT IN ('CREATE', 'ALTER', 'DROP')
        AND ORA_DICT_OBJ_TYPE IN (
            'TABLE', 'VIEW', 'SNAPSHOT',
            'PACKAGE', 'PACKAGE BODY', 'PROCEDURE', 'FUNCTION', 'TRIGGER'
        )
        AND ORA_DICT_OBJ_NAME NOT LIKE 'CORE_LOCK%'
    THEN
        -- refuse anonymous sessions, we dont want generic users
        -- either connect through a proxy user or set the client identifier
        -- get_user falls back to the IP, so this only fires on a local connection
        IF core_lock.get_user() IS NULL THEN
            core_lock.raise_error('USER_ERROR: USE_PROXY_USER_OR_SET_CLIENT_ID');
        END IF;
        --
        core_lock.create_lock (
            in_object_owner     => ORA_DICT_OBJ_OWNER,
            in_object_type      => v_object_type,
            in_object_name      => ORA_DICT_OBJ_NAME,
            in_locked_by        => NULL,
            in_expire_at        => NULL
        );
    END IF;
    --
EXCEPTION
WHEN core_lock.app_exception THEN
    RAISE;
WHEN OTHERS THEN
    core_lock.raise_error();
END;
/
