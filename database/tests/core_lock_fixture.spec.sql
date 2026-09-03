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

    -- a dependency-scanner object, for the locksmith's other name-based skip. Built
    -- the same way c_own is and for the same reason: a PROCEDURE created by a
    -- CREATE, so both the tracked type and the tracked event are satisfied and the
    -- DEPSCAN$ prefix is the only thing keeping it out of the lock table. It must
    -- NOT begin with CORE_LOCK, or the self-exclusion would answer first and this
    -- probe would be proving that rule a second time instead of this one
    c_depscan               CONSTANT VARCHAR2(128) := 'DEPSCAN$CLUT';

    -- the two names the suites act under, so a takeover is a real second person
    c_alice                 CONSTANT VARCHAR2(128) := 'ALICE';
    c_bob                   CONSTANT VARCHAR2(128) := 'BOB';

    -- the account the proxy suite connects through. It owns nothing and may do
    -- nothing but connect; its whole job is to make SYS_CONTEXT('USERENV',
    -- 'PROXY_USER') answer, which no session can arrange for itself
    c_proxy                 CONSTANT VARCHAR2(128) := 'CLUT_PROXY';

    -- the scheduler job the concurrency suite borrows a second session from
    c_job                   CONSTANT VARCHAR2(128) := 'CLUT_JOB';

    -- what teardown could not remove, and why. The last test of each suite
    -- asserts both are clean: a teardown that swallows its own failure is the
    -- appearance of cleanup, and committed fixtures make the leftovers permanent
    g_residue               PLS_INTEGER := 0;
    g_teardown_error        VARCHAR2(4000);

    -- how the last borrowed session ended. SUCCEEDED or FAILED as the scheduler
    -- saw it, plus the error stack it recorded, which is where a refusal raised
    -- in that other session is legible from this one
    g_job_status            VARCHAR2(30);
    g_job_error             VARCHAR2(4000);

    -- how many racers actually ran. Asserted alongside every claim about the
    -- outcome of a race, because "one holder" is also what you get when nothing
    -- raced at all, and that reads exactly like the guard working
    g_racers_done           PLS_INTEGER := 0;



    --
    -- Name the session. Everything core_lock decides about ownership comes from
    -- the session, so the actor is arranged explicitly and never inherited from
    -- whoever happens to run the suite.
    --
    PROCEDURE act_as (
        in_name             VARCHAR2
    );



    --
    -- Take every name off the session, so get_user has to answer from the
    -- connection alone. The counterpart of act_as and arranged just as explicitly:
    -- a session that merely has not been named yet looks identical to one that was
    -- stripped on purpose, and the first survives only until some earlier test
    -- names it and utPLSQL runs them all in the one session.
    --
    PROCEDURE act_as_nobody;



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
    -- Run one PL/SQL block in a session that is not this one, and wait for it.
    --
    -- Everything core_lock commits, it commits autonomously, and a single session
    -- reading back its own committed rows cannot tell a working lock from a
    -- variable. A scheduler job runs in a slave session with its own SID, its own
    -- transaction and no client identifier until it sets one, which is as close to
    -- a second developer as one connection can get.
    --
    -- Leaves g_job_status and g_job_error describing how it went.
    --
    PROCEDURE in_other_session (
        in_body             VARCHAR2,
        in_wait_seconds     NUMBER      := 30
    );



    --
    -- Arrange in_count sessions to call create_lock on the same object at the same
    -- moment. They share one start time rather than being launched one after
    -- another, because six calls in a row is not a race and would pass whatever
    -- the guard did.
    --
    PROCEDURE start_racers (
        in_count            PLS_INTEGER,
        in_object_type      VARCHAR2,
        in_object_name      VARCHAR2,
        in_delay_seconds    PLS_INTEGER := 2
    );



    PROCEDURE await_racers (
        in_count            PLS_INTEGER,
        in_wait_seconds     NUMBER      := 60
    );



    PROCEDURE drop_jobs;



    FUNCTION live_lock_count (
        in_object_name      VARCHAR2    := NULL
    )
    RETURN PLS_INTEGER;



    --
    -- Drop the probes, empty the history, and count whatever survived instead of
    -- reporting success. Leaves first, then the rows that referenced them.
    --
    PROCEDURE teardown;

END;
/
