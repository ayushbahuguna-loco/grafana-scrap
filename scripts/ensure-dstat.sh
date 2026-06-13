#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=machine-passwords.sh
. "$SCRIPT_DIR/machine-passwords.sh"

INSTALL_DSTAT="${INSTALL_DSTAT:-true}"

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

if ! require_machine_ssh_tools "${MACHINES[@]}"; then
    exit 1
fi

ensure_machine() {
    machine="$1"

    host="$(machine_host "$machine" || true)"

    if [ -z "$host" ]; then
        echo "[$machine] unknown machine"
        return 1
    fi

    echo "[$machine] checking dstat"

    machine_ssh "$machine" "
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

            if command -v sar >/dev/null 2>&1 && grep -Eq '^ID=\"?amzn\"?' /etc/os-release 2>/dev/null; then
                echo 'dstat missing on Amazon Linux; sysstat fallback present: '\$(command -v sar)
                exit 0
            fi

            echo 'dstat missing; installing'

            SUDO=''
            if [ \"\$(id -u)\" -ne 0 ]; then
                if ! command -v sudo >/dev/null 2>&1; then
                    echo 'sudo is required to install dstat for non-root user'
                    exit 1
                fi
                SUDO='sudo'
            fi

            if command -v apt-get >/dev/null 2>&1; then
                export DEBIAN_FRONTEND=noninteractive
                \$SUDO env DEBIAN_FRONTEND=noninteractive apt-get update
                \$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y dstat || \$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y pcp
            elif command -v dnf >/dev/null 2>&1; then
                \$SUDO dnf install -y dstat || \$SUDO dnf install -y pcp
            elif command -v yum >/dev/null 2>&1; then
                \$SUDO yum install -y dstat || \$SUDO yum install -y pcp
            else
                echo 'No supported package manager found'
                exit 1
            fi

            if command -v dstat >/dev/null 2>&1; then
                echo 'dstat installed: '\$(command -v dstat)
                dstat --version 2>/dev/null || true
                exit 0
            fi

            if command -v sar >/dev/null 2>&1; then
                echo 'dstat still missing after install; sysstat fallback present: '\$(command -v sar)
                exit 0
            fi

            echo 'dstat still missing after install and no sysstat fallback found'
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
