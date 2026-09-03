CREATE OR REPLACE PACKAGE BODY core_lock_conc_ut AS

    -- how many sessions the race releases at once. Four is enough for the losers
    -- to outnumber the winner and small enough that the scheduler starts them all
    c_racers            CONSTANT PLS_INTEGER := 4;



    --
    -- A block for the other session to run: name itself, then take the lock.
    -- Built here rather than in the fixture because what the second session does
    -- is the subject of each test, not fixture furniture.
    --
    FUNCTION takes_the_lock (
        in_name             VARCHAR2
    )
    RETURN VARCHAR2
    AS
    BEGIN
        RETURN 'BEGIN DBMS_SESSION.SET_IDENTIFIER(''' || in_name || ''');'
            || ' core_lock.create_lock(USER, ''PROCEDURE'', ''' || core_lock_fixture.c_proc || '''); END;';
    END;



    FUNCTION newest_lock (
        in_object_name      core_locks.object_name%TYPE
    )
    RETURN core_locks%ROWTYPE
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        SELECT *
        INTO rec
        FROM core_locks t
        WHERE t.object_name = in_object_name
        ORDER BY
            t.lock_id DESC
        FETCH FIRST 1 ROWS ONLY;
        --
        RETURN rec;
    END;



    PROCEDURE before_all
    AS
    BEGIN
        -- the locksmith stays off throughout: every lock here is booked by an
        -- explicit create_lock, so a trigger firing on the probe compile would add
        -- a row nobody in these tests is talking about
        core_lock_fixture.locksmith(FALSE);
        core_lock_fixture.teardown();
    END;



    PROCEDURE before_each
    AS
    BEGIN
        core_lock_fixture.act_as(core_lock_fixture.c_alice);
        core_lock_fixture.clear_locks();
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        core_lock_fixture.clear_locks();
    END;



    PROCEDURE after_each
    AS
    BEGIN
        core_lock_fixture.teardown();
        --
        ut.expect(core_lock_fixture.g_teardown_error).to_be_null();
        ut.expect(core_lock_fixture.g_residue).to_equal(0);
    END;



    PROCEDURE after_all
    AS
    BEGIN
        core_lock_fixture.locksmith(TRUE);
    END;



    PROCEDURE test_conc#another_sessions_lock_refuses_this_one
    AS
        v_error             VARCHAR2(4000);
    BEGIN
        core_lock_fixture.in_other_session(takes_the_lock(core_lock_fixture.c_bob));
        --
        ut.expect(core_lock_fixture.g_job_status).to_equal('SUCCEEDED');
        --
        BEGIN
            core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        EXCEPTION
        WHEN OTHERS THEN
            v_error := SQLERRM;
        END;

        -- the row Bob committed is in another session's transaction as far as this
        -- one is concerned until he commits, and create_lock is autonomous so he
        -- did. Nothing in the single-session suites can tell those two apart
        ut.expect(v_error).to_be_like('%LOCK_TIME_ERROR%');
        ut.expect(v_error).to_be_like('%' || core_lock_fixture.c_bob || '%');
        ut.expect(newest_lock(core_lock_fixture.c_proc).locked_by).to_equal(core_lock_fixture.c_bob);
    END;



    PROCEDURE test_conc#this_sessions_lock_refuses_another_one
    AS
    BEGIN
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        --
        core_lock_fixture.in_other_session(takes_the_lock(core_lock_fixture.c_bob));

        -- the other direction, and the one that proves the autonomous commit is
        -- visible outward rather than only to the session that made it. The
        -- scheduler keeps the failing session's error stack, which is where a
        -- refusal raised over there is legible from here
        ut.expect(core_lock_fixture.g_job_status).to_equal('FAILED');
        ut.expect(core_lock_fixture.g_job_error).to_be_like('%LOCK_TIME_ERROR%');
        ut.expect(core_lock_fixture.g_job_error).to_be_like('%' || core_lock_fixture.c_alice || '%');
        --
        ut.expect(core_lock_fixture.lock_count(core_lock_fixture.c_proc)).to_equal(1);
        ut.expect(newest_lock(core_lock_fixture.c_proc).locked_by).to_equal(core_lock_fixture.c_alice);
    END;



    PROCEDURE test_conc#a_release_here_frees_the_object_over_there
    AS
    BEGIN
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        core_lock.unlock(in_object_name => core_lock_fixture.c_proc);
        --
        core_lock_fixture.in_other_session(takes_the_lock(core_lock_fixture.c_bob));

        -- releasing is only worth something if somebody else can tell. Without the
        -- unlock above this is the previous test and the job comes back FAILED
        ut.expect(core_lock_fixture.g_job_status).to_equal('SUCCEEDED');
        ut.expect(newest_lock(core_lock_fixture.c_proc).locked_by).to_equal(core_lock_fixture.c_bob);
        ut.expect(core_lock_fixture.live_lock_count(core_lock_fixture.c_proc)).to_equal(1);
    END;



    PROCEDURE test_conc#a_race_leaves_one_holder
    AS
    BEGIN
        core_lock_fixture.start_racers (
            in_count        => c_racers,
            in_object_type  => 'PROCEDURE',
            in_object_name  => core_lock_fixture.c_proc
        );
        --
        core_lock_fixture.await_racers(c_racers);

        -- asserted first and on purpose: one holder is also what an empty table
        -- looks like, so a race that never started reads exactly like a guard that
        -- worked. This says the four sessions genuinely ran
        ut.expect(core_lock_fixture.g_racers_done).to_equal(c_racers);

        -- and the promise itself. create_lock reads the history and then inserts
        -- with nothing serialising the two, so this measures the outcome rather
        -- than a guarantee the code makes: four sessions released together, one of
        -- them ends up holding the object and the other three are refused
        ut.expect(core_lock_fixture.live_lock_count(core_lock_fixture.c_proc)).to_equal(1);
        ut.expect(core_lock_fixture.lock_count(core_lock_fixture.c_proc)).to_equal(1);
        ut.expect(newest_lock(core_lock_fixture.c_proc).locked_by).to_be_like('RACER%');
    END;

END;
/
