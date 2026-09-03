CREATE OR REPLACE PACKAGE core_lock_proxy_ut AS

    --
    -- The one source of ownership that outranks everything else, and the one no
    -- session can arrange for itself.
    --
    -- get_user asks for SYS_CONTEXT('USERENV', 'PROXY_USER') first, because the
    -- database authenticated that person and nothing else on the ladder did. It is
    -- set at connect time and never afterwards, so these tests only mean anything
    -- when the suite is run through a proxy connection:
    --
    --     database/tests/run.sh -c <connect> -x 'CLUT_PROXY[CORE_LOCKS]/clut_proxy@<host>/<service>'
    --
    -- That is why they carry their own tag. run.sql excludes it, so an ordinary run
    -- never reports these as passing on a connection where PROXY_USER is empty, and
    -- run_proxy.sql asks for the tag by name and fails when it finds no tests.
    --
    -- rollback: create_lock is autonomous and commits inside itself, and the
    -- probe compile is DDL, which commits too. There is no savepoint left for
    -- utPLSQL to roll back to, so the fixture owns the cleanup here as everywhere
    -- %suite(core_lock through a proxy user)
    -- %suitepath(core_locks.proxy)
    -- %tags(proxy)
    -- %rollback(manual)
    -- %beforeall(before_all)
    -- %beforeeach(before_each)
    -- %aftereach(after_each)
    -- %afterall(after_all)

    PROCEDURE before_all;

    PROCEDURE before_each;

    PROCEDURE after_each;

    PROCEDURE after_all;



    -- %test(the suite really is connected through a proxy)
    PROCEDURE test_proxy#the_connection_is_a_proxy_connection;

    -- %test(the proxy user is the name the lock would carry)
    PROCEDURE test_proxy#the_proxy_user_names_the_owner;

    -- %test(the proxy user outranks a client identifier saying somebody else)
    PROCEDURE test_proxy#the_proxy_user_outranks_the_identifier;

    -- %test(a lock booked by hand is owned by the proxy user)
    PROCEDURE test_proxy#a_hand_lock_is_owned_by_the_proxy_user;

    -- %test(a lock opened by a compile is owned by the proxy user)
    PROCEDURE test_proxy#a_compile_is_owned_by_the_proxy_user;

END;
/
