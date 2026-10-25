# CORE_LOCKS tests

There are 101 utPLSQL tests in six suites, and they cover every public routine in `core_lock`, every optional argument those routines take, the `core_locksmith` trigger across all three events and every tracked object type, and the three things one session cannot show about itself: a lock seen from another session, an owner the database vouched for, and a session with no name at all.

| File | What it holds |
| --- | --- |
| `database/tests/core_lock_ut.spec.sql` / `.sql` | The package API, called directly. 51 tests |
| `database/tests/core_locksmith_ut.spec.sql` / `.sql` | The DDL trigger, driven by real compiles. 15 tests |
| `database/tests/core_lock_conc_ut.spec.sql` / `.sql` | Two sessions at once, borrowed from the scheduler. 4 tests |
| `database/tests/core_lock_proxy_ut.spec.sql` / `.sql` | Ownership through a proxy connection. 5 tests |
| `database/tests/core_lock_anon_ut.spec.sql` / `.sql` | The refusal of a session that names nobody. 4 tests |
| `database/tests/core_lock_apex_ut.spec.sql` / `.sql` | APEX application and page locks. 22 tests |
| `database/tests/core_lock_fixture.spec.sql` / `.sql` | Actor, probe objects, second sessions, teardown ledger |
| `database/tests/create_test_user.sql` | Creates the throwaway schema and its proxy account, run as SYSDBA |
| `database/tests/install.sql` | Installs product and suites, then proves the install |
| `database/tests/run.sql` | Runs everything except the `proxy`, `anon` and `apex` tags, and fails the session when it is not green |
| `database/tests/run_proxy.sql` | Runs the proxy tag, and refuses a connection that has no proxy user |
| `database/tests/run_anon.sql` | Runs the anon tag, and refuses a connection that has an address |
| `database/tests/run_anon.sh` | Reaches a local connection inside the database's container |
| `database/tests/create_test_apex.sql` | Creates the APEX workspace, its two developers and the page lock grant, run as SYSDBA |
| `database/tests/install_apex.sql` / `core_lock_apex_app.sql` | Installs the two-page application the apex suite locks |
| `database/tests/run_apex.sql` | Runs the apex tag |
| `database/tests/run.sh` | Does all of the above from any working directory |

You need utPLSQL v3 (measured against v3.2.3.4508 on 23ai) and the same `APEX_STRING` and `DBMS_CRYPTO` access the feature itself needs.

```
sqlplus "sys/<password>@<host>:<port>/<service> as sysdba" @database/tests/create_test_user.sql
database/tests/run.sh -c core_locks/core_locks@<host>:<port>/<service> --anon
```

<br>

## Three connections, because three of the tests cannot be faked

`run.sh` makes up to three connections, because what two of the suites test is decided when a session connects and can never be arranged from inside one.

| Connection | Suites | Tests | Why it has to be its own connection |
| --- | --- | --- | --- |
| ordinary | unit, trigger, concurrency | 70 | it is the plain connection everything else is measured against |
| `CLUT_PROXY[CORE_LOCKS]` | proxy | 5 | `PROXY_USER` is fixed at connect time |
| local IPC, inside the host | anon | 4 | only a connection with no IP address resolves to nobody |

The proxy connect string is derived from the first, so the command above is still the whole thing; pass `-x` to give it explicitly, or `--no-proxy` to skip it and be told on stdout that `PROXY_USER` went untested.

The anon run is opt-in rather than opt-out, because it needs a shell on the database host and the ordinary caller of `run.sh` does not have one. Without `--anon` it says so on stdout for the same reason `--no-proxy` does. `--anon [container]` delegates to `run_anon.sh`, which steps inside the container and connects over IPC; the SQL arrives on stdin rather than as an `@` path, since the repository is not mounted in there and a script the container cannot open looks exactly like an empty green run.

Both suites are tagged out of `run.sql` rather than left out of the install. Left in, they would fail on every ordinary run for the connection's reason rather than the product's, and the usual answer to that is `%disabled`, which is a test that never runs again. `run_proxy.sql` and `run_anon.sql` ask for their tag by name and raise when they find fewer tests than the suite declares, so a tag that stops matching is loud instead of quiet.

