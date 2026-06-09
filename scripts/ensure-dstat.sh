#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=machine-passwords.sh
. "$SCRIPT_DIR/machine-passwords.sh"

INSTALL_DSTAT="${INSTALL_DSTAT:-true}"

machine_host() {
    case "$1" in
        brazil-01) printf '%s\n' '130.94.106.105' ;;
        brazil-02) printf '%s\n' '130.94.107.80' ;;
        brazil-03) printf '%s\n' '130.94.107.139' ;;
        brazil-04) printf '%s\n' '130.94.106.176' ;;
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
  brazil-01
  brazil-02
  brazil-03
  brazil-04
)

if [ -n "${MACHINES_OVERRIDE:-}" ]; then
    read -r -a MACHINES <<< "$MACHINES_OVERRIDE"
else
    MACHINES=("${DEFAULT_MACHINES[@]}")
fi

usage() {
    cat <<'EOF'
Usage:
  scripts/ensure-dstat.sh

Defaults:
  Checks and installs dstat on brazil-01, brazil-02, brazil-03, brazil-04.

Examples:
  ./scripts/ensure-dstat.sh
  MACHINES_OVERRIDE="brazil-01 brazil-02 brazil-03 brazil-04" ./scripts/ensure-dstat.sh
  INSTALL_DSTAT=false ./scripts/ensure-dstat.sh

INSTALL_DSTAT=false only checks presence and does not install.
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

ensure_machine() {
    machine="$1"

    host="$(machine_host "$machine" || true)"
    password="$(machine_password "$machine" || true)"

    if [ -z "$host" ] || [ -z "$password" ]; then
        echo "[$machine] unknown machine"
        return 1
    fi

    echo "[$machine] checking dstat"

    sshpass -p "$password" \
        ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=30 \
        root@"$host" "
            set -u

            if command -v dstat >/dev/null 2>&1; then
                echo 'dstat present: '\$(command -v dstat)
                dstat --version 2>/dev/null || true
                exit 0
            fi

            if [ '$INSTALL_DSTAT' != 'true' ]; then
                echo 'dstat missing; install disabled'
                exit 1
            fi

            echo 'dstat missing; installing'

            if command -v apt-get >/dev/null 2>&1; then
                export DEBIAN_FRONTEND=noninteractive
                apt-get update
                apt-get install -y dstat || apt-get install -y pcp
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y dstat || dnf install -y pcp
            elif command -v yum >/dev/null 2>&1; then
                yum install -y dstat || yum install -y pcp
            else
                echo 'No supported package manager found'
                exit 1
            fi

            if command -v dstat >/dev/null 2>&1; then
                echo 'dstat installed: '\$(command -v dstat)
                dstat --version 2>/dev/null || true
                exit 0
            fi

            echo 'dstat still missing after install'
            exit 1
        "
}

overall_status=0

for machine in "${MACHINES[@]}"
do
    if ensure_machine "$machine"; then
        echo "[$machine] OK"
    else
        echo "[$machine] FAILED"
        overall_status=1
    fi
done

exit "$overall_status"
