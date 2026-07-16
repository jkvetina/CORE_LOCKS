CREATE OR REPLACE TRIGGER core_locksmith
AFTER DDL ON SCHEMA
DECLARE
    rec             core_locks%ROWTYPE;
BEGIN
    -- ignore procedure scanning objects
    IF ORA_DICT_OBJ_TYPE = 'PROCEDURE' AND ORA_DICT_OBJ_NAME LIKE 'DEPSCAN$%' THEN
        RETURN;
    END IF;

    -- get username, but we dont want generic users
    BEGIN
        rec.locked_by := core_lock.get_user();
    EXCEPTION
    WHEN OTHERS THEN
        NULL;
    END;

    -- evaluate only specific events and specific object types
    IF ORA_SYSEVENT IN ('CREATE', 'ALTER', 'DROP')
        AND ORA_DICT_OBJ_TYPE IN (
            'TABLE', 'VIEW', 'MATERIALIZED VIEW',
            'PACKAGE', 'PACKAGE BODY', 'PROCEDURE', 'FUNCTION', 'TRIGGER'
        )
        AND ORA_DICT_OBJ_NAME NOT LIKE 'CORE_LOCK%'
    THEN
        core_lock.create_lock (
            in_object_owner     => ORA_DICT_OBJ_OWNER,
            in_object_type      => ORA_DICT_OBJ_TYPE,
            in_object_name      => ORA_DICT_OBJ_NAME,
            in_locked_by        => rec.locked_by,
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

