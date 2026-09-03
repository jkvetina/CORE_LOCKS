CREATE OR REPLACE PACKAGE BODY core_lock_fixture AS

    -- probes dropped leaves first: the trigger sits on the table, so the table
    -- goes last or the drop takes the trigger with it and the count lies
    TYPE t_probe_list IS TABLE OF VARCHAR2(128);
    --
    c_drop_order        CONSTANT t_probe_list := t_probe_list (
        'TRIGGER',
        'VIEW',
        'BIG VIEW',
        'MATERIALIZED VIEW',
        'FUNCTION',
        'PROCEDURE',
        'OWN',
        'DEPSCAN',
        'PACKAGE',
        'SEQUENCE',
        'TABLE'
    );

    -- the racer job names, as a LIKE pattern and as a stem
    c_race_stem         CONSTANT VARCHAR2(30)  := 'CLUT_RACE_';
    c_race_like         CONSTANT VARCHAR2(30)  := 'CLUT\_RACE\_%';

    -- how many run-log rows the racer jobs had before the current race. The
    -- scheduler's run log is append only and outlives DROP_JOB, so a wait for a
    -- count of N returns instantly on the second race and reads the first race's
    -- verdict. Every wait below is for rows added since this baseline
    g_race_base         PLS_INTEGER := 0;



    PROCEDURE drop_job (
        in_name             VARCHAR2
    )
    AS
    BEGIN
        DBMS_SCHEDULER.DROP_JOB(in_name, TRUE);
    EXCEPTION
    WHEN OTHERS THEN
        NULL;   -- not there, which is the normal first run
    END;



    FUNCTION job_runs (
        in_pattern          VARCHAR2
    )
    RETURN PLS_INTEGER
    AS
        v_out               PLS_INTEGER;
    BEGIN
        SELECT COUNT(*)
        INTO v_out
        FROM user_scheduler_job_run_details t
        WHERE t.job_name LIKE in_pattern ESCAPE '\';
        --
        RETURN v_out;
    END;



    PROCEDURE act_as (
        in_name             VARCHAR2
    )
    AS
    BEGIN
        DBMS_SESSION.SET_IDENTIFIER(in_name);
    END;



    PROCEDURE act_as_nobody
    AS
    BEGIN
        -- both, because get_user asks both. Clearing the identifier and leaving
        -- client info behind names the session just as well, one rung further down
        DBMS_SESSION.CLEAR_IDENTIFIER();
        DBMS_APPLICATION_INFO.SET_CLIENT_INFO(NULL);
    END;



    FUNCTION probe_ddl (
        in_object_type      VARCHAR2,
        in_version          PLS_INTEGER := 1
    )
    RETURN CLOB
    AS
        -- the one line that differs between the two versions, and it sits in the
        -- body rather than the header on purpose
        v_mark              VARCHAR2(64) := CASE WHEN in_version = 1 THEN '1' ELSE '2' END;
        v_out               CLOB;
    BEGIN
        --
        -- The CREATE headers below are lower case and doubly spaced, and both are
        -- load bearing.
        --
        -- The trigger fingerprints the statement a developer typed; a lock booked
        -- by hand fingerprints a header this feature rebuilds from the dictionary.
        -- Those two agree only because object_body drops the header before hashing.
        -- Write the probe's header the way the dictionary would write it (upper
        -- case, single spaced) and the two texts match with the header left on, so
        -- the strip stops mattering and the parity test passes whether the feature
        -- works or not. get_object also upper cases 'create ', ' or ' and
        -- ' replace' on the first line, which closes the casing difference on its
        -- own; the extra spaces are what it cannot normalise away.
        --
        CASE in_object_type
        WHEN 'PACKAGE' THEN
            RETURN TO_CLOB (
                'create  or  replace  package ' || LOWER(c_pkg) || ' as' || CHR(10) ||
                '    c_version CONSTANT PLS_INTEGER := ' || v_mark || ';' || CHR(10) ||
                '    PROCEDURE run;' || CHR(10) ||
                'END;'
            );
            --
        WHEN 'PACKAGE BODY' THEN
            RETURN TO_CLOB (
                'create  or  replace  package body ' || LOWER(c_pkg) || ' as' || CHR(10) ||
                '    PROCEDURE run AS' || CHR(10) ||
                '    BEGIN' || CHR(10) ||
                '        NULL;   -- version ' || v_mark || CHR(10) ||
                '    END;' || CHR(10) ||
                'END;'
            );
            --
        WHEN 'PROCEDURE' THEN
            RETURN TO_CLOB (
                'create  or  replace  procedure ' || LOWER(c_proc) || ' as' || CHR(10) ||
                'BEGIN' || CHR(10) ||
                '    NULL;   -- version ' || v_mark || CHR(10) ||
                'END;'
            );
            --
        WHEN 'FUNCTION' THEN
            RETURN TO_CLOB (
                'create  or  replace  function ' || LOWER(c_fn) || ' return number as' || CHR(10) ||
                'BEGIN' || CHR(10) ||
                '    RETURN ' || v_mark || ';' || CHR(10) ||
                'END;'
            );
            --
        WHEN 'VIEW' THEN
            -- object_body cuts a view at its first standalone AS, so the version
            -- has to live in the query text and not in the column list
            RETURN TO_CLOB (
                'create  or  replace  view ' || LOWER(c_view) || ' as' || CHR(10) ||
                'SELECT ' || v_mark || ' AS x FROM dual'
            );
            --
        WHEN 'TRIGGER' THEN
            RETURN TO_CLOB (
                'create  or  replace  trigger ' || LOWER(c_trigger) || CHR(10) ||
                'BEFORE INSERT ON ' || c_table || CHR(10) ||
                'BEGIN' || CHR(10) ||
                '    NULL;   -- version ' || v_mark || CHR(10) ||
                'END;'
            );
            --
        WHEN 'OWN' THEN
            -- named CORE_LOCK%, which the locksmith skips so the feature can never
            -- lock itself out. A tracked type and a tracked event on purpose: the
            -- name is the only reason this one is ignored
            RETURN TO_CLOB (
                'create  or  replace  procedure ' || LOWER(c_own) || ' as' || CHR(10) ||
                'BEGIN' || CHR(10) ||
                '    NULL;   -- version ' || v_mark || CHR(10) ||
                'END;'
            );
            --
        WHEN 'DEPSCAN' THEN
            -- what a dependency scanner leaves behind: a real PROCEDURE, created by
            -- a real CREATE, differing from the PROCEDURE probe in its name alone.
            -- Everything the locksmith tracks is satisfied here, so a lock on this
            -- object means the DEPSCAN$ skip did not run
            RETURN TO_CLOB (
                'create  or  replace  procedure ' || LOWER(c_depscan) || ' as' || CHR(10) ||
                'BEGIN' || CHR(10) ||
                '    NULL;   -- version ' || v_mark || CHR(10) ||
                'END;'
            );
            --
        WHEN 'MATERIALIZED VIEW' THEN
            RETURN TO_CLOB (
                'create  materialized  view ' || LOWER(c_mview) || ' as' || CHR(10) ||
                'SELECT ' || v_mark || ' AS x FROM dual'
            );
            --
        WHEN 'BIG VIEW' THEN
            -- padded past 32k with predicates rather than one long literal, because a
            -- SQL string literal caps at 4000 characters and the point is the length
            -- of the view TEXT, which Oracle keeps as a LONG
            v_out := TO_CLOB (
                'create  or  replace  view ' || LOWER(c_bigview) || ' as' || CHR(10) ||
                'SELECT ' || v_mark || ' AS x FROM dual WHERE 1 = 1' || CHR(10)
            );
            --
            FOR i IN 1 .. 1800 LOOP
                v_out := v_out || '    AND ''a'' != ''pad' || LPAD(i, 6, '0') || '''' || CHR(10);
            END LOOP;
            --
            RETURN v_out;
            --
        WHEN 'TABLE' THEN
            -- a table carries no source, so it has no second version to offer
            RETURN TO_CLOB('CREATE TABLE ' || c_table || ' (id NUMBER)');
            --
        WHEN 'SEQUENCE' THEN
            RETURN TO_CLOB('CREATE SEQUENCE ' || c_sequence);
            --
        ELSE
            RAISE_APPLICATION_ERROR(-20001, 'NO_PROBE_FOR_TYPE: ' || in_object_type);
        END CASE;
    END;



    --
    -- Compile one probe. A TABLE has no CREATE OR REPLACE, so it is dropped
    -- first; everything else replaces in place, which is what a developer
    -- recompiling their own work actually does.
    --
    PROCEDURE compile_probe (
        in_object_type      VARCHAR2,
        in_version          PLS_INTEGER := 1
    )
    AS
    BEGIN
        -- a TABLE, a SEQUENCE and a MATERIALIZED VIEW have no CREATE OR REPLACE form
        IF in_object_type IN ('TABLE', 'SEQUENCE', 'MATERIALIZED VIEW') THEN
            BEGIN
                EXECUTE IMMEDIATE 'DROP ' || in_object_type || ' '
                    || CASE in_object_type
                        WHEN 'TABLE'    THEN c_table
                        WHEN 'SEQUENCE' THEN c_sequence
                        ELSE c_mview
                       END
                    || CASE in_object_type WHEN 'TABLE' THEN ' PURGE' END;
            EXCEPTION
            WHEN OTHERS THEN
                NULL;   -- not there yet, which is the normal first run
            END;
        END IF;
        --
        EXECUTE IMMEDIATE probe_ddl(in_object_type, in_version);
    END;



    PROCEDURE drop_probes
    AS
        v_name              VARCHAR2(128);
        v_type              VARCHAR2(30);
    BEGIN
        FOR i IN 1 .. c_drop_order.COUNT LOOP
            v_name := CASE c_drop_order(i)
                WHEN 'TRIGGER'              THEN c_trigger
                WHEN 'VIEW'                 THEN c_view
                WHEN 'BIG VIEW'             THEN c_bigview
                WHEN 'MATERIALIZED VIEW'    THEN c_mview
                WHEN 'FUNCTION'             THEN c_fn
                WHEN 'PROCEDURE'            THEN c_proc
                WHEN 'OWN'                  THEN c_own
                WHEN 'DEPSCAN'              THEN c_depscan
                WHEN 'PACKAGE'              THEN c_pkg
                WHEN 'SEQUENCE'             THEN c_sequence
                WHEN 'TABLE'                THEN c_table
            END;
            --
            -- OWN, DEPSCAN and BIG VIEW are probe roles, not object types; each is
            -- dropped as whatever it actually is
            v_type := CASE c_drop_order(i)
                WHEN 'OWN'      THEN 'PROCEDURE'
                WHEN 'DEPSCAN'  THEN 'PROCEDURE'
                WHEN 'BIG VIEW' THEN 'VIEW'
                ELSE c_drop_order(i)
            END;
            --
            BEGIN
                EXECUTE IMMEDIATE 'DROP ' || v_type || ' ' || v_name
                    || CASE WHEN v_type = 'TABLE' THEN ' PURGE' END;
            EXCEPTION
            WHEN OTHERS THEN
                -- "it was not there" is the normal case and says nothing; every
                -- other code is a cleanup that genuinely failed and must be heard
                --   -942   table or view
                --   -4043  package, procedure, function
                --   -4080  trigger
                --   -2289  sequence
                --   -12003 materialized view
                IF SQLCODE NOT IN (-942, -4043, -4080, -2289, -12003) THEN
                    RAISE;
                END IF;
            END;
        END LOOP;
    END;



    PROCEDURE clear_locks
    AS
    BEGIN
        DELETE FROM core_locks;
        COMMIT;
    END;



    PROCEDURE age_lock (
        in_object_name      VARCHAR2    := NULL,
        in_expire_at        DATE        := NULL,
        in_locked_at        DATE        := NULL
    )
    AS
    BEGIN
        UPDATE core_locks t
        SET t.expire_at     = NVL(in_expire_at, t.expire_at),
            t.locked_at     = NVL(in_locked_at, t.locked_at)
        WHERE (t.object_name = in_object_name OR in_object_name IS NULL);
        --
        COMMIT;
    END;



    --
    -- The locksmith is a schema-wide AFTER DDL trigger, so the unit suite turns
    -- it off before compiling anything: a probe compiled with it on would open a
    -- lock of its own and the row the test is asserting about would not be the
    -- row the test created. CORE_LOCKSMITH matches the trigger's own
    -- CORE_LOCK% exclusion, so switching it never fires it.
    --
    PROCEDURE locksmith (
        in_enabled          BOOLEAN
    )
    AS
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TRIGGER core_locksmith '
            || CASE WHEN in_enabled THEN 'ENABLE' ELSE 'DISABLE' END;
    END;



    FUNCTION locksmith_status
    RETURN VARCHAR2
    AS
        v_out               VARCHAR2(30);
    BEGIN
        SELECT MAX(t.status)
        INTO v_out
        FROM user_triggers t
        WHERE t.trigger_name = 'CORE_LOCKSMITH';
        --
        RETURN v_out;
    END;



    FUNCTION lock_count (
        in_object_name      VARCHAR2    := NULL,
        in_object_type      VARCHAR2    := NULL
    )
    RETURN PLS_INTEGER
    AS
        v_out               PLS_INTEGER;
    BEGIN
        SELECT COUNT(*)
        INTO v_out
        FROM core_locks t
        WHERE (t.object_name    = in_object_name OR in_object_name IS NULL)
            AND (t.object_type  = in_object_type OR in_object_type IS NULL);
        --
        RETURN v_out;
    END;



    PROCEDURE in_other_session (
        in_body             VARCHAR2,
        in_wait_seconds     NUMBER      := 30
    )
    AS
        v_base              PLS_INTEGER;
        v_now               PLS_INTEGER := 0;
        v_waited            NUMBER      := 0;
    BEGIN
        g_job_status    := NULL;
        g_job_error     := NULL;
        --
        drop_job(c_job);
        v_base := job_runs(c_job);
        --
        DBMS_SCHEDULER.CREATE_JOB (
            job_name    => c_job,
            job_type    => 'PLSQL_BLOCK',
            job_action  => in_body,
            enabled     => FALSE
        );
        --
        -- use_current_session FALSE is the whole point: TRUE would run the block
        -- right here and the suite would be talking to itself again
        DBMS_SCHEDULER.RUN_JOB(c_job, use_current_session => FALSE);
        --
        WHILE v_now <= v_base AND v_waited < in_wait_seconds LOOP
            DBMS_SESSION.SLEEP(0.05);
            v_waited    := v_waited + 0.05;
            v_now       := job_runs(c_job);
        END LOOP;
        --
        IF v_now <= v_base THEN
            -- reported, never waited out silently: a test that gave up waiting and
            -- then asserted on an empty lock table would read as a passing guard
            g_job_status    := 'TIMEOUT';
            g_job_error     := 'the other session did not finish within ' || in_wait_seconds || 's';
            drop_job(c_job);
            RETURN;
        END IF;
        --
        SELECT
            MAX(t.status) KEEP (DENSE_RANK LAST ORDER BY t.log_id),
            SUBSTR(MAX(t.additional_info) KEEP (DENSE_RANK LAST ORDER BY t.log_id), 1, 4000)
        INTO g_job_status, g_job_error
        FROM user_scheduler_job_run_details t
        WHERE t.job_name = c_job;
        --
        drop_job(c_job);
    END;



    PROCEDURE start_racers (
        in_count            PLS_INTEGER,
        in_object_type      VARCHAR2,
        in_object_name      VARCHAR2,
        in_delay_seconds    PLS_INTEGER := 2
    )
    AS
        v_when              TIMESTAMP WITH TIME ZONE;
    BEGIN
        drop_jobs();
        --
        g_racers_done   := 0;
        g_race_base     := job_runs(c_race_like);

        -- one start time shared by all of them. RUN_JOB starts a slave whenever it
        -- gets round to it, and six of those in a row is not a race: it is six
        -- calls in sequence, which the guard passes whatever it does about
        -- simultaneity. A start_date in the near future is what releases them together
        v_when := SYSTIMESTAMP + NUMTODSINTERVAL(in_delay_seconds, 'SECOND');
        --
        FOR i IN 1 .. in_count LOOP
            DBMS_SCHEDULER.CREATE_JOB (
                job_name    => c_race_stem || i,
                job_type    => 'PLSQL_BLOCK',
                job_action  => 'BEGIN DBMS_SESSION.SET_IDENTIFIER(''RACER' || i || ''');'
                    || ' core_lock.create_lock(USER, ''' || in_object_type || ''', ''' || in_object_name || '''); END;',
                start_date  => v_when,
                enabled     => TRUE
            );
        END LOOP;
    END;



    PROCEDURE await_racers (
        in_count            PLS_INTEGER,
        in_wait_seconds     NUMBER      := 60
    )
    AS
        v_now               PLS_INTEGER := 0;
        v_waited            NUMBER      := 0;
    BEGIN
        WHILE v_now - g_race_base < in_count AND v_waited < in_wait_seconds LOOP
            DBMS_SESSION.SLEEP(0.1);
            v_waited    := v_waited + 0.1;
            v_now       := job_runs(c_race_like);
        END LOOP;
        --
        g_racers_done := v_now - g_race_base;
        --
        drop_jobs();
    END;



    PROCEDURE drop_jobs
    AS
    BEGIN
        FOR c IN (
            SELECT t.job_name
            FROM user_scheduler_jobs t
            WHERE t.job_name        = c_job
                OR t.job_name LIKE c_race_like ESCAPE '\'
        ) LOOP
            drop_job(c.job_name);
        END LOOP;
    END;



    FUNCTION live_lock_count (
        in_object_name      VARCHAR2    := NULL
    )
    RETURN PLS_INTEGER
    AS
        v_out               PLS_INTEGER;
    BEGIN
        SELECT COUNT(*)
        INTO v_out
        FROM core_locks t
        WHERE (t.object_name    = in_object_name OR in_object_name IS NULL)
            AND t.expire_at     >= SYSDATE;
        --
        RETURN v_out;
    END;



    PROCEDURE teardown
    AS
        v_left              PLS_INTEGER;
        v_jobs              PLS_INTEGER;
        v_was               VARCHAR2(30);
    BEGIN
        g_teardown_error := NULL;
        v_was := locksmith_status();

        -- Cleanup runs with the locksmith off, and that is not a convenience.
        -- Dropping a probe is DDL like any other, so the trigger fires on it and
        -- can refuse it: a probe still carrying somebody else's fresh lock is
        -- exactly the state several tests deliberately leave behind, and the
        -- product is right to stop a second person destroying it. Teardown is not
        -- what those tests are about, so it steps outside the guard and puts it
        -- back the way it found it.
        BEGIN
            locksmith(FALSE);
        EXCEPTION
        WHEN OTHERS THEN
            g_teardown_error := 'LOCKSMITH_OFF: ' || SUBSTR(SQLERRM, 1, 1000);
        END;

        -- two steps, two handlers. One block would let a failed drop skip the
        -- delete entirely, and the leftover rows would then be blamed on the next
        -- test instead of on the cleanup that never ran
        BEGIN
            drop_probes();
        EXCEPTION
        WHEN OTHERS THEN
            -- recorded, never swallowed: a suite that hides its failed cleanup
            -- starts depending on its own leftovers the very next run
            g_teardown_error := SUBSTR(g_teardown_error || ' DROP_PROBES: ' || SQLERRM, 1, 3000);
        END;
        --
        BEGIN
            clear_locks();
        EXCEPTION
        WHEN OTHERS THEN
            g_teardown_error := SUBSTR(g_teardown_error || ' CLEAR_LOCKS: ' || SQLERRM, 1, 4000);
        END;
        --
        -- a racer left behind does not sit still: its start_date arrives during
        -- somebody else's test and it takes a lock nobody asked for
        BEGIN
            drop_jobs();
        EXCEPTION
        WHEN OTHERS THEN
            g_teardown_error := SUBSTR(g_teardown_error || ' DROP_JOBS: ' || SQLERRM, 1, 4000);
        END;
        --
        IF v_was = 'ENABLED' THEN
            BEGIN
                locksmith(TRUE);
            EXCEPTION
            WHEN OTHERS THEN
                g_teardown_error := SUBSTR(g_teardown_error || ' LOCKSMITH_ON: ' || SQLERRM, 1, 4000);
            END;
        END IF;

        -- count what survived, probes and history alike
        SELECT COUNT(*)
        INTO v_left
        FROM user_objects t
        WHERE t.object_name IN (c_pkg, c_proc, c_fn, c_view, c_bigview, c_mview,
            c_trigger, c_table, c_sequence, c_own, c_depscan);
        --
        SELECT COUNT(*)
        INTO v_jobs
        FROM user_scheduler_jobs t
        WHERE t.job_name        = c_job
            OR t.job_name LIKE c_race_like ESCAPE '\';
        --
        g_residue := v_left + v_jobs + lock_count();
    END;

END;
/
