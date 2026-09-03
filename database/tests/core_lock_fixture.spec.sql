CREATE OR REPLACE PACKAGE core_lock_fixture AS

    --
    -- Actor, probe objects and teardown ledger shared by the CORE_LOCKS suites.
    --
    -- Two suites need the same three things (a session that names somebody, a
    -- handful of throwaway objects to lock, and a way to put the lock history
    -- back the way it was found), so they live here rather than growing twice.
    --
    -- Every suite here runs under %rollback(manual). create_lock, extend_lock,
    -- unlock and purge_locks all carry PRAGMA AUTONOMOUS_TRANSACTION and commit
    -- inside themselves, and the integration suite runs DDL, which commits too.
    -- There is no savepoint left for utPLSQL to roll back to, so the fixture
    -- commits on purpose and this package owns the cleanup.
    --



    --
    -- Probe object names. None of these may begin with CORE_LOCK: the locksmith
    -- trigger skips ORA_DICT_OBJ_NAME LIKE 'CORE_LOCK%' so the feature cannot
    -- lock itself out, and a probe caught by that rule would leave every
    -- integration test asserting against a lock nobody ever took.
    --
    c_pkg                   CONSTANT VARCHAR2(128) := 'CLUT_PKG';
    c_proc                  CONSTANT VARCHAR2(128) := 'CLUT_PROC';
    c_fn                    CONSTANT VARCHAR2(128) := 'CLUT_FN';
    c_view                  CONSTANT VARCHAR2(128) := 'CLUT_VW';
    c_trigger               CONSTANT VARCHAR2(128) := 'CLUT_TRG';
    c_table                 CONSTANT VARCHAR2(128) := 'CLUT_TAB';
    c_mview                 CONSTANT VARCHAR2(128) := 'CLUT_MV';

    -- a view whose text runs past the 32k a varchar2 holds, which is the whole
    -- reason view_query reads the LONG in chunks and object_body walks lines
    -- instead of cutting the CLOB
    c_bigview               CONSTANT VARCHAR2(128) := 'CLUT_BIGVW';

    -- a type the locksmith deliberately does not track, for the test that proves
    -- the object-type filter is a filter and not a formality
    c_sequence              CONSTANT VARCHAR2(128) := 'CLUT_SEQ';

    -- the one probe that IS named CORE_LOCK%, for the test that proves the
    -- self-exclusion works. It is a PROCEDURE created by a CREATE, both of which
    -- the locksmith tracks, so its name is the only reason no lock is taken
    c_own                   CONSTANT VARCHAR2(128) := 'CORE_LOCK_PROBE';

    -- the two names the suites act under, so a takeover is a real second person
    c_alice                 CONSTANT VARCHAR2(128) := 'ALICE';
    c_bob                   CONSTANT VARCHAR2(128) := 'BOB';

    -- what teardown could not remove, and why. The last test of each suite
    -- asserts both are clean: a teardown that swallows its own failure is the
    -- appearance of cleanup, and committed fixtures make the leftovers permanent
    g_residue               PLS_INTEGER := 0;
    g_teardown_error        VARCHAR2(4000);



    --
    -- Name the session. Everything core_lock decides about ownership comes from
    -- the session, so the actor is arranged explicitly and never inherited from
    -- whoever happens to run the suite.
    --
    PROCEDURE act_as (
        in_name             VARCHAR2
    );



    --
    -- The DDL for one probe object. Version 1 and version 2 differ inside the
    -- body, never only in the CREATE header, because object_body strips that header
    -- before hashing, so two versions that differ only there would fingerprint
    -- identically and every hash test would pass without testing anything.
    --
    FUNCTION probe_ddl (
        in_object_type      VARCHAR2,
        in_version          PLS_INTEGER := 1
    )
    RETURN CLOB;



    PROCEDURE compile_probe (
        in_object_type      VARCHAR2,
        in_version          PLS_INTEGER := 1
    );



    PROCEDURE drop_probes;



    PROCEDURE clear_locks;



    --
    -- Move a lock row's clock. The lock window, the rebook window and the
    -- hash-check window are package constants in core_lock, so a test cannot
    -- wait them out or set them; it ages the row instead.
    --
    PROCEDURE age_lock (
        in_object_name      VARCHAR2    := NULL,
        in_expire_at        DATE        := NULL,
        in_locked_at        DATE        := NULL
    );



    PROCEDURE locksmith (
        in_enabled          BOOLEAN
    );



    FUNCTION locksmith_status
    RETURN VARCHAR2;



    FUNCTION lock_count (
        in_object_name      VARCHAR2    := NULL,
        in_object_type      VARCHAR2    := NULL
    )
    RETURN PLS_INTEGER;



    --
    -- Drop the probes, empty the history, and count whatever survived instead of
    -- reporting success. Leaves first, then the rows that referenced them.
    --
    PROCEDURE teardown;

END;
/
