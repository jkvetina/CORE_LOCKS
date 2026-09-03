CREATE OR REPLACE PACKAGE core_lock_ut AS

    -- rollback: create_lock, extend_lock, unlock and purge_locks all carry
    -- PRAGMA AUTONOMOUS_TRANSACTION and commit inside themselves, so there is no
    -- savepoint left for utPLSQL to roll back to and the fixture owns cleanup
    -- %suite(core_lock package API)
    -- %suitepath(core_locks.lock)
    -- %tags(unit)
    -- %rollback(manual)
    -- %beforeall(before_all)
    -- %beforeeach(before_each)
    -- %aftereach(after_each)
    -- %afterall(after_all)

    PROCEDURE before_all;

    PROCEDURE before_each;

    PROCEDURE after_each;

    PROCEDURE after_all;



    -- %test(strips the session number APEX appends to a name)
    PROCEDURE test_clean_user#strips_the_apex_session_suffix;

    -- %test(strips the trailing key a context manager writes over a name)
    PROCEDURE test_clean_user#strips_a_context_manager_key;

    -- %test(a name that is only digits names nobody)
    PROCEDURE test_clean_user#digits_alone_name_nobody;

    -- %test(a connection pool account names nobody)
    PROCEDURE test_clean_user#a_pool_account_names_nobody;

    -- %test(one case for everybody, so a tool that capitalises differently is the same person)
    PROCEDURE test_clean_user#one_case_for_everybody;



    -- %test(the client identifier is the name the lock carries)
    PROCEDURE test_get_user#the_client_identifier_names_the_owner;

    -- %test(a session that offers no identifier still resolves to somebody)
    PROCEDURE test_get_user#a_session_with_no_identifier_still_names_somebody;

    -- %test(a context key over a name sends the question to the history)
    PROCEDURE test_get_user#a_context_key_asks_the_history;

    -- %test(falls back to the name inside client info, prefix and all)
    PROCEDURE test_get_user#falls_back_to_the_client_info_name;



    -- %test(reads back the name this workstation last compiled under)
    PROCEDURE test_recover_user#finds_the_name_this_workstation_used_last;

    -- %test(same desk and a different tool still names the developer)
    PROCEDURE test_recover_user#same_desk_different_tool;



    -- %test(carries address, host, timezone and module in one string)
    PROCEDURE test_get_audit_trail#carries_four_parts;



    -- %test(rebuilds a package body from the dictionary when there is no statement to read)
    PROCEDURE test_get_object#rebuilds_a_package_body_from_the_dictionary;

    -- %test(an object the dictionary has not got answers null)
    PROCEDURE test_get_object#an_object_the_dictionary_has_not_got_is_null;

    -- %test(a view longer than a varchar2 is read whole)
    PROCEDURE test_get_object#reads_a_view_past_the_varchar_limit;



    -- %test(a null payload has no fingerprint)
    PROCEDURE test_get_clob_hash#a_null_payload_has_no_fingerprint;

    -- %test(the same text fingerprints the same)
    PROCEDURE test_get_clob_hash#the_same_text_fingerprints_the_same;

    -- %test(different text fingerprints differently)
    PROCEDURE test_get_clob_hash#different_text_fingerprints_differently;

    -- %test(the algorithm asked for is the algorithm used)
    PROCEDURE test_get_clob_hash#an_explicit_algorithm_is_used;



    -- %test(opens one lock on the named object, with a payload and a fingerprint)
    PROCEDURE test_create_lock#opens_a_lock_on_the_named_object;

    -- %test(an object carrying no source locks without a fingerprint)
    PROCEDURE test_create_lock#no_source_means_no_fingerprint;

    -- %test(the same user extends the lock instead of opening a second one)
    PROCEDURE test_create_lock#the_same_user_extends_instead_of_opening_a_second;

    -- %test(a live lock refuses a second user)
    -- %throws(core_lock.c_app_exception_code)
    PROCEDURE test_create_lock#a_live_lock_refuses_a_second_user;

    -- %test(the refusal names the holder and the lock)
    PROCEDURE test_create_lock#the_refusal_names_the_holder;

    -- %test(an expired lock can be taken over by somebody else)
    PROCEDURE test_create_lock#an_expired_lock_can_be_taken_over;

    -- %test(an object changed since the lock was cut refuses the takeover)
    PROCEDURE test_create_lock#a_changed_object_refuses_the_takeover;

    -- %test(a compile past the rebook window closes the row and starts a new one)
    PROCEDURE test_create_lock#past_the_rebook_window_starts_a_new_row;

    -- %test(a name given outright owns the lock instead of the session)
    PROCEDURE test_create_lock#an_explicit_name_owns_the_lock;

    -- %test(an expiry given outright replaces the default lock length)
    PROCEDURE test_create_lock#an_explicit_expiry_is_kept;

    -- %test(with the fingerprint check off a changed object is taken over)
    PROCEDURE test_create_lock#hash_check_off_allows_the_takeover;



    -- %test(refreshes the expiry and counts the compile)
    PROCEDURE test_extend_lock#refreshes_the_expiry_and_counts_the_compile;

    -- %test(refreshes the fingerprint it will later compare against)
    PROCEDURE test_extend_lock#refreshes_the_fingerprint;

    -- %test(reads the object the lock row names, not whichever was touched last)
    PROCEDURE test_extend_lock#reads_the_object_the_row_names;

    -- %test(an unchanged view keeps the fingerprint its lock was cut with)
    PROCEDURE test_extend_lock#a_view_keeps_the_fingerprint_it_was_locked_with;

    -- %test(an object dropped under the lock keeps the last payload and fingerprint)
    PROCEDURE test_extend_lock#a_dropped_object_keeps_the_last_payload;

    -- %test(an explicit interval sets the expiry)
    PROCEDURE test_extend_lock#an_explicit_interval_sets_the_expiry;

    -- %test(an explicit date sets the expiry, on the other overload)
    PROCEDURE test_extend_lock#an_explicit_date_sets_the_expiry;



    -- %test(releases the lock and clears the fingerprint)
    PROCEDURE test_unlock#releases_the_lock_and_clears_the_fingerprint;

    -- %test(releases every lock one user holds)
    PROCEDURE test_unlock#releases_every_lock_one_user_holds;

    -- %test(releases the object named and leaves the others held)
    PROCEDURE test_unlock#releases_only_the_named_object;

    -- %test(a type narrows a release that would otherwise take the lot)
    PROCEDURE test_unlock#narrows_by_object_type;

    -- %test(refuses to run with no arguments at all)
    -- %throws(core_lock.c_app_exception_code)
    PROCEDURE test_unlock#refuses_to_run_with_no_arguments;



    -- %test(leaves rows inside the retention window alone)
    PROCEDURE test_purge_locks#leaves_the_retention_window_alone;

    -- %test(a live lock keeps its payload and its expiry)
    PROCEDURE test_purge_locks#leaves_a_live_lock_untouched;

    -- %test(a released history row younger than the window survives)
    PROCEDURE test_purge_locks#a_recent_history_row_survives;

    -- %test(deletes old history but keeps the newest row per object)
    PROCEDURE test_purge_locks#keeps_the_newest_row_per_object;

    -- %test(drops the payload on kept old rows but keeps the fingerprint)
    PROCEDURE test_purge_locks#drops_payload_but_keeps_the_fingerprint;



    -- %test(raises the code the whole feature reports under)
    -- %throws(core_lock.c_app_exception_code)
    PROCEDURE test_raise_error#raises_the_catalogue_code;

    -- %test(carries the message it was given through to the caller)
    PROCEDURE test_raise_error#carries_the_message;

END;
/
