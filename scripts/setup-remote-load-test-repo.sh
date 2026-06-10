#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=machine-passwords.sh
. "$SCRIPT_DIR/machine-passwords.sh"

REPO_URL="${REPO_URL:-git@github.com:getloconow/load-test.git}"
GIT_BRANCH="${GIT_BRANCH:-perf/viewer}"

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
  scripts/setup-remote-load-test-repo.sh [machine ...]

Clones git@github.com:getloconow/load-test.git into ~/load-test when missing,
then fetches origin and checks out perf/viewer.

Run scripts/setup-remote-github-ssh-key.sh first and add the printed public key
to GitHub before running this script.

Environment:
  REPO_URL      Default: git@github.com:getloconow/load-test.git
  GIT_BRANCH   Default: perf/viewer

Examples:
  scripts/setup-remote-load-test-repo.sh
  scripts/setup-remote-load-test-repo.sh load-test-egypt-01
  MACHINES_OVERRIDE="load-test-egypt-01 load-test-egypt-02 load-test-egypt-03" scripts/setup-remote-load-test-repo.sh
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
    echo "Repo: $REPO_URL"
    echo "Branch: $GIT_BRANCH"
    echo "===================================="

    if [ -z "$host" ]; then
        echo "Unknown machine"
        status=1
        continue
    fi

    if machine_ssh "$machine" 'bash -s' "$REPO_URL" "$GIT_BRANCH" <<'REMOTE'
set -euo pipefail

REPO_URL="$1"
GIT_BRANCH="$2"
PROJECT_DIR="$HOME/load-test"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "sudo is required to install git for non-root user" >&2
        exit 1
    fi
    SUDO="sudo"
fi

install_git() {
    if command -v apt-get >/dev/null 2>&1; then
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y git openssh-client >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y git openssh-clients >/dev/null
    elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y git openssh-clients >/dev/null
    else
        echo "No supported package manager found" >&2
        exit 1
    fi
}

if ! command -v git >/dev/null 2>&1; then
    install_git
fi

if [ -e "$PROJECT_DIR" ] && [ ! -d "$PROJECT_DIR/.git" ]; then
    backup_dir="$PROJECT_DIR.backup.$(date +%Y%m%d_%H%M%S)"
    mv "$PROJECT_DIR" "$backup_dir"
    echo "Moved non-git $PROJECT_DIR to $backup_dir"
fi

if [ ! -d "$PROJECT_DIR/.git" ]; then
    git clone "$REPO_URL" "$PROJECT_DIR"
fi

cd "$PROJECT_DIR"
git remote set-url origin "$REPO_URL"
git fetch origin

if git show-ref --verify --quiet "refs/heads/$GIT_BRANCH"; then
    git checkout "$GIT_BRANCH"
else
    git checkout -b "$GIT_BRANCH" "origin/$GIT_BRANCH"
fi

git pull --ff-only origin "$GIT_BRANCH"
git status --short --branch
REMOTE
    then
        echo "[$machine] repo ready"
    else
        echo "[$machine] repo setup failed"
        status=1
    fi
done

exit "$status"