The apex suite needs no special connection, it needs an APEX 26.2 workspace on the schema, which only `SYS` can create. So it is opt-in the same way: run `create_test_apex.sql` as SYSDBA once, then pass `--apex`, which installs the fixture application and runs the tag. Without it `run.sh` says the APEX locks went untested.

```
sqlplus "sys/<password>@<host>:<port>/<CDB service> as sysdba" @database/tests/create_test_apex.sql
database/tests/run.sh -c core_locks/core_locks@<host>:<port>/<service> --apex
```

The concurrency suite needs no second connection. It hands its work to a `DBMS_SCHEDULER` job, which runs in a slave session with its own SID and its own transaction, so a lock really does have to cross between two sessions to be seen.

<br>

## The anonymous session, and why it takes a third connection

`get_user` ends its ladder on `SYS_CONTEXT('USERENV', 'IP_ADDRESS')`, so any session reached over TCP resolves to something and the refusal of an anonymous session is unreachable from one. A local IPC or bequeath connection carries no address at all, and the OS user behind it is the database's own service account, which `clean_user` reduces to nobody like any other pool account. That is the only connection on which the guard can fire.

utPLSQL sets the client identifier to the name of the test it is about to run, which is the second rung of that same ladder. A session stripped in `before_each` is therefore named again (after the anon suite's own test, of all things) before the body starts, so each test here strips the session as its first statement instead.

Two things enforce the anonymous rule, not one: `create_lock` checks its resolved owner, and the trigger checks earlier so the error arrives before an autonomous transaction opens. Removing either one on its own changes nothing observable, which the mutation sweep confirms. `core_locks.locked_by` is `NOT NULL`, so with both removed the insert fails and the compile is still refused under the same catalogue code. That is why both refusal tests assert the message and not just the code.

<br>

## Give the suite a schema of its own

`core_locksmith` is an `AFTER DDL ON SCHEMA` trigger, so it governs every `CREATE`, `ALTER` and `DROP` in whatever schema it lives in. Install it beside other work and that work inherits it, and if `core_lock` ever goes invalid its `WHEN OTHERS` handler raises and no DDL in that schema succeeds until somebody drops the trigger. So the suite gets a throwaway schema and nothing else shares it.

The two scheduler jobs are not installed by `install.sql`. `CORE_LOCKSMITH_ENABLE` re-enables the trigger every five minutes, and the unit suite switches it off while it compiles its probes, so the job would switch it back on mid-run.

<br>

## Every suite owns its own cleanup

`create_lock`, `extend_lock`, `unlock` and `purge_locks` all carry `PRAGMA AUTONOMOUS_TRANSACTION` and commit inside themselves, and the trigger suite runs DDL, which commits too. There is no savepoint left for utPLSQL to roll back to, so every suite declares `%rollback(manual)`, the fixture commits on purpose, and cleanup is the suite's job. `after_each` tears down, counts what survived, and asserts that the count is zero and that teardown recorded no error. A teardown that swallows its failure is the appearance of cleanup, and with committed fixtures the leftovers are permanent.

The concurrency suite adds scheduler jobs to that count. A racer left behind does not sit still: its start time arrives during somebody else's test and it takes a lock nobody asked for.

<br>

## One holder, measured rather than guaranteed

`create_lock` reads the lock history and then inserts, with nothing serialising the two. The race test releases four sessions at one shared start time rather than launching them one after another, since four calls in sequence is not a race and would pass whatever the code did about simultaneity. Measured on 26ai across six runs of four to six sessions, exactly one holder every time, the rest refused. That is an outcome, not a promise the code makes, and it is written down here so nobody reads the green as a serialisation guarantee.

The test asserts how many racers actually ran before it asserts anything about the result, because one holder is also what an empty table looks like, and a race that never started reads exactly like a guard that worked.

<br>

## Every test has been seen red

Green proves a suite runs; only red proves it asserts. Each of the 77 tests has been failed on purpose by breaking the behaviour it covers, one piece at a time: the header strip in `object_body`, the hash check and the expiry check in `create_lock`, each rule in `clean_user`, every optional argument thrown away in turn, the chunked `LONG` read in `view_query`, the retention window in `purge_locks`, the name, type and event filters in the trigger, the proxy user's place at the top of the ownership ladder, the lock row an extend reads its payload from, and the history read that would stop seeing other sessions if it were scoped to this one. Sixty-six separate breakages across four sweeps, every one of them caught, and every test died to at least one.

The apex suite got its own sweep of 18 breakages, from a lock that drops its comment to an unlock that uses the NULL admin hammer, a page lock that ignores the application lock and a failed page call that keeps the borrowed `APP_USER`. Every one was caught, and each of the 22 tests died to at least one. It found one product bug on the way: APEX raises the same `ORA-20003` for every invalid parameter, so a comment over 4000 characters came back as `NOT_A_WORKSPACE_DEVELOPER` until the translation started reading the parameter name.

A mutation is anchored on the text around it and asserts how many places it expects to match. `extend_lock`'s two overloads carry byte-identical `UPDATE` bodies, so an unanchored find-and-replace hits the first one, leaves the overload under test untouched, and reports a surviving mutant that reads exactly like a coverage hole.

The proxy suite's first test is the exception that proves the rest of it: it asserts the connection really is a proxy connection, so no product mutation can kill it. Its red comes from the other direction, by running the suite on an ordinary connection, where all five fail. Without it, the four that matter would pass on a database with no proxy in it by falling through the ladder to whatever the session happened to offer.

That discipline found two tests that could not fail as first written. One compared a hand-booked lock against a compiled one using probe source whose `CREATE` header was already spelled the way the dictionary spells it, so the two texts matched with the header left on and the strip stopped mattering. The probe headers are lower case and doubly spaced now, which is what a developer actually types and what normalisation cannot close. The other checked the self-exclusion rule by recompiling the trigger itself, and Oracle does not fire a schema DDL trigger for DDL on that same trigger, so the assertion never had anything to be wrong about.

It also found two product bugs, both in behaviour the code claimed to have. A `DROP` was fingerprinted against the object it was destroying and refused as somebody else's change, and a materialized view was tracked under a name the dictionary never uses. Neither showed up in a review of the same code that wrote them.

<br>

## Coverage

84.9% of the 305 lines utPLSQL can cover in `core_lock`, taken at `PLSQL_OPTIMIZE_LEVEL` 2 on APEX 26.2. Most of what stays uncovered in the APEX part cannot run there at all: the version error below 26.2, the fallback for an APEX without lock columns, the missing grant, a page unlock APEX ignored, and an owner-less session, which only the anon connection can make. Quote the optimize level with the number or it does not mean anything; the same code reports several points higher at level 2 than at level 1. Treat it as a floor rather than a target: the next run may not be lower.

`core_locksmith` contributes no lines to that denominator at all, because the profiler does not instrument a DDL trigger, so the tool reports it with a blank line count rather than a low percentage. The 15 tests in the trigger suite drive it through real compiles, and the mutation sweep breaks it on purpose, which is the only evidence that it runs at all. It is also why the tests added for the trigger's own branches move the number by nothing: those lines were never being counted.

Measured over the 90 tests of the ordinary connection, the apex suite included. A coverage runner that selects by suite name has to name the four suites that connection can reach, since neither the proxy suite nor the anon suite can pass on the connection a coverage run makes:

```
adtai ut -schema CORE_LOCKS -name CORE_LOCK_UT,CORE_LOCKSMITH_UT,CORE_LOCK_CONC_UT,CORE_LOCK_APEX_UT -refresh -compact
```

<br>

## Continuous integration

`.github/workflows/tests.yml` runs the whole thing (all three connections) on every push and pull request.

It runs on a self-hosted macOS runner rather than a GitHub-hosted one, and the reason is `APEX_STRING`. A hosted runner would have to stand up Oracle Free and then install APEX into it before a single test could run, which is roughly half an hour of setup in front of a four-second suite; the self-hosted runner talks to a database that already has both. It also makes the anon suite reachable, which needs a shell on the database host.

The workflow names no path on that machine. The connect string defaults to the throwaway one `create_test_user.sql` already documents, and `CORE_LOCKS_SQLPLUS` and `CORE_LOCKS_CONTAINER` are repository variables with defaults, so the runner's own environment decides where `sqlplus` and the container runtime live.

The first step asks the database whether it is open, as its own named step. A database that is down fails every later step anyway, but it fails them as "the tests did not pass", which is the one thing it does not mean.

The job is guarded against forks. This repository is public and the runner is somebody's own machine, so a pull request opened from a fork would be a stranger's code running on it. The job's `if` holds for a push and for a pull request raised from a branch of this repository, and fails for every fork, which skips the job rather than running it.
