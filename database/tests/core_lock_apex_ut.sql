CREATE OR REPLACE PACKAGE BODY core_lock_apex_ut AS

    FUNCTION app_comment
    RETURN VARCHAR2
    AS
        v_comment           apex_applications.lock_comment%TYPE;
    BEGIN
        SELECT MAX(a.lock_comment)
        INTO v_comment
        FROM apex_applications a
        WHERE a.application_id = c_app;
        --
        RETURN v_comment;
    END;



    --
    -- Release every lock on the fixture application as whoever holds it, through the
    -- same procedures under test, so a broken unlock shows up here as well
    --
    PROCEDURE release_all
    AS
    BEGIN
        FOR c IN (
            SELECT
                p.page_id,
                p.locked_by
            FROM apex_application_locked_pages p
            WHERE p.application_id = c_app
        ) LOOP
            core_lock.unlock(in_app_id => c_app, in_page_id => c.page_id, in_locked_by => c.locked_by);
        END LOOP;
        --
        IF core_lock.get_lock(c_app) IS NOT NULL THEN
            core_lock.unlock(in_app_id => c_app, in_locked_by => core_lock.get_lock(c_app));
        END IF;
    END;



    PROCEDURE before_each
    AS
    BEGIN
        release_all();
        core_lock_fixture.act_as(core_lock_fixture.c_alice);
    END;



    PROCEDURE after_each
    AS
    BEGIN
        release_all();
        --
        ut.expect(core_lock.get_lock(c_app)).to_be_null();
        ut.expect(core_lock.get_lock(c_app, 1)).to_be_null();
        ut.expect(core_lock.get_lock(c_app, 2)).to_be_null();
    END;



    PROCEDURE test_app#lock_takes_the_lock_as_the_session_user
    AS
    BEGIN
        core_lock.create_lock(in_app_id => c_app, in_comment => 'Deploy 1');
        --
        ut.expect(core_lock.get_lock(c_app)).to_equal(core_lock_fixture.c_alice);
        ut.expect(app_comment()).to_equal('Deploy 1');
    END;



    PROCEDURE test_app#lock_for_a_named_owner
    AS
    BEGIN
        -- a deploy locks for its own account, cleaned like every other name
        core_lock.create_lock(in_app_id => c_app, in_locked_by => 'bob');
        --
        ut.expect(core_lock.get_lock(c_app)).to_equal(core_lock_fixture.c_bob);
    END;



    PROCEDURE test_app#same_owner_replaces_the_comment
    AS
    BEGIN
        core_lock.create_lock(in_app_id => c_app, in_comment => 'Deploy 1');
        core_lock.create_lock(in_app_id => c_app, in_comment => 'Deploy 2');
        --
        ut.expect(core_lock.get_lock(c_app)).to_equal(core_lock_fixture.c_alice);
        ut.expect(app_comment()).to_equal('Deploy 2');
    END;



    PROCEDURE test_app#another_owner_is_refused
    AS
        v_error             VARCHAR2(4000);
    BEGIN
        core_lock.create_lock(in_app_id => c_app);
        core_lock_fixture.act_as(core_lock_fixture.c_bob);
        --
        BEGIN
            core_lock.create_lock(in_app_id => c_app);
        EXCEPTION
        WHEN core_lock.app_exception THEN
            v_error := SQLERRM;
        END;
        --
        ut.expect(v_error).to_be_like('%APP_LOCK_ERROR: APP_LOCKED_BY `ALICE` [9901]%');
        ut.expect(core_lock.get_lock(c_app)).to_equal(core_lock_fixture.c_alice);
    END;



    PROCEDURE test_app#a_non_developer_is_refused
    AS
        v_error             VARCHAR2(4000);
    BEGIN
        core_lock_fixture.act_as('MALLORY');
        --
        BEGIN
            core_lock.create_lock(in_app_id => c_app);
        EXCEPTION
        WHEN core_lock.app_exception THEN
            v_error := SQLERRM;
        END;
        --
        ut.expect(v_error).to_be_like('%USER_ERROR: NOT_A_WORKSPACE_DEVELOPER `MALLORY`%');
        ut.expect(core_lock.get_lock(c_app)).to_be_null();
    END;



    PROCEDURE test_app#other_apex_errors_keep_their_text
    AS
        v_error             VARCHAR2(4000);
    BEGIN
        BEGIN
            core_lock.create_lock(in_app_id => c_app, in_comment => RPAD('x', 5000, 'x'));
        EXCEPTION
        WHEN core_lock.app_exception THEN
            v_error := SQLERRM;
        END;
        --
        ut.expect(v_error).to_be_like('%p_lock_comment%');
        ut.expect(v_error).not_to_be_like('%NOT_A_WORKSPACE_DEVELOPER%');
        ut.expect(core_lock.get_lock(c_app)).to_be_null();
    END;



    PROCEDURE test_app#an_unknown_app_is_refused
    AS
        v_error             VARCHAR2(4000);
    BEGIN
        BEGIN
            core_lock.create_lock(in_app_id => c_app + 1);
        EXCEPTION
        WHEN core_lock.app_exception THEN
            v_error := SQLERRM;
        END;
        --
        ut.expect(v_error).to_be_like('%APP_ERROR: APP_NOT_FOUND [9902]%');
    END;



    PROCEDURE test_app#unlock_releases_the_own_lock
    AS
    BEGIN
        core_lock.create_lock(in_app_id => c_app);
        core_lock.unlock(in_app_id => c_app);
        --
        ut.expect(core_lock.get_lock(c_app)).to_be_null();
    END;



    PROCEDURE test_app#unlock_never_releases_another_owner
    AS
        v_error             VARCHAR2(4000);
    BEGIN
        core_lock.create_lock(in_app_id => c_app);
        core_lock_fixture.act_as(core_lock_fixture.c_bob);
        --
        BEGIN
            core_lock.unlock(in_app_id => c_app);
        EXCEPTION
        WHEN core_lock.app_exception THEN
            v_error := SQLERRM;
        END;
        --
        ut.expect(v_error).to_be_like('%APP_LOCK_ERROR: APP_LOCKED_BY `ALICE` [9901]%');
        ut.expect(core_lock.get_lock(c_app)).to_equal(core_lock_fixture.c_alice);
    END;



    PROCEDURE test_app#unlock_leaves_a_free_app_quietly
    AS
    BEGIN
        core_lock.unlock(in_app_id => c_app);
        --
        ut.expect(core_lock.get_lock(c_app)).to_be_null();
    END;



    PROCEDURE test_app#get_lock_names_the_owner
    AS
    BEGIN
        ut.expect(core_lock.get_lock(c_app)).to_be_null();
        --
        core_lock.create_lock(in_app_id => c_app, in_locked_by => core_lock_fixture.c_bob);
        --
        ut.expect(core_lock.get_lock(c_app)).to_equal(core_lock_fixture.c_bob);
    END;



    PROCEDURE test_page#lock_takes_the_lock_as_the_session_user
    AS
    BEGIN
        core_lock.create_lock(in_app_id => c_app, in_page_id => 1, in_comment => 'Editing');
        --
        ut.expect(core_lock.get_lock(c_app, 1)).to_equal(core_lock_fixture.c_alice);
        ut.expect(core_lock.get_lock(c_app, 2)).to_be_null();
        ut.expect(core_lock.get_lock(c_app)).to_be_null();
    END;



    PROCEDURE test_page#another_owner_is_refused
    AS
        v_error             VARCHAR2(4000);
    BEGIN
        core_lock.create_lock(in_app_id => c_app, in_page_id => 1);
        core_lock_fixture.act_as(core_lock_fixture.c_bob);
        --
        BEGIN
            core_lock.create_lock(in_app_id => c_app, in_page_id => 1);
        EXCEPTION
        WHEN core_lock.app_exception THEN
            v_error := SQLERRM;
        END;
        --
        ut.expect(v_error).to_be_like('%PAGE_LOCK_ERROR: PAGE_LOCKED_BY `ALICE` [9901:1]%');
        ut.expect(core_lock.get_lock(c_app, 1)).to_equal(core_lock_fixture.c_alice);
    END;



    PROCEDURE test_page#an_app_held_by_another_blocks_it
    AS
        v_error             VARCHAR2(4000);
    BEGIN
        core_lock.create_lock(in_app_id => c_app);
        core_lock_fixture.act_as(core_lock_fixture.c_bob);
        --
        BEGIN
            core_lock.create_lock(in_app_id => c_app, in_page_id => 1);
        EXCEPTION
        WHEN core_lock.app_exception THEN
            v_error := SQLERRM;
        END;
        --
        ut.expect(v_error).to_be_like('%APP_LOCK_ERROR: APP_LOCKED_BY `ALICE` [9901]%');
        ut.expect(core_lock.get_lock(c_app, 1)).to_be_null();
    END;



    PROCEDURE test_page#a_missing_page_is_refused
    AS
        v_error             VARCHAR2(4000);
    BEGIN
        BEGIN
            core_lock.create_lock(in_app_id => c_app, in_page_id => 99);
        EXCEPTION
        WHEN core_lock.app_exception THEN
            v_error := SQLERRM;
        END;
        --
        ut.expect(v_error).to_be_like('%PAGE_LOCK_ERROR: PAGE_NOT_LOCKED [9901:99]%');
    END;



    PROCEDURE test_page#the_app_user_is_handed_back
    AS
    BEGIN
        APEX_CUSTOM_AUTH.SET_USER(p_user => 'CAROL');
        --
        core_lock.create_lock(in_app_id => c_app, in_page_id => 1);
        core_lock.unlock(in_app_id => c_app, in_page_id => 1);
        --
        ut.expect(V('APP_USER')).to_equal('CAROL');
        --
        APEX_CUSTOM_AUTH.SET_USER(p_user => NULL);
    END;



    PROCEDURE test_page#a_failed_call_hands_the_app_user_back
    AS
        v_error             VARCHAR2(4000);
    BEGIN
        APEX_CUSTOM_AUTH.SET_USER(p_user => 'CAROL');
        --
        BEGIN
            core_lock.create_lock(in_app_id => c_app, in_page_id => 1, in_comment => RPAD('x', 5000, 'x'));
        EXCEPTION
        WHEN core_lock.app_exception THEN
            v_error := SQLERRM;
        END;
        --
        ut.expect(v_error).to_be_like('%LOCK_COMMENT%');
        ut.expect(V('APP_USER')).to_equal('CAROL');
        ut.expect(core_lock.get_lock(c_app, 1)).to_be_null();
        --
        APEX_CUSTOM_AUTH.SET_USER(p_user => NULL);
    END;



    PROCEDURE test_page#same_owner_keeps_the_lock
    AS
    BEGIN
        core_lock.create_lock(in_app_id => c_app, in_page_id => 1);
        core_lock.create_lock(in_app_id => c_app, in_page_id => 1);
        --
        ut.expect(core_lock.get_lock(c_app, 1)).to_equal(core_lock_fixture.c_alice);
    END;



    PROCEDURE test_page#unlock_leaves_a_free_page_quietly
    AS
    BEGIN
        core_lock.unlock(in_app_id => c_app, in_page_id => 1);
        --
        ut.expect(core_lock.get_lock(c_app, 1)).to_be_null();
    END;



    PROCEDURE test_page#unlock_releases_the_own_lock
    AS
    BEGIN
        core_lock.create_lock(in_app_id => c_app, in_page_id => 1);
        core_lock.unlock(in_app_id => c_app, in_page_id => 1);
        --
        ut.expect(core_lock.get_lock(c_app, 1)).to_be_null();
    END;



    PROCEDURE test_page#unlock_never_releases_another_owner
    AS
        v_error             VARCHAR2(4000);
    BEGIN
        core_lock.create_lock(in_app_id => c_app, in_page_id => 1);
        core_lock_fixture.act_as(core_lock_fixture.c_bob);
        --
        BEGIN
            core_lock.unlock(in_app_id => c_app, in_page_id => 1);
        EXCEPTION
        WHEN core_lock.app_exception THEN
            v_error := SQLERRM;
        END;
        --
        ut.expect(v_error).to_be_like('%PAGE_LOCK_ERROR: PAGE_LOCKED_BY `ALICE` [9901:1]%');
        ut.expect(core_lock.get_lock(c_app, 1)).to_equal(core_lock_fixture.c_alice);
    END;



    PROCEDURE test_page#get_lock_names_the_owner
    AS
    BEGIN
        ut.expect(core_lock.get_lock(c_app, 2)).to_be_null();
        --
        core_lock.create_lock(in_app_id => c_app, in_page_id => 2);
        --
        ut.expect(core_lock.get_lock(c_app, 2)).to_equal(core_lock_fixture.c_alice);
        ut.expect(core_lock.get_lock(c_app, 1)).to_be_null();
    END;

END;
/
