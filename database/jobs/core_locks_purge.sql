DECLARE
    in_job_name             CONSTANT VARCHAR2(128)  := 'CORE_LOCKS_PURGE';
    in_run_immediately      CONSTANT BOOLEAN        := FALSE;
BEGIN
    DBMS_OUTPUT.PUT_LINE('--');
    DBMS_OUTPUT.PUT_LINE('-- REPLACE JOB ' || UPPER(in_job_name));
    DBMS_OUTPUT.PUT_LINE('--');
    --
    BEGIN
        DBMS_SCHEDULER.DROP_JOB(in_job_name, TRUE);
    EXCEPTION
    WHEN OTHERS THEN
        NULL;
    END;
    --
    DBMS_SCHEDULER.CREATE_JOB (
        job_name            => in_job_name,
        job_type            => 'PLSQL_BLOCK',
        job_action          => 'core_lock.purge_locks();',
        number_of_arguments => 0,
        start_date          => SYSDATE,
        repeat_interval     => 'FREQ=DAILY; BYHOUR=3; BYMINUTE=0',
        enabled             => FALSE,
        auto_drop           => TRUE,
        comments            => 'Purge core_locks history: keep last 7 days, then one hash-only row per object'
    );
    --
    DBMS_SCHEDULER.SET_ATTRIBUTE(in_job_name, 'JOB_PRIORITY', 3);
    DBMS_SCHEDULER.ENABLE(in_job_name);
    COMMIT;
    --
    IF in_run_immediately THEN
        DBMS_SCHEDULER.RUN_JOB(in_job_name);
        COMMIT;
    END IF;
END;
/

