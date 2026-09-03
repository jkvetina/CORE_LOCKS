CREATE OR REPLACE PACKAGE BODY core_locksmith_ut AS

    --
    -- The newest lock row for an object. The type narrows it because a
    -- materialized view shares its name with the container table Oracle builds
    -- underneath it, and a row for one is not a row for the other.
    --
    FUNCTION newest_lock (
        in_object_name      core_locks.object_name%TYPE,
        in_object_type      core_locks.object_type%TYPE     := NULL
    )
    RETURN core_locks%ROWTYPE
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        SELECT *
        INTO rec
        FROM core_locks t
        WHERE t.object_name     = in_object_name
            AND (t.object_type  = in_object_type OR in_object_type IS NULL)
        ORDER BY
            t.lock_id DESC
        FETCH FIRST 1 ROWS ONLY;
        --
        RETURN rec;
    END;



    --
    -- Whether the probe is still in the schema. A refusal that raises but lets
    -- the statement land is the failure the guard exists to prevent, and for a
    -- DROP the object itself is the only witness left.
    --
    FUNCTION object_exists (
        in_object_name      core_locks.object_name%TYPE
    )
    RETURN PLS_INTEGER
    AS
        v_out               PLS_INTEGER;
    BEGIN
        SELECT COUNT(*)
        INTO v_out
        FROM user_objects t
        WHERE t.object_name = in_object_name;
        --
        RETURN v_out;
    END;



    --
    -- The live source of a probe, so a test can say whether a refused compile was
    -- actually rolled back rather than only that it raised.
    --
    FUNCTION live_version (
        in_object_name      core_locks.object_name%TYPE
    )
    RETURN VARCHAR2
    AS
        v_out               VARCHAR2(4000);
    BEGIN
        SELECT MAX(t.text)
        INTO v_out
        FROM user_source t
        WHERE t.name    = in_object_name
            AND t.text LIKE '%version%';
        --
        RETURN v_out;
    END;



    PROCEDURE before_all
    AS
    BEGIN
        -- every test here is about the trigger firing, so it had better be on;
        -- the unit suite switches it off for itself and may have been interrupted
        core_lock_fixture.locksmith(TRUE);
        core_lock_fixture.teardown();
    END;



    PROCEDURE before_each
    AS
    BEGIN
        core_lock_fixture.act_as(core_lock_fixture.c_alice);
        core_lock_fixture.clear_locks();
    END;



    PROCEDURE after_each
    AS
    BEGIN
        core_lock_fixture.teardown();
        --
        ut.expect(core_lock_fixture.g_teardown_error).to_be_null();
        ut.expect(core_lock_fixture.g_residue).to_equal(0);
        ut.expect(core_lock_fixture.locksmith_status()).to_equal('ENABLED');
    END;



    PROCEDURE test_locksmith#a_compile_opens_a_lock
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        --
        rec := newest_lock(core_lock_fixture.c_proc);
        --
        ut.expect(core_lock_fixture.lock_count(core_lock_fixture.c_proc)).to_equal(1);
        ut.expect(rec.locked_by).to_equal(core_lock_fixture.c_alice);
        ut.expect(rec.object_type).to_equal('PROCEDURE');
        ut.expect(rec.object_hash).to_be_not_null();
        ut.expect(rec.expire_at).to_be_greater_than(SYSDATE);
        --
        -- the payload is the statement the developer compiled, which is what makes
        -- the lock row a source backup and not just a flag
        ut.expect(DBMS_LOB.INSTR(rec.object_payload, 'version 1')).to_be_greater_than(0);
    END;



    PROCEDURE test_locksmith#the_same_developer_extends_the_one_lock
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        --
        rec := newest_lock(core_lock_fixture.c_proc);
        --
        ut.expect(core_lock_fixture.lock_count(core_lock_fixture.c_proc)).to_equal(1);
        ut.expect(rec.counter).to_equal(2);
    END;



    PROCEDURE test_locksmith#an_alter_compile_opens_no_lock
    AS
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        core_lock_fixture.clear_locks();
        --
        EXECUTE IMMEDIATE 'ALTER PROCEDURE ' || core_lock_fixture.c_proc || ' COMPILE';
        --
        -- recompiling is not a change, so it is the one empty payload that opens
        -- nothing; every other empty payload still takes a lock
        ut.expect(core_lock_fixture.lock_count(core_lock_fixture.c_proc)).to_equal(0);
    END;



    PROCEDURE test_locksmith#core_lock_objects_are_never_locked
    AS
    BEGIN
        -- a CREATE, on a PROCEDURE: an event and a type the locksmith both track,
        -- so the CORE_LOCK% name is the only thing standing between this statement
        -- and a lock row. Compiling the trigger itself would prove nothing,
        -- because Oracle does not fire a schema DDL trigger for DDL on that same trigger,
        -- so the check would pass with the name rule deleted
        core_lock_fixture.compile_probe('OWN', 1);
        --
        ut.expect(core_lock_fixture.lock_count(core_lock_fixture.c_own)).to_equal(0);
        ut.expect(core_lock_fixture.lock_count()).to_equal(0);
    END;



    PROCEDURE test_locksmith#an_untracked_object_type_is_ignored
    AS
    BEGIN
        core_lock_fixture.compile_probe('SEQUENCE');
        --
        ut.expect(core_lock_fixture.lock_count(core_lock_fixture.c_sequence)).to_equal(0);
    END;



    PROCEDURE test_locksmith#a_hand_lock_matches_a_compile
    AS
        TYPE t_types IS TABLE OF VARCHAR2(30);
        --
        c_types             CONSTANT t_types := t_types('PROCEDURE', 'FUNCTION', 'PACKAGE BODY', 'VIEW');
        --
        v_name              core_locks.object_name%TYPE;
        v_by_compile        core_locks.object_hash%TYPE;
        v_by_hand           core_locks.object_hash%TYPE;
    BEGIN
        -- the package body needs its spec before it will compile
        core_lock_fixture.compile_probe('PACKAGE', 1);
        --
        FOR i IN 1 .. c_types.COUNT LOOP
            v_name := CASE c_types(i)
                WHEN 'PROCEDURE'    THEN core_lock_fixture.c_proc
                WHEN 'FUNCTION'     THEN core_lock_fixture.c_fn
                WHEN 'PACKAGE BODY' THEN core_lock_fixture.c_pkg
                WHEN 'VIEW'         THEN core_lock_fixture.c_view
            END;

            -- a first version, so the text the dictionary held before this compile
            -- is never the text it holds after it. Without this step a design that
            -- reads the wrong version of the object passes the comparison perfectly
            core_lock_fixture.act_as(core_lock_fixture.c_alice);
            core_lock_fixture.compile_probe(c_types(i), 1);
            core_lock_fixture.clear_locks();

            -- the version under test, locked by the trigger from the statement
            core_lock_fixture.compile_probe(c_types(i), 2);
            v_by_compile := newest_lock(v_name).object_hash;

            -- the same object booked by hand, which reads the dictionary instead
            core_lock_fixture.age_lock (
                in_object_name  => v_name,
                in_expire_at    => SYSDATE - 1/1440
            );
            --
            core_lock_fixture.act_as(core_lock_fixture.c_bob);
            core_lock.create_lock(USER, c_types(i), v_name);
            --
            v_by_hand := newest_lock(v_name).object_hash;
            --
            ut.expect(v_by_compile).to_be_not_null();
            ut.expect(v_by_hand).to_equal(v_by_compile);
        END LOOP;
    END;



    PROCEDURE test_locksmith#a_third_party_edit_is_refused_and_rolled_back
    AS
        v_error             VARCHAR2(4000);
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);

        -- the lock has run out, so nothing stops Bob on time alone. What is left
        -- is the fingerprint: he is about to overwrite a version he never saw
        core_lock_fixture.age_lock (
            in_object_name  => core_lock_fixture.c_proc,
            in_expire_at    => SYSDATE - 1/1440
        );
        --
        core_lock_fixture.act_as(core_lock_fixture.c_bob);
        --
        BEGIN
            core_lock_fixture.compile_probe('PROCEDURE', 2);
        EXCEPTION
        WHEN OTHERS THEN
            -- the whole stack, not SQLERRM: a refusal raised inside a DDL trigger
            -- surfaces as ORA-04088 "error during execution of trigger" and the
            -- ORA-20990 that says why sits underneath it. Asserting on SQLERRM
            -- alone would pin the wrapper and pass for any failure at all
            v_error := DBMS_UTILITY.FORMAT_ERROR_STACK;
        END;
        --
        ut.expect(v_error).to_be_like('%LOCK_HASH_ERROR%');

        -- refusing is only half of it: the compile must not have landed either,
        -- or the guard reports an error over a change it already let through
        ut.expect(live_version(core_lock_fixture.c_proc)).to_be_like('%version 1%');
    END;



    PROCEDURE test_locksmith#a_trigger_compile_opens_a_lock
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        -- the trigger needs its table, and creating that table takes a lock of
        -- its own, so the count below is about the trigger and nothing else
        core_lock_fixture.compile_probe('TABLE');
        core_lock_fixture.clear_locks();
        --
        core_lock_fixture.compile_probe('TRIGGER', 1);
        --
        rec := newest_lock(core_lock_fixture.c_trigger, 'TRIGGER');
        --
        ut.expect(core_lock_fixture.lock_count(core_lock_fixture.c_trigger)).to_equal(1);
        ut.expect(rec.object_hash).to_be_not_null();
        ut.expect(DBMS_LOB.INSTR(rec.object_payload, 'version 1')).to_be_greater_than(0);
    END;



    PROCEDURE test_locksmith#a_materialized_view_compile_opens_a_lock
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('MATERIALIZED VIEW', 1);
        --
        rec := newest_lock(core_lock_fixture.c_mview, 'MATERIALIZED VIEW');

        -- the type has to be the one the rest of the feature uses and not the
        -- SNAPSHOT the dictionary reports, or a lock taken by a compile and one
        -- taken by hand are about two different objects. It is outside the list
        -- create_lock fingerprints, so the backup is all this one gets
        ut.expect(core_lock_fixture.lock_count(core_lock_fixture.c_mview, 'MATERIALIZED VIEW')).to_equal(1);
        ut.expect(rec.locked_by).to_equal(core_lock_fixture.c_alice);
        ut.expect(DBMS_LOB.INSTR(rec.object_payload, 'SELECT 1 AS x')).to_be_greater_than(0);
    END;



    PROCEDURE test_locksmith#an_alter_that_is_not_a_compile_opens_a_lock
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('TABLE');
        core_lock_fixture.clear_locks();
        --
        EXECUTE IMMEDIATE 'ALTER TABLE ' || core_lock_fixture.c_table || ' ADD (note VARCHAR2(10))';
        --
        rec := newest_lock(core_lock_fixture.c_table, 'TABLE');

        -- only ALTER ... COMPILE means "not a change". Every other ALTER is one,
        -- and the statement is the only record of what it did to the object
        ut.expect(core_lock_fixture.lock_count(core_lock_fixture.c_table)).to_equal(1);
        ut.expect(UPPER(DBMS_LOB.SUBSTR(rec.object_payload, 200, 1))).to_be_like('%ADD%');
    END;



    PROCEDURE test_locksmith#a_big_view_fingerprints_the_same_by_hand
    AS
        v_by_compile        core_locks.object_hash%TYPE;
        v_by_hand           core_locks.object_hash%TYPE;
    BEGIN
        -- a first version, so the text the dictionary held before this compile is
        -- never the text it holds after it
        core_lock_fixture.compile_probe('BIG VIEW', 1);
        core_lock_fixture.clear_locks();
        --
        core_lock_fixture.compile_probe('BIG VIEW', 2);
        v_by_compile := newest_lock(core_lock_fixture.c_bigview, 'VIEW').object_hash;
        --
        core_lock_fixture.age_lock (
            in_object_name  => core_lock_fixture.c_bigview,
            in_expire_at    => SYSDATE - 1/1440
        );
        --
        core_lock_fixture.act_as(core_lock_fixture.c_bob);
        core_lock.create_lock(USER, 'VIEW', core_lock_fixture.c_bigview);
        --
        v_by_hand := newest_lock(core_lock_fixture.c_bigview, 'VIEW').object_hash;

        -- past 32k both readers still have to arrive at the same text: the
        -- trigger walks a CLOB of the statement, and the hand lock reads the
        -- LONG the dictionary keeps a view's query in, one chunk at a time
        ut.expect(v_by_compile).to_be_not_null();
        ut.expect(v_by_hand).to_equal(v_by_compile);
    END;



    PROCEDURE test_locksmith#a_drop_is_recorded_not_refused
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);

        -- the lock has run out but it was cut a moment ago, which is the window
        -- the fingerprint check owns. A DROP has no source to fingerprint, and
        -- hashing the statement instead compared "DROP PROCEDURE CLUT_PROC"
        -- against the procedure's own text: those can never match, so every drop
        -- inside that minute came back as somebody else's change
        core_lock_fixture.age_lock (
            in_object_name  => core_lock_fixture.c_proc,
            in_expire_at    => SYSDATE - 1/1440
        );
        --
        core_lock_fixture.act_as(core_lock_fixture.c_bob);
        --
        EXECUTE IMMEDIATE 'DROP PROCEDURE ' || core_lock_fixture.c_proc;
        --
        rec := newest_lock(core_lock_fixture.c_proc, 'PROCEDURE');
        --
        ut.expect(object_exists(core_lock_fixture.c_proc)).to_equal(0);
        ut.expect(rec.locked_by).to_equal(core_lock_fixture.c_bob);
    END;



    PROCEDURE test_locksmith#a_drop_carries_the_last_source_forward
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        --
        core_lock_fixture.age_lock (
            in_object_name  => core_lock_fixture.c_proc,
            in_expire_at    => SYSDATE - 1/1440
        );
        --
        core_lock_fixture.act_as(core_lock_fixture.c_bob);
        --
        EXECUTE IMMEDIATE 'DROP PROCEDURE ' || core_lock_fixture.c_proc;
        --
        rec := newest_lock(core_lock_fixture.c_proc, 'PROCEDURE');

        -- the row a drop opens is the last place that source exists, and it is
        -- the newest row for the object, which is the one row the purge always
        -- keeps. Leave it empty and the backup for a dropped object is the first
        -- thing the housekeeping throws away
        ut.expect(DBMS_LOB.INSTR(rec.object_payload, 'version 1')).to_be_greater_than(0);
        ut.expect(rec.object_hash).to_be_not_null();
    END;



    PROCEDURE test_locksmith#a_live_lock_still_refuses_a_drop
    AS
        v_error             VARCHAR2(4000);
    BEGIN
        -- Alice compiles and walks away holding the lock
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        --
        core_lock_fixture.act_as(core_lock_fixture.c_bob);
        --
        BEGIN
            EXECUTE IMMEDIATE 'DROP PROCEDURE ' || core_lock_fixture.c_proc;
        EXCEPTION
        WHEN OTHERS THEN
            -- the whole stack, because a refusal raised inside a DDL trigger
            -- surfaces as ORA-04088 with the reason underneath it
            v_error := DBMS_UTILITY.FORMAT_ERROR_STACK;
        END;

        -- letting a drop past the fingerprint check must not let it past the
        -- clock as well: destroying an object somebody is holding is the worst
        -- of the cases this lock exists for
        ut.expect(v_error).to_be_like('%LOCK_TIME_ERROR%');
        ut.expect(object_exists(core_lock_fixture.c_proc)).to_equal(1);
    END;

END;
/
