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
#
# The SQL scripts use repo-relative @ paths, so they have to be run from the
# repository root. This finds the root from its own location and goes there, so
# the caller does not have to.
#
# Two runs, not one. The proxy suite needs SYS_CONTEXT('USERENV','PROXY_USER'),
# which is set when a session connects and cannot be arranged from inside one, so
# those tests are tagged out of the main run and asked for by name on a second
# connection. Without -x the proxy connect string is derived from -c, since
# create_test_user.sql builds exactly one proxy account for exactly one schema.
#
# --no-proxy skips that second run and says so on stdout. It is for a database
# where the proxy grant was never made; it is not the quiet default, because a
# suite that silently stops running a third of itself is the failure this whole
# file exists to avoid.
#
# Exit status is the suite's: run.sql raises on a failed test, on a missing
# summary line, and on a run that executed no tests at all. run_proxy.sql raises
# on all of those plus a run that found fewer proxy tests than the suite declares.
#
set -eu

CONNECT=""
PROXY_CONNECT=""
SQLPLUS="sqlplus"
DO_INSTALL=1
DO_RUN=1
DO_PROXY=1

usage() {
    echo "usage: $0 -c <connect-string> [-x <proxy-connect>] [--no-proxy]" >&2
    echo "          [--install-only] [--run-only] [--sqlplus <path>]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--connect)   CONNECT="${2:-}"; shift 2 ;;
        -x|--proxy)     PROXY_CONNECT="${2:-}"; shift 2 ;;
        --sqlplus)      SQLPLUS="${2:-}"; shift 2 ;;
        --install-only) DO_RUN=0; DO_PROXY=0; shift ;;
        --run-only)     DO_INSTALL=0; shift ;;
        --no-proxy)     DO_PROXY=0; shift ;;
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
