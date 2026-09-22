#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_MACHINES=(
    load-test-vietnam-01
    load-test-vietnam-02
    load-test-turkey-01
    load-test-turkey-02
)

usage() {
    cat <<'EOF'
Usage:
  scripts/setup-new-load-test-machines.sh ACTION [machine ...]

Actions:
  prepare  Create/preserve the remote GitHub SSH key and install Go 1.22.5.
  keys     Create/preserve the remote GitHub SSH key and print its public key.
  go       Install Go 1.22.5 and build ~/load-test when it already exists.
  repo     Clone/update perf/viewer, then download modules and build it.
  verify   Check SSH, Go, and the ~/load-test checkout without changing them.

When no machines are supplied, all four September machines are selected:
  load-test-vietnam-01 load-test-vietnam-02
  load-test-turkey-01 load-test-turkey-02

Recommended sequence:
  scripts/setup-new-load-test-machines.sh prepare
  # Add each printed public key as a read-only deploy key on getloconow/load-test.
  scripts/setup-new-load-test-machines.sh repo
  scripts/setup-new-load-test-machines.sh verify

Examples:
  scripts/setup-new-load-test-machines.sh prepare load-test-vietnam-01 load-test-vietnam-02
  scripts/setup-new-load-test-machines.sh repo load-test-turkey-01
EOF
}

if [ "$#" -eq 0 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

ACTION="$1"
shift

if [ "$#" -gt 0 ]; then
    MACHINES=("$@")
else
    MACHINES=("${DEFAULT_MACHINES[@]}")
fi

case "$ACTION" in
    prepare)
        "$SCRIPT_DIR/setup-remote-github-ssh-key.sh" "${MACHINES[@]}"
        "$SCRIPT_DIR/setup-remote-go-1.22.5.sh" "${MACHINES[@]}"
        ;;
    keys)
        "$SCRIPT_DIR/setup-remote-github-ssh-key.sh" "${MACHINES[@]}"
        ;;
    go)
        "$SCRIPT_DIR/setup-remote-go-1.22.5.sh" "${MACHINES[@]}"
        ;;
    repo)
        "$SCRIPT_DIR/setup-remote-load-test-repo.sh" "${MACHINES[@]}"
        "$SCRIPT_DIR/setup-remote-go-1.22.5.sh" "${MACHINES[@]}"
        ;;
    verify)
        # shellcheck source=machine-passwords.sh
        . "$SCRIPT_DIR/machine-passwords.sh"
        require_machine_ssh_tools "${MACHINES[@]}"
        status=0
        for machine in "${MACHINES[@]}"; do
            echo ""
            echo "===================================="
            echo "Machine: $machine ($(machine_user "$machine")@$(machine_host "$machine" || true))"
            echo "===================================="
            if machine_ssh "$machine" 'bash -s' <<'REMOTE'
set -euo pipefail
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
printf 'Hostname: '
hostname
printf 'Go: '
go version
if [ ! -d "$HOME/load-test/.git" ]; then
    echo "Repository: missing ($HOME/load-test)"
    exit 1
fi
cd "$HOME/load-test"
printf 'Repository: '
git remote get-url origin
printf 'Branch: '
git branch --show-current
printf 'Commit: '
git rev-parse --short HEAD
git status --short --branch
REMOTE
            then
                echo "[$machine] verification passed"
            else
                echo "[$machine] verification failed"
                status=1
            fi
        done
        exit "$status"
        ;;
    *)
        echo "Unknown action: $ACTION"
        usage
        exit 1
        ;;
esac
