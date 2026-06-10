#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=machine-passwords.sh
. "$SCRIPT_DIR/machine-passwords.sh"

GO_VERSION="${GO_VERSION:-1.22.5}"
RUN_GO_BUILD="${RUN_GO_BUILD:-true}"

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
  scripts/setup-remote-go-1.22.5.sh [machine ...]

Installs Go 1.22.5 under /usr/local/go on each remote machine, replacing any
existing /usr/local/go installation. If ~/load-test exists, it also runs
go mod download and go build .

Environment:
  GO_VERSION    Default: 1.22.5
  RUN_GO_BUILD  Default: true

Examples:
  scripts/setup-remote-go-1.22.5.sh
  scripts/setup-remote-go-1.22.5.sh load-test-egypt-01
  RUN_GO_BUILD=false scripts/setup-remote-go-1.22.5.sh philippines-01
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
    echo "GoVersion: $GO_VERSION"
    echo "RunGoBuild: $RUN_GO_BUILD"
    echo "===================================="

    if [ -z "$host" ]; then
        echo "Unknown machine"
        status=1
        continue
    fi

    if machine_ssh "$machine" 'bash -s' "$GO_VERSION" "$RUN_GO_BUILD" <<'REMOTE'
set -euo pipefail

GO_VERSION="$1"
RUN_GO_BUILD="$2"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "sudo is required to install Go for non-root user" >&2
        exit 1
    fi
    SUDO="sudo"
fi

install_packages() {
    if command -v apt-get >/dev/null 2>&1; then
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar gzip ca-certificates >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y curl tar gzip ca-certificates >/dev/null
    elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y curl tar gzip ca-certificates >/dev/null
    else
        echo "No supported package manager found" >&2
        exit 1
    fi
}

if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
    install_packages
fi

case "$(uname -m)" in
    x86_64|amd64) GO_ARCH="amd64" ;;
    aarch64|arm64) GO_ARCH="arm64" ;;
    *)
        echo "Unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

archive="$tmp_dir/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
url="https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"

curl -fsSL "$url" -o "$archive"

$SUDO rm -rf /usr/local/go
$SUDO tar -C /usr/local -xzf "$archive"
printf '%s\n' 'export PATH=/usr/local/go/bin:$PATH' | $SUDO tee /etc/profile.d/go.sh >/dev/null

export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
go version

if [ "$RUN_GO_BUILD" = "true" ] && [ -d "$HOME/load-test" ]; then
    cd "$HOME/load-test"
    go mod download
    go build .
fi
REMOTE
    then
        echo "[$machine] Go setup ready"
    else
        echo "[$machine] Go setup failed"
        status=1
    fi
done

exit "$status"
