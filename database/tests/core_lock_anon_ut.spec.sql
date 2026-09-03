CREATE OR REPLACE PACKAGE core_lock_anon_ut AS

    --
    -- The locksmith's refusal of a session that names nobody.
    --
    -- get_user ends its ladder on SYS_CONTEXT('USERENV', 'IP_ADDRESS'), which every
    -- connection over TCP carries, so on the ordinary run and on the proxy run the
    -- function can never answer NULL and the refusal above it can never fire. The
    -- one connection that does reach it is a local one (IPC or bequeath), where
    -- there is no address to fall back to and the OS user is the database's own
    -- account, which clean_user reduces to nobody like any other service account.
    --
    -- Tagged out of run.sql for the same reason the proxy suite is: on the ordinary
    -- connection these tests would be failing for the connection's sake and not the
    -- product's. run_anon.sql asks for the tag by name.
    --
    -- rollback: the tests here run DDL, and DDL commits. There is no savepoint for
    -- utPLSQL to roll back to, so the fixture commits and cleans up after itself
    -- %suite(core_lock on a session that names nobody)
    -- %suitepath(core_locks.anon)
    -- %tags(anon)
    -- %rollback(manual)
    -- %beforeall(before_all)
    -- %beforeeach(before_each)
    -- %aftereach(after_each)
    -- %afterall(after_all)

    PROCEDURE before_all;

    PROCEDURE before_each;

    PROCEDURE after_each;

    PROCEDURE after_all;



    -- %test(the session really does name nobody)
    PROCEDURE test_anon#the_session_names_nobody;

    -- no %throws: the refusal comes out of a DDL trigger, so what reaches the
    -- caller is ORA-04088 with the catalogue code underneath it, and an annotation
    -- naming either one would pass for any failed compile at all
    -- %test(a compile from a nameless session is refused, and told how to fix it)
    PROCEDURE test_anon#a_compile_is_refused_and_says_what_to_do;

    -- %test(nothing is locked and nothing is compiled when the session is refused)
    PROCEDURE test_anon#the_refused_compile_leaves_nothing_behind;

    -- %test(naming the session is all it takes for the same compile to be allowed)
    PROCEDURE test_anon#naming_the_session_lets_the_compile_through;

END;
/
