CREATE OR REPLACE PACKAGE BODY core_lock_proxy_ut AS

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
        core_lock_fixture.locksmith(FALSE);
        core_lock_fixture.teardown();
    END;



    PROCEDURE before_each
    AS
    BEGIN
        -- named as somebody else on purpose. Every test here would pass on an
        -- unnamed session by falling through to the proxy for want of anything
        -- better, and a ladder is only ordered if the rung above wins while the
        -- rung below is also answering
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
    END;



    PROCEDURE after_all
    AS
    BEGIN
        core_lock_fixture.locksmith(TRUE);
    END;



    PROCEDURE test_proxy#the_connection_is_a_proxy_connection
    AS
    BEGIN
        -- the control for the other four. Run this suite on an ordinary connection
        -- and PROXY_USER is empty, every assertion below falls back to whatever
        -- the session happens to offer, and the file reads as a passing proxy
        -- suite on a database with no proxy in it
        ut.expect(SYS_CONTEXT('USERENV', 'PROXY_USER')).to_equal(core_lock_fixture.c_proxy);
        ut.expect(SYS_CONTEXT('USERENV', 'SESSION_USER')).to_equal(USER);
    END;



    PROCEDURE test_proxy#the_proxy_user_names_the_owner
    AS
    BEGIN
        ut.expect(core_lock.get_user()).to_equal(core_lock_fixture.c_proxy);
    END;



    PROCEDURE test_proxy#the_proxy_user_outranks_the_identifier
    AS
    BEGIN
        core_lock_fixture.act_as('MALLORY');

        -- the session says one thing and the database knows another. A client
        -- identifier is whatever the client typed; a proxy user is who the
        -- database let in, and that is why it sits at the top of the ladder
        ut.expect(SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER')).to_equal('MALLORY');
        ut.expect(core_lock.get_user()).to_equal(core_lock_fixture.c_proxy);
    END;



    PROCEDURE test_proxy#a_hand_lock_is_owned_by_the_proxy_user
    AS
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        core_lock_fixture.clear_locks();
        --
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        --
        ut.expect(newest_lock(core_lock_fixture.c_proc).locked_by).to_equal(core_lock_fixture.c_proxy);
    END;



    PROCEDURE test_proxy#a_compile_is_owned_by_the_proxy_user
    AS
    BEGIN
        core_lock_fixture.locksmith(TRUE);
        core_lock_fixture.clear_locks();
        --
        core_lock_fixture.compile_probe('PROCEDURE', 1);

        -- the trigger path, where the name is decided inside a DDL event rather
        -- than by the caller. Same answer, because get_user is the one place
        -- either route asks
        ut.expect(newest_lock(core_lock_fixture.c_proc).locked_by).to_equal(core_lock_fixture.c_proxy);
    END;

END;
/
