#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=machine-passwords.sh
. "$SCRIPT_DIR/machine-passwords.sh"

GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-perf/viewer}"

DEFAULT_MACHINES=(
    turkey-01
    turkey-02
    turkey-03
)

if [ -n "${MACHINES_OVERRIDE:-}" ]; then
    read -r -a MACHINES <<< "$MACHINES_OVERRIDE"
else
    MACHINES=("${DEFAULT_MACHINES[@]}")
fi

usage() {
    cat <<'EOF'
Usage:
  ./scripts/pull-load-test.sh

Defaults:
  SSHes into turkey-01, turkey-02, turkey-03 and runs:
    cd ~/load-test && git stash 

Examples:
  ./scripts/pull-load-test.sh
  MACHINES_OVERRIDE="brazil-01 brazil-02 brazil-03 brazil-04" ./scripts/pull-load-test.sh
  GIT_BRANCH=main ./scripts/pull-load-test.sh
  GIT_REMOTE=upstream GIT_BRANCH=perf/viewer ./scripts/pull-load-test.sh
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if ! require_machine_ssh_tools "${MACHINES[@]}"; then
    exit 1
fi

pull_machine() {
    machine="$1"

    host="$(machine_host "$machine" || true)"

    if [ -z "$host" ]; then
        echo "[$machine] unknown machine"
        return 1
    fi

    echo ""
    echo "===================================="
    echo "[$machine] pulling $GIT_REMOTE $GIT_BRANCH"
    echo "===================================="

    machine_ssh "$machine" \
        "cd ~/load-test && git pull '$GIT_REMOTE' '$GIT_BRANCH'"
}

status=0
for machine in "${MACHINES[@]}"
do
    if pull_machine "$machine"; then
        echo "[$machine] OK"
    else
        echo "[$machine] FAILED"
        status=1
    fi
done

exit "$status"
