CREATE OR REPLACE PACKAGE BODY core_lock_anon_ut AS

    -- what the locksmith tells a session it cannot name
    c_expected_message  CONSTANT VARCHAR2(100) := 'USER_ERROR: USE_PROXY_USER_OR_SET_CLIENT_ID';



    FUNCTION probe_exists (
        in_object_name      VARCHAR2
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



    PROCEDURE before_all
    AS
    BEGIN
        core_lock_fixture.locksmith(FALSE);
        core_lock_fixture.teardown();
    END;



    PROCEDURE before_each
    AS
    BEGIN
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



    --
    -- Every test below strips the session as its first act, and it has to happen
    -- here rather than in before_each: utPLSQL sets the client identifier to the
    -- name of the test it is about to run, so a session stripped in before_each is
    -- named again (after CORE_LOCK_ANON_UT, of all things) by the time the body
    -- starts. It is the ladder's second rung answering, which is the function
    -- working exactly as designed on a name it was never meant to be handed.
    --

    PROCEDURE test_anon#the_session_names_nobody
    AS
    BEGIN
        core_lock_fixture.act_as_nobody();

        -- the control for the other four, and the reason this suite is tagged out
        -- of the ordinary run. get_user falls back to the session's IP address, so
        -- on any connection over TCP it answers something and every refusal below
        -- stops happening, leaving a suite that passes its teardown assertions and
        -- reads green while testing nothing at all
        ut.expect(SYS_CONTEXT('USERENV', 'IP_ADDRESS')).to_be_null();
        ut.expect(core_lock.get_user()).to_be_null();
    END;



    --
    -- Both refusal tests below assert the message and not just the error code, and
    -- the reason is measured rather than assumed. core_locks.locked_by is NOT NULL,
    -- so with the guards taken out the row simply fails to insert, create_lock's
    -- WHEN OTHERS turns that into the same catalogue code, and the compile is
    -- refused and rolled back exactly as it is now. A test pinned to the code alone
    -- passes on a database where nothing checks who you are at all, which is the
    -- one state it exists to rule out.
    --

    PROCEDURE test_anon#a_compile_is_refused_and_says_what_to_do
    AS
        v_error             VARCHAR2(4000);
    BEGIN
        core_lock_fixture.act_as_nobody();
        core_lock_fixture.locksmith(TRUE);
        --
        BEGIN
            core_lock_fixture.compile_probe('PROCEDURE', 1);
        EXCEPTION
        WHEN OTHERS THEN
            -- the whole stack, not SQLERRM, and not %throws either: a refusal raised
            -- inside a DDL trigger surfaces as ORA-04088 "error during execution of
            -- trigger" and the catalogue code that says why sits underneath it, so
            -- both of the shorter forms would pin the wrapper and pass for any
            -- failure at all, a probe that would not compile included
            v_error := DBMS_UTILITY.FORMAT_ERROR_STACK;
        END;

        -- the code is built from the constant rather than typed, so renumbering the
        -- catalogue moves this assertion with it instead of leaving it green against
        -- an error nothing raises any more
        ut.expect(v_error).to_be_like('%ORA-' || LTRIM(TO_CHAR(core_lock.c_app_exception_code), '-') || '%');

        -- and the message, because the code alone is what a second developer gets
        -- when they are merely too late. This one has to name the fix: the developer
        -- reading it has no lock to wait out and no colleague to ask, their session
        -- is anonymous, and nothing on their screen makes that obvious
        ut.expect(v_error).to_be_like('%' || c_expected_message || '%');
    END;



    PROCEDURE test_anon#the_refused_compile_leaves_nothing_behind
    AS
        v_error             VARCHAR2(4000);
    BEGIN
        core_lock_fixture.act_as_nobody();
        core_lock_fixture.locksmith(TRUE);
        --
        BEGIN
            core_lock_fixture.compile_probe('PROCEDURE', 1);
        EXCEPTION
        WHEN OTHERS THEN
            v_error := DBMS_UTILITY.FORMAT_ERROR_STACK;
        END;

        -- the refusal is raised from an AFTER DDL trigger, so it takes the statement
        -- down with it. A guard that let the compile stand and only skipped the lock
        -- row would be worse than no guard: the object would have moved with nobody
        -- named as having moved it
        ut.expect(core_lock_fixture.lock_count()).to_equal(0);
        ut.expect(probe_exists(core_lock_fixture.c_proc)).to_equal(0);

        -- asserted here too, so this test is about the guard rolling the compile
        -- back and not about any failure at all doing it. Without this line a
        -- database that refuses the insert for some unrelated reason leaves exactly
        -- the same empty schema behind, and this test calls that a working guard
        ut.expect(v_error).to_be_like('%' || c_expected_message || '%');
    END;



    PROCEDURE test_anon#naming_the_session_lets_the_compile_through
    AS
    BEGIN
        core_lock_fixture.locksmith(TRUE);

        -- the same compile as the three tests above, on the same connection, with
        -- one thing changed. Without this the suite cannot tell a working guard
        -- from a broken trigger, a probe that would not compile, or a connection
        -- that refuses every piece of DDL for a reason of its own
        core_lock_fixture.act_as(core_lock_fixture.c_alice);
        --
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        --
        ut.expect(core_lock_fixture.lock_count(core_lock_fixture.c_proc)).to_equal(1);
        ut.expect(probe_exists(core_lock_fixture.c_proc)).to_equal(1);
    END;

END;
/
