CREATE OR REPLACE PACKAGE BODY core_lock AS

    g_lock_length       CONSTANT NUMBER     := 20/1440;     -- for how long is lock valid
    g_lock_rebook       CONSTANT NUMBER     := 10/1440;     -- how long to create a new lock (object backup)
    g_check_hash        CONSTANT BOOLEAN    := TRUE;
    g_purge_after       CONSTANT NUMBER     := 7;           -- how many days of history the purge job keeps untouched

    -- accounts that name a connection pool or a process, never a person
    -- colon delimited on both ends, so INSTR matches a whole name and not a fragment
    c_anon_users        CONSTANT VARCHAR2(256) := ':ORDS_PUBLIC_USER:APEX_PUBLIC_USER:APEX_REST_PUBLIC_USER:ANONYMOUS:NOBODY:ORACLE:ROOT:SYSTEM:';

    -- set by get_object when the statement it read was an ALTER ... COMPILE, the one
    -- empty payload that means "not a change" rather than "no statement to read"
    g_alter_compile     BOOLEAN := FALSE;

    -- set by get_object when the statement it read was a DROP. The text of a DROP
    -- is not the object's source, so hashing it compares "DROP PROCEDURE X" against
    -- a source fingerprint, which can never match and refused every drop of a
    -- recently locked object with OBJECT_CHANGED_BY when nothing had changed
    g_drop_event        BOOLEAN := FALSE;



    FUNCTION dict_object (
        in_object_type      core_locks.object_type%TYPE,
        in_object_name      core_locks.object_name%TYPE
    )
    RETURN CLOB;



    FUNCTION source_object (
        in_object_type      core_locks.object_type%TYPE,
        in_object_name      core_locks.object_name%TYPE
    )
    RETURN CLOB;



    FUNCTION object_body (
        in_object_type      core_locks.object_type%TYPE,
        in_payload          CLOB
    )
    RETURN CLOB;



    PROCEDURE raise_error (
        in_message          VARCHAR2 := NULL
    )
    AS
        v_message           VARCHAR2(2048);
    BEGIN
        -- called bare from WHEN OTHERS handlers, where SQLERRM carries the error
        v_message := COALESCE (
            in_message,
            CASE WHEN SQLERRM NOT LIKE 'ORA-0000:%' THEN SQLERRM END,
            'CORE_LOCK_ERROR'
        );

        -- keeperrorstack, since nothing logs the backtrace before we raise
        RAISE_APPLICATION_ERROR(c_app_exception_code, SUBSTR(v_message, 1, 2048), TRUE);
    END;



    FUNCTION clean_user (
        in_name             VARCHAR2
    )
    RETURN core_locks.locked_by%TYPE
    AS
        v_name              core_locks.locked_by%TYPE;
    BEGIN
        -- the client identifier is a key, not a name, and every tool builds it its own way,
        -- APEX stamps JAN:12345678 and a session context manager can stamp JAN_100_12345678901234,
        -- so drop the trailing session number in both shapes
        v_name := TRIM(REGEXP_REPLACE(in_name, '(:\d+|_\d+_\d+)$', ''));

        -- a number is no name at all, some clients (Toad) stamp the session with one,
        -- and a lock owned by 1234 tells you as little as one owned by the schema
        IF REGEXP_LIKE(v_name, '^\d+$') THEN
            RETURN NULL;
        END IF;

        -- a pool or process account is not a person either
        IF INSTR(c_anon_users, ':' || UPPER(v_name) || ':') > 0 THEN
            RETURN NULL;
        END IF;

        -- one case for everybody. Jan, JAN and jan are one developer, and the lock
        -- compares owners as strings, so letting the case through would let the same
        -- person lock themselves out from a tool that capitalizes differently
        RETURN UPPER(v_name);
    END;



    FUNCTION recover_user
    RETURN core_locks.locked_by%TYPE
    AS
        v_trail             core_locks.audit_trail%TYPE := get_audit_trail();
        v_place             core_locks.audit_trail%TYPE;
        v_name              core_locks.locked_by%TYPE;
    BEGIN
        IF v_trail IS NULL THEN
            RETURN NULL;
        END IF;

        -- the session cannot say who it belongs to, but the workstation can,
        -- so ask the history what this exact machine and tool called itself last time
        -- KEEP DENSE_RANK LAST gives the newest row and NULL when there is none,
        -- which is what we want here, an empty history is not an error
        SELECT MAX(t.locked_by) KEEP (DENSE_RANK LAST ORDER BY t.lock_id)
        INTO v_name
        FROM core_locks t
        WHERE t.audit_trail     = v_trail
            AND REGEXP_LIKE(t.locked_by, '[A-Za-z]')
            AND NOT REGEXP_LIKE(t.locked_by, '^\d{1,3}(\.\d{1,3}){3}$');
        --
        IF v_name IS NOT NULL THEN
            RETURN UPPER(v_name);
        END IF;

        -- same desk, different tool: the trail carries the module in its tail, so
        -- widen the question to the address and the host and ask again
        v_place := REGEXP_SUBSTR(v_trail, '^[^|]*\|[^|]*');
        --
        SELECT MAX(t.locked_by) KEEP (DENSE_RANK LAST ORDER BY t.lock_id)
        INTO v_name
        FROM core_locks t
        WHERE REGEXP_SUBSTR(t.audit_trail, '^[^|]*\|[^|]*') = v_place
            AND REGEXP_LIKE(t.locked_by, '[A-Za-z]')
            AND NOT REGEXP_LIKE(t.locked_by, '^\d{1,3}(\.\d{1,3}){3}$');
        --
        RETURN UPPER(v_name);
    END;



    FUNCTION get_user
    RETURN core_locks.locked_by%TYPE
    AS
        v_ident             core_locks.locked_by%TYPE := SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER');
        v_told              core_locks.locked_by%TYPE;
        v_lost              core_locks.locked_by%TYPE;
    BEGIN
        -- a bare name, or APEX's own NAME:12345678, is the session saying who it is,
        -- and a startup script setting the developer's own name is the best answer there is
        -- short of a proxy user. A NAME_100_12345678901234 key is something else entirely:
        -- a context manager overwrote that startup script, and the name left inside the key
        -- is the application user, which for an SSO login is a company account and not the
        -- name the developer works under
        IF REGEXP_LIKE(v_ident, '_\d+_\d+$') THEN
            -- a key in place of a name means a name was there and got overwritten,
            -- and that is the only case the history is allowed to answer. A session
            -- that never carried a name has nothing to recover, and naming it after
            -- whoever sat at that machine last would be a guess dressed as a fact
            v_lost := recover_user();
        ELSE
            v_told := clean_user(v_ident);
        END IF;

        -- best source first
        --   proxy user      the database authenticated the person, nothing beats that
        --   identifier      the session said who it is, and nothing overwrote it
        --   recovered       who this same workstation compiled as last time, and only
        --                   when a context key proves the session did have a name
        --   APEX user       the application user behind the session, a company account
        --                   under SSO, so it ranks below the workstation's own memory
        --   key remains     the name inside a context key, better than nothing
        --   client info     the same idea, minus the prefix some jobs put in front of it
        --   OS user         nobody vouched for it and it is often the company account
        --                   rather than the developer name, but it only gets asked when
        --                   every other source came back empty, and a name beats an address
        -- not adding schema on purpose, we dont want generic users
        -- the IP is the last resort, not a person but still something you can trace
        RETURN COALESCE (
            clean_user(SYS_CONTEXT('USERENV', 'PROXY_USER')),
            v_told,
            v_lost,
            clean_user(SYS_CONTEXT('APEX$SESSION', 'APP_USER')),
            clean_user(v_ident),
            clean_user(REGEXP_REPLACE(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^[^:]+:', '')),
            clean_user(SYS_CONTEXT('USERENV', 'OS_USER')),
            SYS_CONTEXT('USERENV', 'IP_ADDRESS')
        );
    END;



    FUNCTION get_audit_trail
    RETURN core_locks.audit_trail%TYPE
    AS
    BEGIN
        RETURN SUBSTR(SYS_CONTEXT('USERENV', 'IP_ADDRESS')
            || '|' || SYS_CONTEXT('USERENV', 'HOST')
            || '|' || SESSIONTIMEZONE
            || '|' || SYS_CONTEXT('USERENV', 'MODULE'), 1, 128);
    END;



    PROCEDURE create_lock (
        in_object_owner     core_locks.object_owner%TYPE,
        in_object_type      core_locks.object_type%TYPE,
        in_object_name      core_locks.object_name%TYPE,
        in_locked_by        core_locks.locked_by%TYPE       := NULL,
        in_expire_at        core_locks.expire_at%TYPE       := NULL,
        in_hash_check       BOOLEAN                         := TRUE
    )
    AS
        PRAGMA AUTONOMOUS_TRANSACTION;
        --
        rec                 core_locks%ROWTYPE;
        v_hash_check        BOOLEAN := in_hash_check;
        --
        -- what the object looked like before this statement, kept so a DROP row can
        -- carry the source of the thing that was dropped
        v_last_payload      core_locks.object_payload%TYPE;
        v_last_hash         core_locks.object_hash%TYPE;
    BEGIN
        -- check if we have a valid user
        rec.locked_by := COALESCE(in_locked_by, get_user());
        IF rec.locked_by IS NULL THEN
            raise_error('USER_ERROR: USE_PROXY_USER_OR_SET_CLIENT_ID');
        END IF;

        -- get current object, from the statement in the trigger and from the
        -- dictionary when this is called by hand
        rec.object_payload := get_object(in_object_type, in_object_name);
        --
        -- an ALTER ... COMPILE is the one empty payload that means "not a change",
        -- so it is the only one that opens no lock. Anything else locks with the
        -- payload it has, NULL included: a TABLE carries no source, a DROP has a
        -- statement that is not source, and a lock taken outside a compile is
        -- still a lock
        IF g_alter_compile THEN
            RETURN;
        END IF;

        -- check hash only on objects with source code.
        --
        -- Hash the body, never the whole statement. The trigger sees the statement a
        -- developer compiled and a lock taken by hand sees the dictionary's copy, and
        -- their first lines never match: one is what somebody typed, the other adds
        -- EDITIONABLE, quotes and schema qualifies the name, and prints a view's
        -- column list. Everything after that first line is the same text in both, so
        -- object_body drops the CREATE header and what is left compares
        IF in_object_type IN ('PACKAGE', 'PACKAGE BODY', 'PROCEDURE', 'FUNCTION', 'TRIGGER', 'VIEW') THEN
            rec.object_hash := get_clob_hash(object_body(in_object_type, rec.object_payload));
        END IF;
        --
        IF (NOT g_check_hash OR rec.object_hash IS NULL) THEN
            v_hash_check := FALSE;
        END IF;

        -- check recent log for current object
        FOR c IN (
            SELECT
                t.lock_id,
                t.locked_by,
                t.locked_at,
                t.expire_at,
                t.object_hash,
                t.object_payload
            FROM core_locks t
            WHERE t.object_owner    = in_object_owner
                AND t.object_type   = in_object_type
                AND t.object_name   = in_object_name
            ORDER BY
                t.lock_id DESC
            FETCH FIRST 1 ROWS ONLY
        ) LOOP
            v_last_payload  := c.object_payload;
            v_last_hash     := c.object_hash;
            --
            IF c.locked_by = rec.locked_by THEN
                -- same user, so just extend the lock
                rec.lock_id     := c.lock_id;
                rec.locked_at   := c.locked_at;
                --
            ELSIF c.expire_at >= SYSDATE THEN
                -- for different user we need to check the expire date first
                raise_error('LOCK_TIME_ERROR: OBJECT_LOCKED_BY `' || c.locked_by || '` [' || c.lock_id || ']');
                --
            ELSIF v_hash_check AND c.object_hash IS NOT NULL AND c.object_hash != rec.object_hash AND c.locked_at + 1/1440 > SYSDATE THEN
                -- check object hash
                -- when you take over an object, you should compile it right away, without any changes
                -- that will make sure you are not overriding any changes done by someone else in the meantime
                raise_error('LOCK_HASH_ERROR: OBJECT_CHANGED_BY `' || c.locked_by || ' ' || TO_CHAR(c.expire_at, 'YYYY-MM-DD HH24:MI') || '` [' || c.lock_id || ']');
            END IF;
        END LOOP;

        -- check how old is the lock, so we can take object backup by creating a new record
        IF rec.lock_id IS NOT NULL AND rec.locked_at + g_lock_rebook <= SYSDATE THEN
            UPDATE core_locks t
            SET t.expire_at     = SYSDATE
            WHERE t.lock_id     = rec.lock_id;
            --
            rec.lock_id := NULL;    -- to trigger new record
        END IF;

        -- create a new lock or extend existing one
        IF rec.lock_id IS NOT NULL THEN
            core_lock.extend_lock (
                in_lock_id => rec.lock_id
            );
        ELSE
            -- a DROP has no source of its own, so the row it opens carries the source
            -- of what was dropped. Without this the newest row for the object is a
            -- payload-less one, and the purge keeps exactly that row and deletes the
            -- older ones, so the backup for a dropped object is the first thing lost
            IF g_drop_event THEN
                rec.object_payload  := v_last_payload;
                rec.object_hash     := v_last_hash;
            END IF;
            --
            -- lock_id stays NULL, the identity column assigns it on insert
            rec.object_owner    := in_object_owner;
            rec.object_type     := in_object_type;
            rec.object_name     := in_object_name;
            rec.locked_at       := SYSDATE;
            rec.counter         := 1;
            rec.expire_at       := NVL(in_expire_at, rec.locked_at + g_lock_length);
            rec.audit_trail     := get_audit_trail();
            --
            INSERT INTO core_locks VALUES rec;
        END IF;
        --
        COMMIT;
        --
    EXCEPTION
    WHEN app_exception THEN
        ROLLBACK;
        RAISE;
    WHEN OTHERS THEN
        ROLLBACK;
        raise_error();
    END;



    --
    -- The source of the object a lock row is about, re-read for an extend. The row
    -- knows the type and the name, so an extend called by hand refreshes the backup
    -- exactly like one driven from the trigger instead of reading an empty statement
    --
    FUNCTION get_lock_payload (
        in_lock_id          core_locks.lock_id%TYPE
    )
    RETURN CLOB
    AS
        v_out           CLOB;
    BEGIN
        FOR c IN (
            SELECT
                t.object_type,
                t.object_name
            FROM core_locks t
            WHERE t.lock_id     = in_lock_id
        ) LOOP
            v_out := get_object(c.object_type, c.object_name);
        END LOOP;
        --
        RETURN v_out;
    END;



    --
    -- The fingerprint of that same payload, taken the way create_lock takes it, so an
    -- extend writes a hash the next compile can actually compare against
    --
    FUNCTION get_lock_hash (
        in_lock_id          core_locks.lock_id%TYPE,
        in_payload          CLOB
    )
    RETURN VARCHAR2
    AS
        v_out           VARCHAR2(128);
    BEGIN
        FOR c IN (
            SELECT
                t.object_type
            FROM core_locks t
            WHERE t.lock_id     = in_lock_id
        ) LOOP
            v_out := get_clob_hash(object_body(c.object_type, in_payload));
        END LOOP;
        --
        RETURN v_out;
    END;



    PROCEDURE extend_lock (
        in_lock_id          core_locks.lock_id%TYPE,
        in_time             NUMBER
    )
    AS
        PRAGMA AUTONOMOUS_TRANSACTION;
        --
        rec                 core_locks%ROWTYPE;
    BEGIN
        rec.expire_at       := SYSDATE + NVL(in_time, g_lock_length);
        rec.object_payload  := get_lock_payload(in_lock_id);
        rec.object_hash     := get_lock_hash(in_lock_id, rec.object_payload);
        --
        UPDATE core_locks t
        SET t.counter           = NVL(t.counter, 0) + 1,
            t.expire_at         = rec.expire_at,
            t.object_payload    = NVL(rec.object_payload, t.object_payload),
            t.object_hash       = NVL(rec.object_hash, t.object_hash)
        WHERE t.lock_id         = in_lock_id;
        --
        COMMIT;
        --
    EXCEPTION
    WHEN app_exception THEN
        ROLLBACK;
        RAISE;
    WHEN OTHERS THEN
        ROLLBACK;
        raise_error();
    END;



    PROCEDURE extend_lock (
        in_lock_id          core_locks.lock_id%TYPE,
        in_expire_at        core_locks.expire_at%TYPE       := NULL
    )
    AS
        PRAGMA AUTONOMOUS_TRANSACTION;
        --
        rec                 core_locks%ROWTYPE;
    BEGIN
        rec.expire_at       := NVL(in_expire_at, SYSDATE + g_lock_length);
        rec.object_payload  := get_lock_payload(in_lock_id);
        rec.object_hash     := get_lock_hash(in_lock_id, rec.object_payload);
        --
        UPDATE core_locks t
        SET t.counter           = NVL(t.counter, 0) + 1,
            t.expire_at         = rec.expire_at,
            t.object_payload    = NVL(rec.object_payload, t.object_payload),
            t.object_hash       = NVL(rec.object_hash, t.object_hash)
        WHERE t.lock_id         = in_lock_id;
        --
        COMMIT;
        --
    EXCEPTION
    WHEN app_exception THEN
        ROLLBACK;
        RAISE;
    WHEN OTHERS THEN
        ROLLBACK;
        raise_error();
    END;



    PROCEDURE unlock (
        in_lock_id          core_locks.lock_id%TYPE         := NULL,
        in_locked_by        core_locks.locked_by%TYPE       := NULL,
        in_object_name      core_locks.object_name%TYPE     := NULL,
        in_object_type      core_locks.object_type%TYPE     := NULL
    )
    AS
        PRAGMA AUTONOMOUS_TRANSACTION;
        --
    BEGIN
        IF in_lock_id IS NULL AND in_locked_by IS NULL AND in_object_name IS NULL THEN
            raise_error('ARGUMENTS_MISSING');
        END IF;
        --
        FOR c IN (
            SELECT
                t.object_type,
                t.object_name,
                t.lock_id
            FROM core_locks t
            WHERE 1 = 1
                AND (t.lock_id      = in_lock_id        OR in_lock_id       IS NULL)
                AND (t.locked_by    = in_locked_by      OR in_locked_by     IS NULL)
                AND (t.object_name  = in_object_name    OR in_object_name   IS NULL)
                AND (t.object_type  = in_object_type    OR in_object_type   IS NULL)
                AND (t.expire_at    >= SYSDATE)
            UNION ALL
            --
            SELECT
                t.object_type,
                t.object_name,
                MAX(t.lock_id) AS lock_id
            FROM core_locks t
            WHERE 1 = 1
                AND (t.lock_id      = in_lock_id        OR in_lock_id       IS NULL)
                AND (t.locked_by    = in_locked_by      OR in_locked_by     IS NULL)
                AND (t.object_name  = in_object_name    OR in_object_name   IS NULL)
                AND (t.object_type  = in_object_type    OR in_object_type   IS NULL)
            GROUP BY
                t.object_type,
                t.object_name
        ) LOOP
            UPDATE core_locks t
            SET t.expire_at     = NULL,
                t.object_hash   = ''
            WHERE t.lock_id     = c.lock_id;
            --
            IF SQL%ROWCOUNT > 0 THEN
                DBMS_OUTPUT.PUT_LINE(c.object_type || ' ' || c.object_name || ' UNLOCKED [' || c.lock_id || ']');
            END IF;
        END LOOP;
        --
        COMMIT;
        --
    EXCEPTION
    WHEN app_exception THEN
        ROLLBACK;
        RAISE;
    WHEN OTHERS THEN
        ROLLBACK;
        raise_error();
    END;



    --
    -- Retention rule for the lock history, run daily by the CORE_LOCKS_PURGE job:
    -- rows younger than g_purge_after days stay untouched; beyond that each unique
    -- object collapses to its newest row, which keeps the hash but drops the payload
    --
    PROCEDURE purge_locks
    AS
        PRAGMA AUTONOMOUS_TRANSACTION;
        --
        v_deleted           PLS_INTEGER;
        v_stripped          PLS_INTEGER;
    BEGIN
        -- delete old history rows, the newest row per object survives as the hash carrier
        DELETE FROM core_locks t
        WHERE 1 = 1
            AND t.locked_at     < TRUNC(SYSDATE) - g_purge_after
            AND (t.expire_at    < SYSDATE OR t.expire_at IS NULL)
            AND t.lock_id NOT IN (
                SELECT MAX(s.lock_id)
                FROM core_locks s
                GROUP BY
                    s.object_owner,
                    s.object_type,
                    s.object_name
            );
        --
        v_deleted := SQL%ROWCOUNT;

        -- ditch the payload on the kept old rows, the hash stays for takeover checks
        UPDATE core_locks t
        SET t.object_payload    = NULL
        WHERE 1 = 1
            AND t.locked_at     < TRUNC(SYSDATE) - g_purge_after
            AND (t.expire_at    < SYSDATE OR t.expire_at IS NULL)
            AND t.object_payload IS NOT NULL;
        --
        v_stripped := SQL%ROWCOUNT;
        --
        COMMIT;
        --
        DBMS_OUTPUT.PUT_LINE('CORE_LOCKS_PURGE: ROWS_DELETED=' || v_deleted || ' PAYLOADS_DITCHED=' || v_stripped);
        --
    EXCEPTION
    WHEN app_exception THEN
        ROLLBACK;
        RAISE;
    WHEN OTHERS THEN
        ROLLBACK;
        raise_error();
    END;



    --
    -- A view's query text, which is a LONG. No SQL expression may concatenate one,
    -- and a SELECT INTO caps at the PL/SQL varchar limit, so a big reporting view
    -- would lose its fingerprint exactly where a lock is worth the most. DBMS_SQL
    -- reads a LONG in chunks and has no such ceiling. It is granted to PUBLIC, so
    -- this costs no extra privilege
    --
    FUNCTION view_query (
        in_object_name      core_locks.object_name%TYPE
    )
    RETURN CLOB
    AS
        v_cursor        PLS_INTEGER := DBMS_SQL.OPEN_CURSOR;
        v_ignore        PLS_INTEGER;
        v_chunk         VARCHAR2(32767);
        v_read          PLS_INTEGER;
        v_offset        PLS_INTEGER := 0;
        v_out           CLOB;
    BEGIN
        DBMS_SQL.PARSE(v_cursor, 'SELECT t.text FROM user_views t WHERE t.view_name = :n', DBMS_SQL.NATIVE);
        DBMS_SQL.BIND_VARIABLE(v_cursor, ':n', in_object_name);
        DBMS_SQL.DEFINE_COLUMN_LONG(v_cursor, 1);
        --
        v_ignore := DBMS_SQL.EXECUTE(v_cursor);
        --
        IF DBMS_SQL.FETCH_ROWS(v_cursor) > 0 THEN
            LOOP
                DBMS_SQL.COLUMN_VALUE_LONG(v_cursor, 1, 32767, v_offset, v_chunk, v_read);
                EXIT WHEN NVL(v_read, 0) = 0;
                --
                v_out       := v_out || SUBSTR(v_chunk, 1, v_read);
                v_offset    := v_offset + v_read;
            END LOOP;
        END IF;
        --
        DBMS_SQL.CLOSE_CURSOR(v_cursor);
        --
        RETURN v_out;
    EXCEPTION
    WHEN OTHERS THEN
        IF DBMS_SQL.IS_OPEN(v_cursor) THEN
            DBMS_SQL.CLOSE_CURSOR(v_cursor);
        END IF;
        --
        RETURN NULL;
    END;



    --
    -- The object as the dictionary itself holds it, rebuilt into the statement that
    -- would create it. This is the one text a hash is ever taken from, whichever way
    -- the lock was opened, which is what lets a lock taken by hand and a lock taken
    -- by a compile fingerprint the same object identically.
    --
    -- user_source carries all five PL/SQL types, triggers included, and it stores
    -- what the developer actually typed after CREATE OR REPLACE, so putting that
    -- prefix back reproduces the compiled statement character for character. Views
    -- keep their query text and get a canonical header instead, since no two clients
    -- write that header the same way. An object the dictionary has nothing for
    -- answers NULL, and a lock is still taken, just without a fingerprint
    --
    FUNCTION source_object (
        in_object_type      core_locks.object_type%TYPE,
        in_object_name      core_locks.object_name%TYPE
    )
    RETURN CLOB
    AS
        v_out           CLOB;
    BEGIN
        IF in_object_type = 'VIEW' THEN
            v_out := view_query(in_object_name);
            --
            IF v_out IS NULL THEN
                RETURN NULL;
            END IF;
            --
            RETURN 'CREATE OR REPLACE VIEW ' || in_object_name || ' AS' || CHR(10) || v_out;
        END IF;
        --
        FOR c IN (
            SELECT
                t.text
            FROM user_source t
            WHERE t.name        = in_object_name
                AND t.type      = in_object_type
            ORDER BY
                t.line
        ) LOOP
            v_out := v_out || c.text;
        END LOOP;
        --
        IF v_out IS NULL THEN
            RETURN NULL;
        END IF;
        --
        RETURN 'CREATE OR REPLACE ' || v_out;
    EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
    END;



    --
    -- The object without its CREATE header, which is the only text worth hashing.
    --
    -- Two things write a payload here and they disagree on that header and on nothing
    -- else. The trigger keeps the statement a developer typed; a lock taken by hand
    -- rebuilds one from the dictionary, which uppercases nothing, quotes the name and
    -- prints a view's column list. Drop the header and the two agree character for
    -- character, which is what lets a lock booked by hand and a lock taken by a
    -- compile talk about the same object.
    --
    -- The header is always the first line, so this walks lines rather than cutting the
    -- CLOB: SUBSTR over a CLOB comes back as a varchar and would silently truncate a
    -- package at 32k. A view loses everything through its first standalone AS, since
    -- the dictionary keeps only the query text; anything else loses the CREATE, the
    -- optional OR REPLACE, and the EDITIONABLE and FORCE that only the dictionary adds
    --
    FUNCTION object_body (
        in_object_type      core_locks.object_type%TYPE,
        in_payload          CLOB
    )
    RETURN CLOB
    AS
        v_out           CLOB;
        v_line          CLOB;
    BEGIN
        IF in_payload IS NULL THEN
            RETURN NULL;
        END IF;
        --
        FOR c IN (
            SELECT
                t.column_value,
                ROWNUM AS r#
            FROM TABLE(APEX_STRING.SPLIT_CLOBS(
                p_str => in_payload,
                p_sep => CHR(10)
            )) t
        ) LOOP
            v_line := c.column_value;
            --
            IF c.r# = 1 THEN
                IF in_object_type IN ('VIEW', 'MATERIALIZED VIEW') THEN
                    v_line  := REGEXP_REPLACE(v_line, '^.*?\sAS\s|^.*?\sAS$', '', 1, 1, 'i');
                ELSE
                    v_line  := REGEXP_REPLACE(v_line, '^\s*CREATE\s+(OR\s+REPLACE\s+)?((NON)?EDITIONABLE\s+)?(FORCE\s+)?', '', 1, 1, 'i');
                END IF;
            END IF;
            --
            v_out := v_out || v_line || CHR(10);
        END LOOP;

        -- a header written on its own line leaves an empty one behind, and a header
        -- sharing the line with the body does not, so drop the leading whitespace
        -- instead of letting the developer's line breaks decide the hash
        v_out := LTRIM(v_out, CHR(10) || CHR(13) || CHR(9) || ' ');
        v_out := RTRIM(v_out, CHR(10) || CHR(13) || CHR(9) || ' ');

        -- and drop the trailing terminator, which is the client's punctuation rather
        -- than the object's source. SQL*Plus hands over a statement ending in a
        -- newline and the dictionary's copy ends on the END, so a rule that reads the
        -- last LINE gets a different answer for the same object depending on who
        -- compiled it. Reading the last CHARACTER of the whole text does not.
        -- DBMS_LOB rather than SUBSTR, which would cut a big package down to a varchar
        IF NVL(LENGTH(v_out), 0) > 0
            AND NOT REGEXP_LIKE(DBMS_LOB.SUBSTR(v_out, 1, LENGTH(v_out)), '[[:alnum:]_]')
        THEN
            DBMS_LOB.TRIM(v_out, LENGTH(v_out) - 1);
        END IF;
        --
        RETURN v_out;
    END;



    --
    -- The object as the dictionary holds it, for a lock taken outside the DDL trigger
    -- where there is no statement to read. The dictionary's own source comes first,
    -- because DBMS_METADATA reprints rather than repeats: asked for a PACKAGE it
    -- hands back the spec AND the body, asked for a TRIGGER it appends an ALTER
    -- TRIGGER ... ENABLE, and neither of those is the object you locked. It stays as
    -- the fallback for the types user_source and user_views cannot answer, a table
    -- among them. It needs no grant for the caller's own objects, and an object that
    -- is not there raises ORA-31603, which answers NULL and locks without a backup
    --
    FUNCTION dict_object (
        in_object_type      core_locks.object_type%TYPE,
        in_object_name      core_locks.object_name%TYPE
    )
    RETURN CLOB
    AS
        v_out           CLOB := source_object(in_object_type, in_object_name);
    BEGIN
        IF v_out IS NOT NULL THEN
            RETURN v_out;
        END IF;
        --
        -- the metadata API spells a two-word type with an underscore
        RETURN DBMS_METADATA.GET_DDL(REPLACE(in_object_type, ' ', '_'), in_object_name);
    EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
    END;



    FUNCTION get_object (
        in_object_type      core_locks.object_type%TYPE     := NULL,
        in_object_name      core_locks.object_name%TYPE     := NULL
    )
    RETURN CLOB
    AS
        v_sql_text      ora_name_list_t;            -- TABLE OF VARCHAR2(64);
        v_temp          CLOB;
        v_out           CLOB;
        v_rows          PLS_INTEGER;
        v_alter         BOOLEAN := FALSE;
        v_drop          BOOLEAN := FALSE;
    BEGIN
        g_alter_compile := FALSE;
        g_drop_event    := FALSE;

        -- get object source into a CLOB. ora_sql_txt carries a statement only inside
        -- a DDL trigger and raises anywhere else, which is what stopped create_lock
        -- from being callable by hand
        BEGIN
            FOR i IN 1 .. ora_sql_txt(v_sql_text) LOOP
                v_temp := v_temp || TO_CLOB(v_sql_text(i));
            END LOOP;
        EXCEPTION
        WHEN OTHERS THEN
            v_temp := NULL;
        END;

        -- ora_sql_txt hands the statement over in 64 byte chunks and the last one
        -- carries a C string terminator on the end. That is transport noise, not
        -- source, and it is what the old last-line rule was really removing, which is
        -- also why nobody noticed the rule eating a real character everywhere else
        v_temp := REPLACE(v_temp, CHR(0));

        -- no statement means this was called by hand, so ask the dictionary instead
        IF v_temp IS NULL AND in_object_name IS NOT NULL THEN
            v_temp := dict_object(in_object_type, in_object_name);
        END IF;

        -- tweak the CLOB slightly so it matches for different clients
        FOR c IN (
            SELECT
                t.column_value,
                t.r#,
                COUNT(*) OVER() AS total#
            FROM (
                SELECT
                    t.column_value,
                    ROWNUM AS r#
                FROM TABLE(APEX_STRING.SPLIT_CLOBS(
                    p_str => v_temp,
                    p_sep => CHR(10)
                )) t
            ) t
        ) LOOP
            -- fix wrong first line, uppercase it
            IF c.r# = 1 THEN
                c.column_value := REPLACE(REPLACE(REPLACE(c.column_value, 'create ', 'CREATE '), ' replace', ' REPLACE'), ' or ', ' OR ');
                --
                IF UPPER(c.column_value) LIKE 'ALTER%' THEN
                    v_alter := TRUE;
                END IF;
                --
                -- case insensitive, because the uppercase pass above only fixes the
                -- CREATE spellings and a developer types DROP in whatever case they like
                IF REGEXP_LIKE(c.column_value, '^\s*DROP\s', 'i') THEN
                    v_drop := TRUE;
                END IF;
            END IF;

            -- the last line used to be stripped here, to drop the terminator a client
            -- may or may not send. It was written REGEXP_REPLACE(line, '[^\w]$', '')
            -- and Oracle reads \w as the plain letter, so the class matched everything
            -- except w and a backslash and ate the last real character: measured on
            -- 26ai, "dual" came back as "dua" and "ENABLE" as "ENABL". It was invisible
            -- because a statement ending in a newline splits into an empty last line
            -- and the strip landed on that instead of on the source. The payload is a
            -- backup and gets to keep every character it arrived with; the terminator
            -- is normalized in object_body, where the comparing is done
            v_out := v_out || c.column_value || CHR(10);
            --
            v_rows := c.total#;
        END LOOP;
        --
        IF v_alter AND INSTR(UPPER(v_out), 'COMPILE') > 0 THEN
            g_alter_compile := TRUE;
            RETURN NULL;
        END IF;

        -- a DROP still opens a lock, it is just not a source of one. Handing the
        -- statement back would put "DROP PROCEDURE X" in the payload column where the
        -- object's own text belongs, and fingerprint that instead of the object
        IF v_drop THEN
            g_drop_event := TRUE;
            RETURN NULL;
        END IF;
        --
        RETURN v_out;
    END;



    FUNCTION get_clob_hash (
        in_payload          CLOB,
        in_type             PLS_INTEGER := NULL
    )
    RETURN VARCHAR2
    AS
    BEGIN
        IF in_payload IS NULL THEN
            RETURN NULL;
        END IF;
        --
        RETURN DBMS_CRYPTO.HASH(in_payload, NVL(in_type, DBMS_CRYPTO.HASH_SH256));
    EXCEPTION
    WHEN OTHERS THEN
        raise_error();
    END;

END;
/

