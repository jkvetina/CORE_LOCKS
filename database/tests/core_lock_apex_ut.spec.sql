CREATE OR REPLACE PACKAGE core_lock_apex_ut AS

    --
    -- APEX application and page locks, against the fixture application 9901 in the
    -- CLUT workspace, whose developers are ALICE and BOB.
    --
    -- Needs APEX 26.2 and the fixture from create_test_apex.sql and install_apex.sql,
    -- so it carries its own tag; run.sql excludes it and run_apex.sql asks for it:
    --
    --     database/tests/run.sh -c <connect> --apex
    --
    -- rollback: every lock call is autonomous and commits inside itself, so the
    -- suite releases whatever a test left behind
    -- %suite(core_lock APEX application and page locks)
    -- %suitepath(core_locks.apex)
    -- %tags(apex)
    -- %rollback(manual)
    -- %beforeeach(before_each)
    -- %aftereach(after_each)

    c_app                   CONSTANT NUMBER := 9901;

    PROCEDURE before_each;

    PROCEDURE after_each;



    -- %test(create_lock takes the application lock as the session user)
    PROCEDURE test_app#lock_takes_the_lock_as_the_session_user;

    -- %test(create_lock locks for a named owner, cleaned like any other name)
    PROCEDURE test_app#lock_for_a_named_owner;

    -- %test(create_lock again by the same owner replaces the comment)
    PROCEDURE test_app#same_owner_replaces_the_comment;

    -- %test(create_lock refuses an application another developer holds)
    PROCEDURE test_app#another_owner_is_refused;

    -- %test(create_lock refuses an owner who is no developer of the workspace)
    PROCEDURE test_app#a_non_developer_is_refused;

    -- %test(create_lock passes any other APEX refusal through in its own words)
    PROCEDURE test_app#other_apex_errors_keep_their_text;

    -- %test(create_lock refuses an application it cannot see)
    PROCEDURE test_app#an_unknown_app_is_refused;

    -- %test(unlock releases the owner's own application lock)
    PROCEDURE test_app#unlock_releases_the_own_lock;

    -- %test(unlock never releases another developer's application lock)
    PROCEDURE test_app#unlock_never_releases_another_owner;

    -- %test(unlock leaves a free application quietly)
    PROCEDURE test_app#unlock_leaves_a_free_app_quietly;

    -- %test(get_lock names the application owner, NULL when free)
    PROCEDURE test_app#get_lock_names_the_owner;

    -- %test(create_lock with a page takes the page lock as the session user)
    PROCEDURE test_page#lock_takes_the_lock_as_the_session_user;

    -- %test(create_lock refuses a page another developer holds)
    PROCEDURE test_page#another_owner_is_refused;

    -- %test(create_lock refuses a page whose application another developer holds)
    PROCEDURE test_page#an_app_held_by_another_blocks_it;

    -- %test(create_lock refuses a page that does not exist)
    PROCEDURE test_page#a_missing_page_is_refused;

    -- %test(create_lock hands the session its own APP_USER back)
    PROCEDURE test_page#the_app_user_is_handed_back;

    -- %test(create_lock hands APP_USER back even when the call fails)
    PROCEDURE test_page#a_failed_call_hands_the_app_user_back;

    -- %test(create_lock again by the same owner keeps the page lock)
    PROCEDURE test_page#same_owner_keeps_the_lock;

    -- %test(unlock leaves a free page quietly)
    PROCEDURE test_page#unlock_leaves_a_free_page_quietly;

    -- %test(unlock releases the owner's own page lock)
    PROCEDURE test_page#unlock_releases_the_own_lock;

    -- %test(unlock never releases another developer's page lock)
    PROCEDURE test_page#unlock_never_releases_another_owner;

    -- %test(get_lock names the page owner, NULL when free)
    PROCEDURE test_page#get_lock_names_the_owner;

END;
/
