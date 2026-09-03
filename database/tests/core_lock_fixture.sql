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
        'PACKAGE',
        'SEQUENCE',
        'TABLE'
    );



    PROCEDURE act_as (
        in_name             VARCHAR2
    )
    AS
    BEGIN
        DBMS_SESSION.SET_IDENTIFIER(in_name);
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
                WHEN 'PACKAGE'              THEN c_pkg
                WHEN 'SEQUENCE'             THEN c_sequence
                WHEN 'TABLE'                THEN c_table
            END;
            --
            -- OWN and BIG VIEW are probe roles, not object types; each is dropped
            -- as whatever it actually is
            v_type := CASE c_drop_order(i)
                WHEN 'OWN'      THEN 'PROCEDURE'
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



    PROCEDURE teardown
    AS
        v_left              PLS_INTEGER;
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
            c_trigger, c_table, c_sequence, c_own);
        --
        g_residue := v_left + lock_count();
    END;

END;
/
