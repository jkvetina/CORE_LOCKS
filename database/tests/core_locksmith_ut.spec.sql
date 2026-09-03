CREATE OR REPLACE PACKAGE core_locksmith_ut AS

    -- rollback: every test here runs DDL, and DDL commits. There is no savepoint
    -- for utPLSQL to roll back to, so the fixture commits and cleans up after itself
    -- %suite(core_locksmith DDL trigger)
    -- %suitepath(core_locks.locksmith)
    -- %tags(integration)
    -- %rollback(manual)
    -- %beforeall(before_all)
    -- %beforeeach(before_each)
    -- %aftereach(after_each)

    PROCEDURE before_all;

    PROCEDURE before_each;

    PROCEDURE after_each;



    -- %test(a compile opens a lock carrying the statement and its fingerprint)
    PROCEDURE test_locksmith#a_compile_opens_a_lock;

    -- %test(a second compile by the same developer extends the one lock)
    PROCEDURE test_locksmith#the_same_developer_extends_the_one_lock;

    -- %test(an ALTER COMPILE changes nothing, so it opens no lock)
    PROCEDURE test_locksmith#an_alter_compile_opens_no_lock;

    -- %test(the feature never locks its own objects out)
    PROCEDURE test_locksmith#core_lock_objects_are_never_locked;

    -- %test(an object type outside the tracked list is ignored)
    PROCEDURE test_locksmith#an_untracked_object_type_is_ignored;

    -- %test(an object a dependency scanner left behind is skipped by name)
    PROCEDURE test_locksmith#a_dependency_scanner_object_is_skipped;

    -- %test(a lock booked by hand fingerprints the same object as one taken by a compile)
    PROCEDURE test_locksmith#a_hand_lock_matches_a_compile;

    -- %test(a compile over somebody else's changed object is refused and rolled back)
    PROCEDURE test_locksmith#a_third_party_edit_is_refused_and_rolled_back;

    -- %test(a trigger compile opens a lock of its own)
    PROCEDURE test_locksmith#a_trigger_compile_opens_a_lock;

    -- %test(a materialized view compile opens a lock of its own)
    PROCEDURE test_locksmith#a_materialized_view_compile_opens_a_lock;

    -- %test(an ALTER that is not a compile is a change, so it opens a lock)
    PROCEDURE test_locksmith#an_alter_that_is_not_a_compile_opens_a_lock;

    -- %test(a view past the varchar limit fingerprints the same by hand)
    PROCEDURE test_locksmith#a_big_view_fingerprints_the_same_by_hand;

    -- %test(a drop is recorded rather than refused as somebody else's change)
    PROCEDURE test_locksmith#a_drop_is_recorded_not_refused;

    -- %test(the row a drop opens carries the source of what was dropped)
    PROCEDURE test_locksmith#a_drop_carries_the_last_source_forward;

    -- %test(a drop of an object somebody is holding is still refused)
    PROCEDURE test_locksmith#a_live_lock_still_refuses_a_drop;

END;
/
