CREATE OR REPLACE PACKAGE core_lock AS

    -- same code CORE used, so an APEX error handler tuned to CORE keeps
    -- recognizing locking errors after this package is installed standalone
    c_app_exception_code    CONSTANT PLS_INTEGER := -20990;
    --
    app_exception           EXCEPTION;
    PRAGMA EXCEPTION_INIT(app_exception, -20990);



    PROCEDURE raise_error (
        in_message          VARCHAR2 := NULL
    );



    FUNCTION get_user
    RETURN core_locks.locked_by%TYPE;



    FUNCTION get_audit_trail
    RETURN core_locks.audit_trail%TYPE;



    PROCEDURE create_lock (
        in_object_owner     core_locks.object_owner%TYPE,
        in_object_type      core_locks.object_type%TYPE,
        in_object_name      core_locks.object_name%TYPE,
        in_locked_by        core_locks.locked_by%TYPE       := NULL,
        in_expire_at        core_locks.expire_at%TYPE       := NULL,
        in_hash_check       BOOLEAN                         := TRUE
    );



    PROCEDURE extend_lock (
        in_lock_id          core_locks.lock_id%TYPE,
        in_time             NUMBER
    );



    PROCEDURE extend_lock (
        in_lock_id          core_locks.lock_id%TYPE,
        in_expire_at        core_locks.expire_at%TYPE       := NULL
    );



    PROCEDURE unlock (
        in_lock_id          core_locks.lock_id%TYPE         := NULL,
        in_locked_by        core_locks.locked_by%TYPE       := NULL,
        in_object_name      core_locks.object_name%TYPE     := NULL,
        in_object_type      core_locks.object_type%TYPE     := NULL
    );



    FUNCTION get_object
    RETURN CLOB;



    FUNCTION get_clob_hash (
        in_payload          CLOB,
        in_type             PLS_INTEGER := NULL
    )
    RETURN VARCHAR2;

END;
/

