#!/bin/sh
#
# Install the CORE_LOCKS test suites and run them, from anywhere.
#
#   database/tests/run.sh -c core_locks/core_locks@localhost:1521/FREEPDB1
#   database/tests/run.sh -c <connect> --install-only
#   database/tests/run.sh -c <connect> --run-only
#   database/tests/run.sh -c <connect> --sqlplus /path/to/sqlplus
#
# The SQL scripts use repo-relative @ paths, so they have to be run from the
# repository root. This finds the root from its own location and goes there, so
# the caller does not have to.
#
# Exit status is the suite's: run.sql raises on a failed test, on a missing
# summary line, and on a run that executed no tests at all.
#
set -eu

CONNECT=""
SQLPLUS="sqlplus"
DO_INSTALL=1
DO_RUN=1

usage() {
    echo "usage: $0 -c <connect-string> [--install-only] [--run-only] [--sqlplus <path>]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--connect)   CONNECT="${2:-}"; shift 2 ;;
        --sqlplus)      SQLPLUS="${2:-}"; shift 2 ;;
        --install-only) DO_RUN=0; shift ;;
        --run-only)     DO_INSTALL=0; shift ;;
        -h|--help)      usage ;;
        *)              echo "unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$CONNECT" ] || usage

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$REPO_ROOT"

if [ "$DO_INSTALL" -eq 1 ]; then
    "$SQLPLUS" -S "$CONNECT" @database/tests/install.sql
fi

if [ "$DO_RUN" -eq 1 ]; then
    "$SQLPLUS" -S "$CONNECT" @database/tests/run.sql
fi
