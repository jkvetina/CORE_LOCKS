#!/bin/sh
#
# Install the CORE_LOCKS test suites and run them, from anywhere.
#
#   database/tests/run.sh -c core_locks/core_locks@localhost:1521/FREEPDB1
#   database/tests/run.sh -c <connect> --install-only
#   database/tests/run.sh -c <connect> --run-only
#   database/tests/run.sh -c <connect> --sqlplus /path/to/sqlplus
#   database/tests/run.sh -c <connect> -x <proxy-connect>
#   database/tests/run.sh -c <connect> --no-proxy
#   database/tests/run.sh -c <connect> --anon [container]
#
# The SQL scripts use repo-relative @ paths, so they have to be run from the
# repository root. This finds the root from its own location and goes there, so
# the caller does not have to.
#
# Three runs, not one, because two of the suites are decided by the connection they
# arrive on and neither can be arranged from inside a session:
#
#   proxy   needs SYS_CONTEXT('USERENV','PROXY_USER'), which is fixed at connect
#           time. Without -x the proxy connect string is derived from -c, since
#           create_test_user.sql builds exactly one proxy account for one schema.
#   anon    needs a session with no IP address at all, which means a local IPC or
#           bequeath connection on the database host itself. --anon delegates to
#           run_anon.sh, which knows how to reach one inside a container.
#
# Both are tagged out of the main run and asked for by name.
#
# --no-proxy skips the proxy run and says so on stdout; the anon run is off unless
# --anon is given and says so too. Neither is ever silent, because a suite that
# quietly stops running part of itself is the failure this whole file exists to
# avoid. The anon run is opt-in rather than opt-out because it needs a shell on the
# database host, which the ordinary caller of this script does not have.
#
# Exit status is the suite's: run.sql raises on a failed test, on a missing
# summary line, and on a run that executed no tests at all. run_proxy.sql and
# run_anon.sql raise on all of those plus a run that found fewer tests than the
# suite declares.
#
set -eu

CONNECT=""
PROXY_CONNECT=""
SQLPLUS="sqlplus"
DO_INSTALL=1
DO_RUN=1
DO_PROXY=1
DO_ANON=0
ANON_CONTAINER=""

usage() {
    echo "usage: $0 -c <connect-string> [-x <proxy-connect>] [--no-proxy]" >&2
    echo "          [--anon [container]] [--install-only] [--run-only] [--sqlplus <path>]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--connect)   CONNECT="${2:-}"; shift 2 ;;
        -x|--proxy)     PROXY_CONNECT="${2:-}"; shift 2 ;;
        --sqlplus)      SQLPLUS="${2:-}"; shift 2 ;;
        --install-only) DO_RUN=0; DO_PROXY=0; DO_ANON=0; shift ;;
        --run-only)     DO_INSTALL=0; shift ;;
        --no-proxy)     DO_PROXY=0; shift ;;
        --anon)
            DO_ANON=1
            shift
            # the container name is optional, so anything that looks like the next
            # flag is the next flag and not a container called --run-only
            case "${1:-}" in
                ""|-*)  ;;
                *)      ANON_CONTAINER="$1"; shift ;;
            esac
            ;;
        -h|--help)      usage ;;
        *)              echo "unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$CONNECT" ] || usage

# core_locks/core_locks@host:port/service  ->  CLUT_PROXY[core_locks]/clut_proxy@host:port/service
if [ "$DO_PROXY" -eq 1 ] && [ -z "$PROXY_CONNECT" ]; then
    CONNECT_USER=${CONNECT%%/*}
    CONNECT_REST=${CONNECT#*@}
    PROXY_CONNECT="CLUT_PROXY[${CONNECT_USER}]/clut_proxy@${CONNECT_REST}"
fi

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$REPO_ROOT"

if [ "$DO_INSTALL" -eq 1 ]; then
    "$SQLPLUS" -S "$CONNECT" @database/tests/install.sql
fi

if [ "$DO_RUN" -eq 1 ]; then
    "$SQLPLUS" -S "$CONNECT" @database/tests/run.sql
fi

if [ "$DO_PROXY" -eq 1 ]; then
    "$SQLPLUS" -S "$PROXY_CONNECT" @database/tests/run_proxy.sql
elif [ "$DO_RUN" -eq 1 ]; then
    echo "PROXY SUITE SKIPPED: --no-proxy was passed, so PROXY_USER is untested."
fi

if [ "$DO_ANON" -eq 1 ]; then
    if [ -n "$ANON_CONTAINER" ]; then
        database/tests/run_anon.sh --container "$ANON_CONTAINER"
    else
        database/tests/run_anon.sh
    fi
elif [ "$DO_RUN" -eq 1 ]; then
    echo "ANON SUITE SKIPPED: --anon was not passed, so the refusal of a nameless session is untested."
fi
