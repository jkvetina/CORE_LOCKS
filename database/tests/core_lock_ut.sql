CREATE OR REPLACE PACKAGE BODY core_lock_ut AS

    --
    -- The newest lock row for an object, which is the row every assertion here
    -- is about. create_lock keeps history, so MAX(lock_id) rather than the only
    -- row: a takeover leaves the old row in place on purpose.
    --
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



    --
    -- A history row written straight into the table. The purge tests need rows
    -- older than the retention window, and there is no way to age one through
    -- the API. locked_at is set to SYSDATE at insert and never moves.
    --
    PROCEDURE seed_history (
        in_object_name      core_locks.object_name%TYPE,
        in_locked_at        DATE,
        in_expire_at        DATE            := NULL,
        in_payload          VARCHAR2        := 'PAYLOAD',
        in_hash             VARCHAR2        := 'DEADBEEF'
    )
    AS
    BEGIN
        INSERT INTO core_locks (
            object_owner,
            object_type,
            object_name,
            locked_by,
            locked_at,
            expire_at,
            counter,
            object_payload,
            object_hash
        )
        VALUES (
            USER,
            'PROCEDURE',
            in_object_name,
            core_lock_fixture.c_alice,
            in_locked_at,
            in_expire_at,
            1,
            TO_CLOB(in_payload),
            in_hash
        );
        --
        COMMIT;
    END;



    PROCEDURE before_all
    AS
    BEGIN
        -- the locksmith is schema wide, so a probe compiled with it on would open
        -- a lock of its own and every row count below would be about the wrong row
        core_lock_fixture.locksmith(FALSE);
        core_lock_fixture.teardown();
    END;



    PROCEDURE before_each
    AS
    BEGIN
        core_lock_fixture.act_as(core_lock_fixture.c_alice);

        -- get_user reads client info as one of its fallbacks and one test sets it.
        -- It survives a commit and belongs to the session, not to the transaction,
        -- so a leftover would answer for a later test that meant to ask the OS
        DBMS_APPLICATION_INFO.SET_CLIENT_INFO(NULL);
        --
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
        -- put the schema back the way the suite found it; the integration suite
        -- turns it on for itself, but a half-run unit suite must not leave the
        -- feature switched off in a schema somebody else is about to use
        core_lock_fixture.locksmith(TRUE);
    END;



    -- ---------------------------------------------------------------- clean_user



    PROCEDURE test_clean_user#strips_the_apex_session_suffix
    AS
    BEGIN
        ut.expect(core_lock.clean_user('JAN:12345678')).to_equal('JAN');
    END;



    PROCEDURE test_clean_user#strips_a_context_manager_key
    AS
    BEGIN
        ut.expect(core_lock.clean_user('JAN_100_12345678901234')).to_equal('JAN');
    END;



    PROCEDURE test_clean_user#digits_alone_name_nobody
    AS
    BEGIN
        ut.expect(core_lock.clean_user('1234')).to_be_null();
    END;



    PROCEDURE test_clean_user#a_pool_account_names_nobody
    AS
    BEGIN
        ut.expect(core_lock.clean_user('ORDS_PUBLIC_USER')).to_be_null();
        ut.expect(core_lock.clean_user('apex_public_user')).to_be_null();
    END;



    PROCEDURE test_clean_user#one_case_for_everybody
    AS
    BEGIN
        ut.expect(core_lock.clean_user('jan')).to_equal('JAN');
        ut.expect(core_lock.clean_user('Jan')).to_equal('JAN');
    END;



    -- ------------------------------------------------------------------ get_user



    PROCEDURE test_get_user#the_client_identifier_names_the_owner
    AS
    BEGIN
        core_lock_fixture.act_as('CAROL');
        --
        ut.expect(core_lock.get_user()).to_equal('CAROL');
    END;



    PROCEDURE test_get_user#a_session_with_no_identifier_still_names_somebody
    AS
        v_user              core_locks.locked_by%TYPE;
    BEGIN
        DBMS_SESSION.CLEAR_IDENTIFIER();
        --
        v_user := core_lock.get_user();
        --
        -- what it lands on depends on the connection: an OS user, or the address
        -- as the last resort. What matters is that it never answers nobody, and
        -- never answers the schema account
        ut.expect(v_user).to_be_not_null();
        ut.expect(v_user).not_to_equal(USER);
    END;



    PROCEDURE test_get_user#a_context_key_asks_the_history
    AS
    BEGIN
        -- a key in place of a name means a name was there and a context manager
        -- wrote over it. The name left inside the key is the application user,
        -- which under SSO is a company account rather than the developer, so the
        -- workstation's own memory outranks it
        core_lock_fixture.act_as('CAROL_100_12345678901234');
        --
        INSERT INTO core_locks (
            object_owner, object_type, object_name, locked_by,
            locked_at, expire_at, counter, audit_trail
        )
        VALUES (
            USER, 'PROCEDURE', 'CLUT_HISTORY', 'DAVE',
            SYSDATE, SYSDATE, 1, core_lock.get_audit_trail()
        );
        --
        COMMIT;
        --
        -- DAVE is what this machine compiled as; CAROL is what the key still says
        ut.expect(core_lock.get_user()).to_equal('DAVE');
    END;



    PROCEDURE test_get_user#falls_back_to_the_client_info_name
    AS
    BEGIN
        DBMS_SESSION.CLEAR_IDENTIFIER();
        DBMS_APPLICATION_INFO.SET_CLIENT_INFO('JOB:ERIC');
        --
        -- the prefix in front of the colon belongs to the job that set it, and
        -- the name behind it belongs to the person the lock is about
        ut.expect(core_lock.get_user()).to_equal('ERIC');
    END;



    -- -------------------------------------------------------------- recover_user



    PROCEDURE test_recover_user#finds_the_name_this_workstation_used_last
    AS
    BEGIN
        INSERT INTO core_locks (
            object_owner, object_type, object_name, locked_by,
            locked_at, expire_at, counter, audit_trail
        )
        VALUES (
            USER, 'PROCEDURE', 'CLUT_HISTORY', 'CAROL',
            SYSDATE, SYSDATE, 1, core_lock.get_audit_trail()
        );
        --
        COMMIT;
        --
        ut.expect(core_lock.recover_user()).to_equal('CAROL');
    END;



    PROCEDURE test_recover_user#same_desk_different_tool
    AS
        -- the same address and host, a different timezone and module, which is
        -- the same developer opening a second tool at the same desk
        v_trail             core_locks.audit_trail%TYPE := SUBSTR (
            REGEXP_SUBSTR(core_lock.get_audit_trail(), '^[^|]*\|[^|]*') || '|OTHER_ZONE|OTHER_TOOL',
            1, 128
        );
    BEGIN
        INSERT INTO core_locks (
            object_owner, object_type, object_name, locked_by,
            locked_at, expire_at, counter, audit_trail
        )
        VALUES (
            USER, 'PROCEDURE', 'CLUT_HISTORY', 'FRANK',
            SYSDATE, SYSDATE, 1, v_trail
        );
        --
        COMMIT;

        -- said out loud, because the whole test rests on it: the exact trail
        -- matches nothing, so only the widened question can answer FRANK
        ut.expect(v_trail).not_to_equal(core_lock.get_audit_trail());
        ut.expect(core_lock.recover_user()).to_equal('FRANK');
    END;



    -- ------------------------------------------------------------ get_audit_trail



    PROCEDURE test_get_audit_trail#carries_four_parts
    AS
        v_trail             core_locks.audit_trail%TYPE := core_lock.get_audit_trail();
    BEGIN
        ut.expect(v_trail).to_be_not_null();
        ut.expect(REGEXP_COUNT(v_trail, '\|')).to_equal(3);
    END;



    -- ---------------------------------------------------------------- get_object



    PROCEDURE test_get_object#rebuilds_a_package_body_from_the_dictionary
    AS
        v_src               CLOB;
        v_head              VARCHAR2(200);
    BEGIN
        core_lock_fixture.compile_probe('PACKAGE', 1);
        core_lock_fixture.compile_probe('PACKAGE BODY', 1);
        --
        v_src   := core_lock.get_object('PACKAGE BODY', core_lock_fixture.c_pkg);
        v_head  := DBMS_LOB.SUBSTR(v_src, 100, 1);
        --
        -- compared upper case on purpose: user_source keeps what the developer
        -- typed, so the rebuilt statement carries their casing after the CREATE OR
        -- REPLACE. That difference is exactly what object_body exists to absorb,
        -- and pinning it here would make this test about formatting
        ut.expect(UPPER(v_head)).to_be_like('CREATE OR REPLACE PACKAGE BODY ' || core_lock_fixture.c_pkg || '%');
        ut.expect(DBMS_LOB.INSTR(v_src, 'version 1')).to_be_greater_than(0);
    END;



    PROCEDURE test_get_object#an_object_the_dictionary_has_not_got_is_null
    AS
    BEGIN
        ut.expect(core_lock.get_object('PROCEDURE', 'CLUT_NOT_THERE')).to_be_null();
    END;



    PROCEDURE test_get_object#reads_a_view_past_the_varchar_limit
    AS
        v_src               CLOB;
    BEGIN
        core_lock_fixture.compile_probe('BIG VIEW', 1);
        --
        v_src := core_lock.get_object('VIEW', core_lock_fixture.c_bigview);

        -- a view's text is a LONG, and a SELECT INTO of one stops at the varchar
        -- ceiling, so a big reporting view would lose its backup and its
        -- fingerprint exactly where a lock is worth the most. The last padding
        -- line is the proof: a read that stopped at the first chunk keeps
        -- pad000001 and never reaches this one
        ut.expect(DBMS_LOB.GETLENGTH(v_src)).to_be_greater_than(40000);
        ut.expect(DBMS_LOB.INSTR(v_src, 'pad001800')).to_be_greater_than(0);
    END;



    -- -------------------------------------------------------------- get_clob_hash



    PROCEDURE test_get_clob_hash#a_null_payload_has_no_fingerprint
    AS
    BEGIN
        ut.expect(core_lock.get_clob_hash(NULL)).to_be_null();
    END;



    PROCEDURE test_get_clob_hash#the_same_text_fingerprints_the_same
    AS
        v_first             VARCHAR2(128) := core_lock.get_clob_hash(TO_CLOB('BEGIN NULL; END;'));
        v_again             VARCHAR2(128) := core_lock.get_clob_hash(TO_CLOB('BEGIN NULL; END;'));
    BEGIN
        ut.expect(v_first).to_be_not_null();
        ut.expect(v_again).to_equal(v_first);
    END;



    PROCEDURE test_get_clob_hash#different_text_fingerprints_differently
    AS
        v_first             VARCHAR2(128) := core_lock.get_clob_hash(TO_CLOB('BEGIN NULL; END;'));
        v_other             VARCHAR2(128) := core_lock.get_clob_hash(TO_CLOB('BEGIN RETURN; END;'));
    BEGIN
        ut.expect(v_other).not_to_equal(v_first);
    END;



    PROCEDURE test_get_clob_hash#an_explicit_algorithm_is_used
    AS
        v_default           VARCHAR2(256) := core_lock.get_clob_hash(TO_CLOB('BEGIN NULL; END;'));
        v_wider             VARCHAR2(256) := core_lock.get_clob_hash(TO_CLOB('BEGIN NULL; END;'), DBMS_CRYPTO.HASH_SH512);
    BEGIN
        -- a 256 bit digest prints 64 hex characters and a 512 bit one prints 128,
        -- so the length is what says which algorithm actually ran. Comparing the
        -- two digests instead would pass with the argument thrown away, because a
        -- default-only implementation returns the same string twice and the
        -- assertion would be that it did not
        ut.expect(LENGTH(v_default)).to_equal(64);
        ut.expect(LENGTH(v_wider)).to_equal(128);
    END;



    -- --------------------------------------------------------------- create_lock



    PROCEDURE test_create_lock#opens_a_lock_on_the_named_object
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        --
        core_lock.create_lock (
            in_object_owner => USER,
            in_object_type  => 'PROCEDURE',
            in_object_name  => core_lock_fixture.c_proc
        );
        --
        rec := newest_lock(core_lock_fixture.c_proc);
        --
        ut.expect(core_lock_fixture.lock_count(core_lock_fixture.c_proc)).to_equal(1);
        ut.expect(rec.locked_by).to_equal(core_lock_fixture.c_alice);
        ut.expect(rec.counter).to_equal(1);
        ut.expect(rec.object_hash).to_be_not_null();
        ut.expect(rec.object_payload).to_be_not_null();
        ut.expect(rec.audit_trail).to_be_not_null();
        ut.expect(rec.expire_at).to_be_greater_than(SYSDATE);
    END;



    PROCEDURE test_create_lock#no_source_means_no_fingerprint
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('TABLE');
        --
        core_lock.create_lock (
            in_object_owner => USER,
            in_object_type  => 'TABLE',
            in_object_name  => core_lock_fixture.c_table
        );
        --
        rec := newest_lock(core_lock_fixture.c_table);
        --
        -- the lock is still taken; a table simply has nothing to fingerprint
        ut.expect(core_lock_fixture.lock_count(core_lock_fixture.c_table)).to_equal(1);
        ut.expect(rec.object_hash).to_be_null();
    END;



    PROCEDURE test_create_lock#the_same_user_extends_instead_of_opening_a_second
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        --
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        --
        rec := newest_lock(core_lock_fixture.c_proc);
        --
        ut.expect(core_lock_fixture.lock_count(core_lock_fixture.c_proc)).to_equal(1);
        ut.expect(rec.counter).to_equal(2);
    END;



    PROCEDURE test_create_lock#a_live_lock_refuses_a_second_user
    AS
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        --
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        --
        core_lock_fixture.act_as(core_lock_fixture.c_bob);
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
    END;



    PROCEDURE test_create_lock#the_refusal_names_the_holder
    AS
        v_error             VARCHAR2(4000);
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        --
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        --
        core_lock_fixture.act_as(core_lock_fixture.c_bob);
        --
        BEGIN
            core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        EXCEPTION
        WHEN OTHERS THEN
            v_error := SQLERRM;
        END;
        --
        -- the point of the message is that it tells you who to go and ask
        ut.expect(v_error).to_be_like('%LOCK_TIME_ERROR%');
        ut.expect(v_error).to_be_like('%' || core_lock_fixture.c_alice || '%');
    END;



    PROCEDURE test_create_lock#an_expired_lock_can_be_taken_over
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        --
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        core_lock_fixture.age_lock (
            in_object_name  => core_lock_fixture.c_proc,
            in_expire_at    => SYSDATE - 1/1440
        );
        --
        core_lock_fixture.act_as(core_lock_fixture.c_bob);
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        --
        rec := newest_lock(core_lock_fixture.c_proc);
        --
        -- the old row stays as history, the new one belongs to whoever took over
        ut.expect(rec.locked_by).to_equal(core_lock_fixture.c_bob);
        ut.expect(rec.expire_at).to_be_greater_than(SYSDATE);
    END;



    PROCEDURE test_create_lock#a_changed_object_refuses_the_takeover
    AS
        v_error             VARCHAR2(4000);
        v_source            VARCHAR2(200);
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);

        -- expired, so the lock itself no longer refuses; locked_at stays fresh so
        -- the fingerprint check is the only thing left standing between Bob and
        -- the object. The version under test is genuinely a different text from
        -- the one the lock was cut against, which is the whole point
        core_lock_fixture.age_lock (
            in_object_name  => core_lock_fixture.c_proc,
            in_expire_at    => SYSDATE - 1/1440
        );
        --
        core_lock_fixture.compile_probe('PROCEDURE', 2);
        --
        core_lock_fixture.act_as(core_lock_fixture.c_bob);
        --
        BEGIN
            core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        EXCEPTION
        WHEN OTHERS THEN
            v_error := SQLERRM;
        END;
        --
        ut.expect(v_error).to_be_like('%LOCK_HASH_ERROR%');

        -- and the version that was there is still the version that is there
        SELECT MAX(t.text)
        INTO v_source
        FROM user_source t
        WHERE t.name    = core_lock_fixture.c_proc
            AND t.text LIKE '%version%';
        --
        ut.expect(v_source).to_be_like('%version 2%');
    END;



    PROCEDURE test_create_lock#past_the_rebook_window_starts_a_new_row
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        --
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);

        -- the rebook window is ten minutes; past it the same user gets a fresh
        -- row so the old payload survives as a backup instead of being overwritten
        core_lock_fixture.age_lock (
            in_object_name  => core_lock_fixture.c_proc,
            in_locked_at    => SYSDATE - 11/1440
        );
        --
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        --
        rec := newest_lock(core_lock_fixture.c_proc);
        --
        ut.expect(core_lock_fixture.lock_count(core_lock_fixture.c_proc)).to_equal(2);
        ut.expect(rec.counter).to_equal(1);
    END;



    PROCEDURE test_create_lock#an_explicit_name_owns_the_lock
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);

        -- the session says Alice and the caller says otherwise, which is how a
        -- tool books a lock on behalf of somebody it authenticated itself
        core_lock.create_lock (
            in_object_owner => USER,
            in_object_type  => 'PROCEDURE',
            in_object_name  => core_lock_fixture.c_proc,
            in_locked_by    => 'DAVE'
        );
        --
        rec := newest_lock(core_lock_fixture.c_proc);
        --
        ut.expect(rec.locked_by).to_equal('DAVE');
    END;



    PROCEDURE test_create_lock#an_explicit_expiry_is_kept
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        --
        core_lock.create_lock (
            in_object_owner => USER,
            in_object_type  => 'PROCEDURE',
            in_object_name  => core_lock_fixture.c_proc,
            in_expire_at    => SYSDATE + 3/1440
        );
        --
        rec := newest_lock(core_lock_fixture.c_proc);
        --
        -- the default lock length is twenty minutes, so an expiry inside five
        -- proves the argument was used and not the constant
        ut.expect(rec.expire_at).to_be_greater_than(SYSDATE + 2/1440);
        ut.expect(rec.expire_at).to_be_less_than(SYSDATE + 5/1440);
    END;



    PROCEDURE test_create_lock#hash_check_off_allows_the_takeover
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);

        -- exactly the arrangement that refuses a takeover: the lock has run out,
        -- it was cut a moment ago, and the object is no longer the object it was
        -- cut against. The only thing different here is the argument
        core_lock_fixture.age_lock (
            in_object_name  => core_lock_fixture.c_proc,
            in_expire_at    => SYSDATE - 1/1440
        );
        --
        core_lock_fixture.compile_probe('PROCEDURE', 2);
        --
        core_lock_fixture.act_as(core_lock_fixture.c_bob);
        --
        core_lock.create_lock (
            in_object_owner => USER,
            in_object_type  => 'PROCEDURE',
            in_object_name  => core_lock_fixture.c_proc,
            in_hash_check   => FALSE
        );
        --
        rec := newest_lock(core_lock_fixture.c_proc);
        --
        ut.expect(rec.locked_by).to_equal(core_lock_fixture.c_bob);
    END;



    -- --------------------------------------------------------------- extend_lock



    PROCEDURE test_extend_lock#refreshes_the_expiry_and_counts_the_compile
    AS
        rec                 core_locks%ROWTYPE;
        v_after             core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        --
        rec := newest_lock(core_lock_fixture.c_proc);
        core_lock_fixture.age_lock (
            in_object_name  => core_lock_fixture.c_proc,
            in_expire_at    => SYSDATE + 1/1440
        );
        --
        core_lock.extend_lock(in_lock_id => rec.lock_id);
        --
        v_after := newest_lock(core_lock_fixture.c_proc);
        --
        ut.expect(v_after.counter).to_equal(rec.counter + 1);
        ut.expect(v_after.expire_at).to_be_greater_than(SYSDATE + 15/1440);
    END;



    PROCEDURE test_extend_lock#refreshes_the_fingerprint
    AS
        rec                 core_locks%ROWTYPE;
        v_after             core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        --
        rec := newest_lock(core_lock_fixture.c_proc);

        -- the object moves under the lock, so the refreshed fingerprint has to be
        -- a different one; an extend that kept the old hash would compare the next
        -- compile against a version that no longer exists
        core_lock_fixture.compile_probe('PROCEDURE', 2);
        --
        core_lock.extend_lock(in_lock_id => rec.lock_id);
        --
        v_after := newest_lock(core_lock_fixture.c_proc);
        --
        ut.expect(v_after.object_hash).to_be_not_null();
        ut.expect(v_after.object_hash).not_to_equal(rec.object_hash);
    END;



    PROCEDURE test_extend_lock#an_explicit_interval_sets_the_expiry
    AS
        rec                 core_locks%ROWTYPE;
        v_after             core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        --
        rec := newest_lock(core_lock_fixture.c_proc);
        --
        core_lock.extend_lock (
            in_lock_id      => rec.lock_id,
            in_time         => 5/1440
        );
        --
        v_after := newest_lock(core_lock_fixture.c_proc);
        --
        ut.expect(v_after.expire_at).to_be_greater_than(SYSDATE + 4/1440);
        ut.expect(v_after.expire_at).to_be_less_than(SYSDATE + 6/1440);
    END;



    PROCEDURE test_extend_lock#an_explicit_date_sets_the_expiry
    AS
        rec                 core_locks%ROWTYPE;
        v_after             core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        --
        rec := newest_lock(core_lock_fixture.c_proc);

        -- the other overload takes an interval and this one takes the moment
        -- itself, named rather than positional because that is the only thing
        -- telling the two of them apart
        core_lock.extend_lock (
            in_lock_id      => rec.lock_id,
            in_expire_at    => SYSDATE + 3/1440
        );
        --
        v_after := newest_lock(core_lock_fixture.c_proc);
        --
        ut.expect(v_after.expire_at).to_be_greater_than(SYSDATE + 2/1440);
        ut.expect(v_after.expire_at).to_be_less_than(SYSDATE + 5/1440);
        ut.expect(v_after.counter).to_equal(rec.counter + 1);
    END;



    -- -------------------------------------------------------------------- unlock



    PROCEDURE test_unlock#releases_the_lock_and_clears_the_fingerprint
    AS
        rec                 core_locks%ROWTYPE;
        v_after             core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        --
        rec := newest_lock(core_lock_fixture.c_proc);
        --
        core_lock.unlock(in_lock_id => rec.lock_id);
        --
        v_after := newest_lock(core_lock_fixture.c_proc);
        --
        ut.expect(v_after.expire_at).to_be_null();
        ut.expect(v_after.object_hash).to_be_null();
    END;



    PROCEDURE test_unlock#releases_every_lock_one_user_holds
    AS
        v_live              PLS_INTEGER;
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        core_lock_fixture.compile_probe('FUNCTION', 1);
        --
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        core_lock.create_lock(USER, 'FUNCTION', core_lock_fixture.c_fn);
        --
        core_lock.unlock(in_locked_by => core_lock_fixture.c_alice);
        --
        SELECT COUNT(*)
        INTO v_live
        FROM core_locks t
        WHERE t.expire_at >= SYSDATE;
        --
        ut.expect(v_live).to_equal(0);
    END;



    PROCEDURE test_unlock#releases_only_the_named_object
    AS
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        core_lock_fixture.compile_probe('FUNCTION', 1);
        --
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        core_lock.create_lock(USER, 'FUNCTION', core_lock_fixture.c_fn);
        --
        core_lock.unlock(in_object_name => core_lock_fixture.c_proc);

        -- one developer holding two objects releases one of them and keeps
        -- working on the other, which is the ordinary case and not an edge one
        ut.expect(newest_lock(core_lock_fixture.c_proc).expire_at).to_be_null();
        ut.expect(newest_lock(core_lock_fixture.c_fn).expire_at).to_be_greater_than(SYSDATE);
    END;



    PROCEDURE test_unlock#narrows_by_object_type
    AS
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        core_lock_fixture.compile_probe('FUNCTION', 1);
        --
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        core_lock.create_lock(USER, 'FUNCTION', core_lock_fixture.c_fn);

        -- by owner alone this releases everything Alice holds, so the type is
        -- the only thing leaving the procedure locked. A type on its own is not
        -- enough of an argument for unlock to run at all, which is why the owner
        -- is here as well
        core_lock.unlock (
            in_locked_by    => core_lock_fixture.c_alice,
            in_object_type  => 'FUNCTION'
        );
        --
        ut.expect(newest_lock(core_lock_fixture.c_fn).expire_at).to_be_null();
        ut.expect(newest_lock(core_lock_fixture.c_proc).expire_at).to_be_greater_than(SYSDATE);
    END;



    PROCEDURE test_unlock#refuses_to_run_with_no_arguments
    AS
    BEGIN
        core_lock.unlock();
    END;



    -- --------------------------------------------------------------- purge_locks



    PROCEDURE test_purge_locks#leaves_the_retention_window_alone
    AS
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        --
        core_lock.purge_locks();
        --
        ut.expect(core_lock_fixture.lock_count(core_lock_fixture.c_proc)).to_equal(1);
    END;



    PROCEDURE test_purge_locks#leaves_a_live_lock_untouched
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        core_lock_fixture.compile_probe('PROCEDURE', 1);
        core_lock.create_lock(USER, 'PROCEDURE', core_lock_fixture.c_proc);
        --
        core_lock.purge_locks();
        --
        rec := newest_lock(core_lock_fixture.c_proc);
        --
        -- housekeeping must never reach into a lock somebody is holding: the
        -- payload is that developer's source backup while they work on it
        ut.expect(rec.object_payload).to_be_not_null();
        ut.expect(rec.object_hash).to_be_not_null();
        ut.expect(rec.expire_at).to_be_greater_than(SYSDATE);
    END;



    PROCEDURE test_purge_locks#a_recent_history_row_survives
    AS
        v_kept              PLS_INTEGER;
    BEGIN
        -- two released rows for one object: the older one is history and is NOT
        -- the newest row, so nothing but the retention window is protecting it.
        -- A single-row fixture cannot make this claim, because the only row an object has
        -- is always its newest, and the purge spares that one whatever the window
        seed_history('CLUT_RECENT', SYSDATE - 1);
        seed_history('CLUT_RECENT', SYSDATE);
        --
        core_lock.purge_locks();
        --
        SELECT COUNT(*)
        INTO v_kept
        FROM core_locks t
        WHERE t.object_name = 'CLUT_RECENT';
        --
        ut.expect(v_kept).to_equal(2);
    END;



    PROCEDURE test_purge_locks#keeps_the_newest_row_per_object
    AS
        v_kept              PLS_INTEGER;
    BEGIN
        -- two released rows for the same object, both well past the seven days
        seed_history('CLUT_OLD', SYSDATE - 30);
        seed_history('CLUT_OLD', SYSDATE - 20);
        --
        core_lock.purge_locks();
        --
        SELECT COUNT(*)
        INTO v_kept
        FROM core_locks t
        WHERE t.object_name = 'CLUT_OLD';
        --
        ut.expect(v_kept).to_equal(1);
    END;



    PROCEDURE test_purge_locks#drops_payload_but_keeps_the_fingerprint
    AS
        rec                 core_locks%ROWTYPE;
    BEGIN
        seed_history('CLUT_OLD', SYSDATE - 30);
        --
        core_lock.purge_locks();
        --
        rec := newest_lock('CLUT_OLD');
        --
        -- the hash is what a takeover check needs; the payload is only a backup
        ut.expect(rec.object_payload).to_be_null();
        ut.expect(rec.object_hash).to_equal('DEADBEEF');
    END;



    -- --------------------------------------------------------------- raise_error



    PROCEDURE test_raise_error#raises_the_catalogue_code
    AS
    BEGIN
        core_lock.raise_error('ANYTHING');
    END;



    PROCEDURE test_raise_error#carries_the_message
    AS
        v_code              PLS_INTEGER;
        v_message           VARCHAR2(4000);
    BEGIN
        BEGIN
            core_lock.raise_error('SOMETHING_SPECIFIC');
        EXCEPTION
        WHEN OTHERS THEN
            v_code      := SQLCODE;
            v_message   := SQLERRM;
        END;
        --
        ut.expect(v_code).to_equal(core_lock.c_app_exception_code);
        ut.expect(v_message).to_be_like('%SOMETHING_SPECIFIC%');
    END;

END;
/
