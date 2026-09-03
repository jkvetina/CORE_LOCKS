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

    -- %test(a lock booked by hand fingerprints the same object as one taken by a compile)
    PROCEDURE test_locksmith#a_hand_lock_matches_a_compile;

    -- %test(a compile over somebody else's changed object is refused and rolled back)
    PROCEDURE test_locksmith#a_third_party_edit_is_refused_and_rolled_back;

END;
/
