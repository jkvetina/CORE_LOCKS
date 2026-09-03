#!/bin/sh
#
# Run the anon suite on a connection that carries no address.
#
#   database/tests/run_anon.sh
#   database/tests/run_anon.sh --container local-26ai
#   database/tests/run_anon.sh --container-bin /opt/homebrew/opt/container/bin/container
#   database/tests/run_anon.sh --connect core_locks/core_locks --service FREEPDB1
#
# core_lock.get_user ends its ladder on the session's IP address, so every TCP
# connection resolves to somebody and the locksmith's refusal of an anonymous
# session cannot be reached from one. A local IPC connection has no address, and the
# OS user behind it is the database's own service account, which clean_user reduces
# to nobody. That connection exists only inside the database host, so when the
# database runs in a container this script has to step inside it to make the call.
#
# It is a separate file from run.sh on purpose. run.sh drives a database through a
# connect string and knows nothing about where that database lives; everything the
# container runtime is called and how you get a shell inside it lives here, in the
# one script whose whole subject is reaching a host-local connection.
#
# The SQL arrives on stdin rather than as an @ path, because the repository is not
# mounted inside the container and a script the container cannot open is the one
# failure that looks exactly like an empty green run.
#
set -eu

CONTAINER="local-26ai"
CONTAINER_BIN=""
CONNECT="core_locks/core_locks"
SERVICE="FREEPDB1"
IPC_KEY="EXTPROC1521"
SQLPLUS="sqlplus"

usage() {
    echo "usage: $0 [--container <name>] [--container-bin <path>] [--connect <user/pass>]" >&2
    echo "          [--service <name>] [--key <ipc-key>] [--sqlplus <name>]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --container)     CONTAINER="${2:-}"; shift 2 ;;
        --container-bin) CONTAINER_BIN="${2:-}"; shift 2 ;;
        -c|--connect)    CONNECT="${2:-}"; shift 2 ;;
        --service)       SERVICE="${2:-}"; shift 2 ;;
        --key)           IPC_KEY="${2:-}"; shift 2 ;;
        --sqlplus)       SQLPLUS="${2:-}"; shift 2 ;;
        -h|--help)       usage ;;
        *)               echo "unknown argument: $1" >&2; usage ;;
    esac
done

# whatever is on PATH first, and Homebrew's own location only as a fallback: the
# runtime is normally on PATH, and a hard-coded prefix that happens to exist is how
# a script starts working on one machine and silently nowhere else
if [ -z "$CONTAINER_BIN" ]; then
    for candidate in container podman docker /opt/homebrew/opt/container/bin/container; do
        if command -v "$candidate" >/dev/null 2>&1; then
            CONTAINER_BIN="$candidate"
            break
        fi
    done
fi

if [ -z "$CONTAINER_BIN" ]; then
    echo "ANON: no container runtime found (looked for container, podman, docker)." >&2
    echo "      Pass --container-bin, or run run_anon.sql yourself on a local connection." >&2
    exit 1
fi

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$REPO_ROOT"

# Reported, never skipped. A stopped container and a passing suite are the same
# silence otherwise, and the whole reason this file exists is that the suite it runs
# is invisible from the ordinary connection.
if ! "$CONTAINER_BIN" exec "$CONTAINER" true >/dev/null 2>&1; then
    echo "ANON: cannot get a shell inside container '$CONTAINER' via $CONTAINER_BIN." >&2
    echo "      It is probably not running. Start it and run this again." >&2
    exit 1
fi

DESCRIPTOR="(DESCRIPTION=(ADDRESS=(PROTOCOL=IPC)(KEY=${IPC_KEY}))(CONNECT_DATA=(SERVICE_NAME=${SERVICE})))"

"$CONTAINER_BIN" exec -i "$CONTAINER" "$SQLPLUS" -S "${CONNECT}@${DESCRIPTOR}" \
    < database/tests/run_anon.sql
