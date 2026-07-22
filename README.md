# CORE_LOCKS

## Object locking and source backup for shared Oracle schemas — standalone, no framework required

<br>
<p><img src="docs/one_pager_comix.png" alt="CORE_LOCKS comix"></p>
<br>

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Prerequisites & Requirements](#2-prerequisites--requirements)
3. [Installation & Setup](#3-installation--setup)
4. [How It Works](#4-how-it-works)
5. [API Reference](#5-api-reference)
6. [Configuration](#6-configuration)
7. [Operational Notes](#7-operational-notes)

---

## 1. Project Overview

**CORE_LOCKS** answers a single question on a shared development schema: *who last touched this object, and am I about to overwrite their work?*

It hooks every DDL statement in the schema, records who ran it, keeps a copy of the source, and refuses a compile when someone else already holds a live lock on that object. Two developers compiling the same package no longer silently overwrite each other — the second one gets an error instead of a surprise.

This repo is extracted from the author's [CORE23](https://github.com/jkvetina/CORE23) framework. In CORE23, the LOCK feature depends on the `CORE` and `CORE_CUSTOM` packages plus the `CORE_LOGS` table — roughly 6,300 lines of framework for what is really a self-contained idea. This version cuts that away.

**Key characteristics:**

- **Five objects** — one table, one package, one trigger, two jobs
- **No framework** — no `CORE`, no `CORE_CUSTOM`, no logging tables
- **Source backup included** — every lock row carries a copy of the object's DDL
- **Drop-in** — install into any schema that has APEX available

---

## 2. Prerequisites & Requirements

Oracle Database 12c or later (identity columns are used for `lock_id`).

Two grants are required from `SYS`:

```sql
GRANT EXECUTE ON dbms_crypto TO <schema>;      -- SHA-256 source hashing
GRANT EXECUTE ON dbms_scheduler TO <schema>;   -- the locksmith enable job
```

`APEX_STRING` must be reachable — `get_object` uses `APEX_STRING.SPLIT_CLOBS` to normalize the captured DDL. `DBMS_OUTPUT` is used by `unlock` for feedback.

Every developer must reach the schema under an identifiable name: either connect through a proxy user or set `CLIENT_IDENTIFIER` (`DBMS_SESSION.SET_IDENTIFIER`). The `core_locksmith` trigger refuses tracked DDL from a session that has neither — `USER_ERROR: USE_PROXY_USER_OR_SET_CLIENT_ID` — so the compile fails. Generic shared logins are rejected by design, since a lock owned by "the schema account" tells you nothing. For the lock owner's name, `core_lock.get_user` resolves, in order, the proxy user, then `CLIENT_IDENTIFIER`, then `CLIENT_INFO`.

---

## 3. Installation & Setup

Install in this order — the package body will not compile before the table exists, and the trigger needs the package:

```
database/tables/core_locks.sql
database/packages/core_lock.spec.sql
database/packages/core_lock.sql
database/triggers/core_locksmith.sql
database/jobs/core_locksmith_enable.sql
database/jobs/core_locks_purge.sql
```

Both jobs are optional but recommended; see [Operational Notes](#7-operational-notes) for what they do and why they matter.

---

## 4. How It Works

`core_locksmith` fires `AFTER DDL ON SCHEMA`. It ignores `DEPSCAN$%` procedures (dependency-scanner noise) and anything named `CORE_LOCK%`, so the feature cannot lock itself out. For `CREATE`, `ALTER`, and `DROP` on tables, views, materialized views, packages, package bodies, procedures, functions, and triggers, it first refuses the statement outright when the session has neither a proxy user nor a `CLIENT_IDENTIFIER` set — no anonymous compiles — and then calls `core_lock.create_lock`.

`create_lock` captures the statement's own text through `ora_sql_txt`, normalizes the first and last line so the same source compiled by different clients hashes identically, and skips `ALTER ... COMPILE` entirely — recompiling is not a change. Source-bearing object types are hashed with SHA-256.

It then reads the most recent lock row for that object and decides:

| Situation | Outcome |
|---|---|
| Same user holds the lock | Lock extended, source and hash refreshed |
| Different user, lock still live | `LOCK_TIME_ERROR: OBJECT_LOCKED_BY ...` — DDL fails |
| Hash differs from the stored one, within a minute of the lock | `LOCK_HASH_ERROR: OBJECT_CHANGED_BY ...` — DDL fails |
| Lock older than the rebook window | Current row closed, new row inserted as a fresh backup point |
| No lock at all | New row inserted |

The hash check is the subtle one. When you take an object over from someone else, compile it once **unchanged** first. That proves your source matches what is actually in the database, and only then should you apply your edits — otherwise you are compiling over changes made while you were not looking.

Because each rebook writes a new row rather than updating in place, `core_locks` accumulates a history of the object's source over time, not just its current state. That history is kept in full for the last 7 days; beyond that the `CORE_LOCKS_PURGE` job collapses it to one hash-only row per object (see [Operational Notes](#7-operational-notes)).

---

## 5. API Reference

All procedures run as autonomous transactions and commit on their own — they must, since they are driven from a DDL trigger.

### Create lock

`create_lock` is called by the trigger; rarely called by hand.

```sql
core_lock.create_lock (
    in_object_owner     => 'APPS',
    in_object_type      => 'PACKAGE BODY',
    in_object_name      => 'MY_PACKAGE',
    in_locked_by        => NULL,     -- defaults to get_user()
    in_expire_at        => NULL,     -- defaults to now + g_lock_length
    in_hash_check       => TRUE
);
```

### Unlock

`unlock` releases a lock. At least one of `in_lock_id`, `in_locked_by`, or `in_object_name` must be passed, otherwise it raises `ARGUMENTS_MISSING`. Reports each released object through `DBMS_OUTPUT`.

```sql
BEGIN
    core_lock.unlock(in_object_name => 'MY_PACKAGE');   -- free one object
    core_lock.unlock(in_locked_by   => 'JAN');          -- free everything a user holds
END;
/
```

### Extend lock

`extend_lock` pushes the expiry out and refreshes the stored source and hash. Overloaded — pass a number of days, or an explicit date.

```sql
core_lock.extend_lock(in_lock_id => 10001, in_time => 60/1440);   -- +60 minutes
core_lock.extend_lock(in_lock_id => 10001, in_expire_at => SYSDATE + 1);
```

### Purge

`purge_locks` is the retention rule, run daily at 03:00 by the `CORE_LOCKS_PURGE` job. Rows younger than `g_purge_after` (7 days) are never touched, and neither is any still-live lock. Beyond the window, each unique object collapses to its newest row — that row keeps the SHA-256 hash, owner, and timestamps but has its `object_payload` CLOB set to NULL; the older history rows are deleted. Safe to run by hand; it reports its row counts through `DBMS_OUTPUT`.

```sql
core_lock.purge_locks();
```

### Raise error

`raise_error` raises `ORA-20990` carrying the message, with `keeperrorstack` on. It is public because the trigger calls it from its own `WHEN OTHERS`. The matching `core_lock.app_exception` is pinned to the same code, so an APEX error handler already tuned to CORE23 keeps recognizing these errors unchanged.

### Helpers

`get_user`, `get_audit_trail`, `get_object`, and `get_clob_hash` are exposed for diagnostics. Note that `get_object` reads `ora_sql_txt` and therefore returns meaningful output **only inside a DDL trigger** — called standalone it returns nothing useful.

---

## 6. Configuration

Constants at the top of the package body:

| Constant | Default | Meaning |
|---|---|---|
| `g_lock_length` | 20 minutes | How long a new lock stays live |
| `g_lock_rebook` | 10 minutes | Age past which a new backup row is cut instead of extending |
| `g_check_hash` | `TRUE` | Master switch for the source-hash comparison |
| `g_purge_after` | 7 days | History younger than this is never purged |

Lock numbering starts at 10000, assigned by the identity column on `core_locks.lock_id`.

---

## 7. Operational Notes

**This trigger can block every DDL in the schema.** It is `AFTER DDL ON SCHEMA` and it raises. A bug in `core_lock`, a missing `DBMS_CRYPTO` grant, or a developer connecting without an identifiable username will fail *all* DDL — including the DDL needed to fix the package. Install it on a dev schema first and understand the escape hatch before putting it anywhere that matters.

**The escape hatch is not just disabling the trigger.** `CORE_LOCKSMITH_ENABLE` is a scheduler job that runs `ALTER TRIGGER CORE_LOCKSMITH ENABLE` every five minutes. That is the point — it stops the trigger from being quietly switched off and left off. But it also means this is not enough:

```sql
ALTER TRIGGER core_locksmith DISABLE;   -- comes back within 5 minutes
```

To actually stop the feature you must disable the job as well:

```sql
BEGIN
    DBMS_SCHEDULER.DROP_JOB('CORE_LOCKSMITH_ENABLE', TRUE);
    EXECUTE IMMEDIATE 'ALTER TRIGGER core_locksmith DISABLE';
END;
/
```

**It affects everyone on the schema, not just you.** On a shared dev database, installing this changes the deployment experience for every developer and every automated pipeline touching that schema. That is the feature working as intended, but it is a team decision rather than a personal one.

**`core_locks` grows — the purge job caps it.** Every rebook writes a new row carrying a full CLOB copy of the object source, and the CLOB is where virtually all of the segment size lives. The `CORE_LOCKS_PURGE` job (daily, 03:00) applies the retention rule: the last 7 days stay untouched as a working source backup; beyond that, each unique object keeps exactly one row — its newest, with the hash but without the payload — and the rest of the history is deleted. Live locks are never touched. The trade-off is deliberate: after 7 days you lose the old source text and the per-compile history, but you keep who last touched each object, when, and its source fingerprint.

Freed space is reused by new rows, so the segment stops growing but does not shrink on its own. To hand space back to the tablespace after the first purge of a large backlog, run once:

```sql
ALTER TABLE core_locks ENABLE ROW MOVEMENT;
ALTER TABLE core_locks SHRINK SPACE CASCADE;
ALTER TABLE core_locks DISABLE ROW MOVEMENT;
```
