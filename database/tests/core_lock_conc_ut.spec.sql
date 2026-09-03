CREATE OR REPLACE PACKAGE core_lock_conc_ut AS

    --
    -- What the lock does when there is more than one session, which is the only
    -- situation it exists for.
    --
    -- Every other suite here runs in one session, and a session reading back rows
    -- it committed itself cannot tell a working lock from a package variable. The
    -- tests below hand the work to a scheduler job, which runs in a slave session
    -- with its own SID and its own transaction, so a refusal has to travel between
    -- two real sessions to be seen at all.
    --
    -- rollback: a second session cannot see anything this one has not committed,
    -- so every fixture row here is committed on purpose and the lock rows the
    -- other session writes are its own. There is nothing for utPLSQL to roll back
    -- and the fixture owns the cleanup, jobs included
    -- %suite(core_lock across sessions)
    -- %suitepath(core_locks.concurrency)
    -- %tags(concurrency)
    -- %rollback(manual)
    -- %beforeall(before_all)
    -- %beforeeach(before_each)
    -- %aftereach(after_each)
    -- %afterall(after_all)

    PROCEDURE before_all;

    PROCEDURE before_each;

    PROCEDURE after_each;

    PROCEDURE after_all;



    -- %test(a lock another session is holding refuses this one)
    PROCEDURE test_conc#another_sessions_lock_refuses_this_one;

    -- %test(a lock this session is holding refuses another one, and it is told why)
    PROCEDURE test_conc#this_sessions_lock_refuses_another_one;

    -- %test(a release here lets the next session have the object)
    PROCEDURE test_conc#a_release_here_frees_the_object_over_there;

    -- %test(sessions released together leave exactly one holder)
    PROCEDURE test_conc#a_race_leaves_one_holder;

END;
/
