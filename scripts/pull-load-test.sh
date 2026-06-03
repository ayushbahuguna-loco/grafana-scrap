#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=machine-passwords.sh
. "$SCRIPT_DIR/machine-passwords.sh"

GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-perf/viewer}"

machine_host() {
    case "$1" in
        brazil-01) printf '%s\n' '130.94.106.105' ;;
        brazil-02) printf '%s\n' '130.94.107.80' ;;
        brazil-03) printf '%s\n' '130.94.107.139' ;;
        philippines-01) printf '%s\n' '38.60.246.239' ;;
        philippines-02) printf '%s\n' '38.54.36.76' ;;
        philippines-03) printf '%s\n' '38.54.87.127' ;;
        turkey-01) printf '%s\n' '38.60.208.217' ;;
        turkey-02) printf '%s\n' '130.94.1.175' ;;
        turkey-03) printf '%s\n' '38.54.105.77' ;;
        *) return 1 ;;
    esac
}


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
    cd ~/load-test && git pull origin perf/viewer

Examples:
  ./scripts/pull-load-test.sh
  MACHINES_OVERRIDE="brazil-01 brazil-02 brazil-03" ./scripts/pull-load-test.sh
  GIT_BRANCH=main ./scripts/pull-load-test.sh
  GIT_REMOTE=upstream GIT_BRANCH=perf/viewer ./scripts/pull-load-test.sh
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if ! command -v sshpass >/dev/null 2>&1; then
    echo "sshpass not found"
    exit 1
fi

pull_machine() {
    machine="$1"

    host="$(machine_host "$machine" || true)"
    password="$(machine_password "$machine" || true)"

    if [ -z "$host" ] || [ -z "$password" ]; then
        echo "[$machine] unknown machine"
        return 1
    fi

    echo ""
    echo "===================================="
    echo "[$machine] pulling $GIT_REMOTE $GIT_BRANCH"
    echo "===================================="

    sshpass -p "$password" \
        ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        root@"$host" \
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
