CREATE OR REPLACE TRIGGER core_locksmith
AFTER DDL ON SCHEMA
BEGIN
    -- ignore procedure scanning objects
    IF ORA_DICT_OBJ_TYPE = 'PROCEDURE' AND ORA_DICT_OBJ_NAME LIKE 'DEPSCAN$%' THEN
        RETURN;
    END IF;

    -- evaluate only specific events and specific object types
    IF ORA_SYSEVENT IN ('CREATE', 'ALTER', 'DROP')
        AND ORA_DICT_OBJ_TYPE IN (
            'TABLE', 'VIEW', 'MATERIALIZED VIEW',
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
            in_object_type      => ORA_DICT_OBJ_TYPE,
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
