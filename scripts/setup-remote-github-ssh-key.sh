#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=machine-passwords.sh
. "$SCRIPT_DIR/machine-passwords.sh"

DEFAULT_MACHINES=(
    load-test-egypt-01
    load-test-egypt-02
    load-test-egypt-03
    load-test-saudi-01
    load-test-saudi-02
    load-test-saudi-03
)

usage() {
    cat <<'EOF'
Usage:
  scripts/setup-remote-github-ssh-key.sh [machine ...]

Generates ~/.ssh/id_ed25519 on each remote machine when missing, adds GitHub
to known_hosts, and prints the public key to add in GitHub.

Defaults:
  load-test-egypt-01 load-test-egypt-02 load-test-egypt-03
  load-test-saudi-01 load-test-saudi-02 load-test-saudi-03

Examples:
  scripts/setup-remote-github-ssh-key.sh
  scripts/setup-remote-github-ssh-key.sh load-test-egypt-01
  MACHINES_OVERRIDE="load-test-egypt-01 load-test-egypt-02 load-test-egypt-03" scripts/setup-remote-github-ssh-key.sh
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$#" -gt 0 ]; then
    MACHINES=("$@")
elif [ -n "${MACHINES_OVERRIDE:-}" ]; then
    read -r -a MACHINES <<< "$MACHINES_OVERRIDE"
else
    MACHINES=("${DEFAULT_MACHINES[@]}")
fi

if ! require_machine_ssh_tools "${MACHINES[@]}"; then
    exit 1
fi

status=0

for machine in "${MACHINES[@]}"; do
    host="$(machine_host "$machine" || true)"
    user="$(machine_user "$machine")"

    echo ""
    echo "===================================="
    echo "Machine: $machine ($user@$host)"
    echo "===================================="

    if [ -z "$host" ]; then
        echo "Unknown machine"
        status=1
        continue
    fi

    public_key="$(
        machine_ssh "$machine" 'bash -s' <<'REMOTE'
set -euo pipefail

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "sudo is required to install ssh/git tools for non-root user" >&2
        exit 1
    fi
    SUDO="sudo"
fi

install_ssh_tools() {
    if command -v apt-get >/dev/null 2>&1; then
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-client git >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y openssh-clients git >/dev/null
    elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y openssh-clients git >/dev/null
    else
        echo "No supported package manager found" >&2
        exit 1
    fi
}

if ! command -v ssh-keygen >/dev/null 2>&1 || ! command -v ssh-keyscan >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    install_ssh_tools
fi

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
    ssh-keygen -t ed25519 -N "" -C "$(hostname)-github" -f "$HOME/.ssh/id_ed25519" >/dev/null
fi

known_hosts="$HOME/.ssh/known_hosts"
tmp_known_hosts="$HOME/.ssh/known_hosts.github.tmp"
touch "$known_hosts"
chmod 600 "$known_hosts"

if ssh-keyscan github.com > "$tmp_known_hosts" 2>/dev/null && [ -s "$tmp_known_hosts" ]; then
    sort -u "$known_hosts" "$tmp_known_hosts" > "$tmp_known_hosts.merged"
    mv "$tmp_known_hosts.merged" "$known_hosts"
fi
rm -f "$tmp_known_hosts" "$tmp_known_hosts.merged"

cat "$HOME/.ssh/id_ed25519.pub"
REMOTE
    )"

    if [ "$?" -eq 0 ] && [ -n "$public_key" ]; then
        echo "Add this public key in GitHub:"
        echo "$public_key"
    else
        echo "Failed to prepare GitHub SSH key"
        status=1
    fi
done

exit "$status"
