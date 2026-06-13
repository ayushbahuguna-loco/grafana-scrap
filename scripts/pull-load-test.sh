#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=machine-passwords.sh
. "$SCRIPT_DIR/machine-passwords.sh"

GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-perf/viewer}"
MACHINE_PRESET="${MACHINE_PRESET:-test1}"
DRY_RUN="${DRY_RUN:-false}"

preset_machines() {
    case "$1" in
        middle-east|me|gcc-levant)
            printf '%s\n' 'load-test-iraq-01 load-test-bahrain-01 load-test-qatar-01 load-test-kuwait-01'
            ;;
        test1|brazil-turkey)
            printf '%s\n' 'load-test-brazil-lightnode-01 load-test-brazil-lightnode-02 load-test-brazil-lightnode-03 load-test-brazil-lightnode-04 load-test-turkey-01 load-test-turkey-02 load-test-turkey-03'
            ;;
        test2|core-p0|expanded-p0)
            printf '%s\n' 'load-test-brazil-lightnode-01 load-test-brazil-lightnode-02 load-test-brazil-lightnode-03 load-test-brazil-lightnode-04 load-test-turkey-01 load-test-turkey-02 load-test-turkey-03 load-test-linux-philippines-01 load-test-linux-philippines-02 load-test-linux-philippines-03 load-test-saudi-01 load-test-saudi-02 load-test-saudi-03 load-test-egypt-01 load-test-egypt-02'
            ;;
        *)
            return 1
            ;;
    esac
}

test_preset() {
    case "$1" in
        1|test1|brazil-turkey) printf '%s\n' 'test1' ;;
        2|test2|core-p0|expanded-p0) printf '%s\n' 'test2' ;;
        *) return 1 ;;
    esac
}

apply_machine_preset() {
    local preset="$1"
    local preset_value

    preset_value="$(preset_machines "$preset" || true)"
    if [ -z "$preset_value" ]; then
        echo "Unknown preset: $preset"
        echo "Supported presets: middle-east, test1, brazil-turkey, test2, core-p0"
        exit 1
    fi

    read -r -a MACHINES <<< "$preset_value"
}

usage() {
    cat <<'EOF'
Usage:
  ./scripts/pull-load-test.sh [flags]

Defaults:
  SSHes into the test1 Brazil+Turkey machines and runs:
    cd ~/load-test && git pull origin perf/viewer

Flags:
  --preset test1                 Preset: middle-east, test1, brazil-turkey, test2, core-p0.
  --test 1                       Alias for --preset test1.
  --test 2                       Alias for --preset test2.
  --machines "machine-a machine-b"
                                  Override machines directly.
  --remote origin                Git remote. Default: origin.
  --branch perf/viewer           Git branch. Default: perf/viewer.
  --dry-run                      Print resolved machines and exit before SSH.

Examples:
  ./scripts/pull-load-test.sh
  ./scripts/pull-load-test.sh --test 1
  ./scripts/pull-load-test.sh --test 2
  ./scripts/pull-load-test.sh --machines "load-test-brazil-lightnode-01 load-test-turkey-01"
  ./scripts/pull-load-test.sh --branch main
  GIT_REMOTE=upstream GIT_BRANCH=perf/viewer ./scripts/pull-load-test.sh
EOF
}

apply_machine_preset "$MACHINE_PRESET"
if [ -n "${MACHINES_OVERRIDE:-}" ]; then
    read -r -a MACHINES <<< "$MACHINES_OVERRIDE"
    MACHINE_PRESET="custom"
fi

while [ "$#" -gt 0 ]
do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --preset|--machine-preset)
            if [ "$#" -lt 2 ]; then
                echo "--preset requires a value"
                exit 1
            fi
            MACHINE_PRESET="$2"
            apply_machine_preset "$MACHINE_PRESET"
            shift 2
            continue
            ;;
        --preset=*|--machine-preset=*)
            MACHINE_PRESET="${1#*=}"
            apply_machine_preset "$MACHINE_PRESET"
            ;;
        --test)
            if [ "$#" -lt 2 ]; then
                echo "--test requires a value"
                exit 1
            fi
            MACHINE_PRESET="$(test_preset "$2" || true)"
            if [ -z "$MACHINE_PRESET" ]; then
                echo "Unknown test: $2"
                echo "Supported tests: 1, 2"
                exit 1
            fi
            apply_machine_preset "$MACHINE_PRESET"
            shift 2
            continue
            ;;
        --test=*)
            MACHINE_PRESET="$(test_preset "${1#*=}" || true)"
            if [ -z "$MACHINE_PRESET" ]; then
                echo "Unknown test: ${1#*=}"
                echo "Supported tests: 1, 2"
                exit 1
            fi
            apply_machine_preset "$MACHINE_PRESET"
            ;;
        --machines)
            if [ "$#" -lt 2 ]; then
                echo "--machines requires a quoted, space-separated value"
                exit 1
            fi
            read -r -a MACHINES <<< "$2"
            MACHINE_PRESET="custom"
            shift 2
            continue
            ;;
        --machines=*)
            read -r -a MACHINES <<< "${1#*=}"
            MACHINE_PRESET="custom"
            ;;
        --remote)
            if [ "$#" -lt 2 ]; then
                echo "--remote requires a value"
                exit 1
            fi
            GIT_REMOTE="$2"
            shift 2
            continue
            ;;
        --remote=*)
            GIT_REMOTE="${1#*=}"
            ;;
        --branch)
            if [ "$#" -lt 2 ]; then
                echo "--branch requires a value"
                exit 1
            fi
            GIT_BRANCH="$2"
            shift 2
            continue
            ;;
        --branch=*)
            GIT_BRANCH="${1#*=}"
            ;;
        --dry-run)
            DRY_RUN="true"
            ;;
        *)
            echo "Unknown flag: $1"
            usage
            exit 1
            ;;
    esac

    shift
done

echo "MachinePreset=$MACHINE_PRESET"
echo "Machines=${MACHINES[*]}"
echo "GitRemote=$GIT_REMOTE"
echo "GitBranch=$GIT_BRANCH"

if [ "$DRY_RUN" = "true" ]; then
    echo "Dry run enabled: no SSH commands will run"
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
