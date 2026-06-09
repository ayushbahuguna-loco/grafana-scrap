#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=machine-passwords.sh
. "$SCRIPT_DIR/machine-passwords.sh"

RUN_ID=""
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-60}"
REMOTE_DIR="${REMOTE_DIR:-/root/load-test}"
FORCE_COPY="false"
GENERATE_REPORT="true"
MACHINES_ARG="${MACHINES_OVERRIDE:-}"
FLOWS_ARG="${FLOWS_OVERRIDE:-}"

DEFAULT_MACHINES=(
  brazil-01
  brazil-02
  brazil-03
  brazil-04
)

DEFAULT_FLOWS=(
  auth_pre_soak
  auth_burst
  auth_soak
  feed_pre_soak
  feed_burst
  feed_soak
  stream_pre_soak
  stream_burst
  stream_soak
  chat_pre_soak
  chat_burst
  chat_soak
  quest_rewards_pre_soak
  quest_rewards_burst
  quest_rewards_soak
)

usage() {
    cat <<'EOF'
Usage:
  scripts/sync-load-test-run-files.sh RUN_ID [options]

Syncs load-test log and summary files from remote load-generator machines.
By default it checks all 4 Brazil machines and all expected API coverage flows.

Behavior:
  - Verifies login to each machine first.
  - Skips copy when the local file already exists.
  - Checks whether the remote file exists before SCP.
  - Prints REMOTE MISSING when a file was not created on the remote machine.
  - Continues checking remaining files even when one file is missing or fails.
  - Regenerates the CSV report from currently available local files by default.

Options:
  --timeout SECONDS       SSH/SCP connect timeout. Default: 60
  --machines "LIST"      Space-separated machine list.
                          Default: brazil-01 brazil-02 brazil-03 brazil-04
  --flows "LIST"         Space-separated flow list.
  --remote-dir PATH      Remote load-test directory. Default: /root/load-test
  --force                Copy even if the local file already exists.
  --no-report            Do not regenerate summary CSV files after sync.
  -h, --help             Show this help.

Examples:
  scripts/sync-load-test-run-files.sh api_coverage_v1_no_k8s_20260609_191002

  scripts/sync-load-test-run-files.sh api_coverage_v1_no_k8s_20260609_191002 \
    --machines "brazil-01 brazil-02" \
    --flows "stream_pre_soak chat_pre_soak"

Environment overrides:
  MACHINES_OVERRIDE="brazil-01 brazil-02" scripts/sync-load-test-run-files.sh RUN_ID
  FLOWS_OVERRIDE="auth_soak feed_soak" scripts/sync-load-test-run-files.sh RUN_ID
  SSH_CONNECT_TIMEOUT=90 scripts/sync-load-test-run-files.sh RUN_ID
EOF
}

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

require_local_tools() {
    local tool

    for tool in sshpass ssh scp; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "Missing required local command: $tool"
            exit 1
        fi
    done
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --timeout)
                if [ "$#" -lt 2 ]; then
                    echo "--timeout requires a value"
                    exit 1
                fi
                SSH_CONNECT_TIMEOUT="$2"
                shift 2
                ;;
            --machines)
                if [ "$#" -lt 2 ]; then
                    echo "--machines requires a value"
                    exit 1
                fi
                MACHINES_ARG="$2"
                shift 2
                ;;
            --flows)
                if [ "$#" -lt 2 ]; then
                    echo "--flows requires a value"
                    exit 1
                fi
                FLOWS_ARG="$2"
                shift 2
                ;;
            --remote-dir)
                if [ "$#" -lt 2 ]; then
                    echo "--remote-dir requires a value"
                    exit 1
                fi
                REMOTE_DIR="$2"
                shift 2
                ;;
            --force)
                FORCE_COPY="true"
                shift
                ;;
            --no-report)
                GENERATE_REPORT="false"
                shift
                ;;
            -*)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                if [ -n "$RUN_ID" ]; then
                    echo "Unexpected extra argument: $1"
                    usage
                    exit 1
                fi
                RUN_ID="$1"
                shift
                ;;
        esac
    done

    if [ -z "$RUN_ID" ]; then
        echo "RUN_ID is required"
        usage
        exit 1
    fi

    if ! [[ "$SSH_CONNECT_TIMEOUT" =~ ^[0-9]+$ ]]; then
        echo "--timeout must be a positive integer"
        exit 1
    fi
}

build_lists() {
    if [ -n "$MACHINES_ARG" ]; then
        read -r -a MACHINES <<< "$MACHINES_ARG"
    else
        MACHINES=("${DEFAULT_MACHINES[@]}")
    fi

    if [ -n "$FLOWS_ARG" ]; then
        read -r -a FLOWS <<< "$FLOWS_ARG"
    else
        FLOWS=("${DEFAULT_FLOWS[@]}")
    fi

    if [ "${#MACHINES[@]}" -eq 0 ]; then
        echo "Machine list is empty"
        exit 1
    fi

    if [ "${#FLOWS[@]}" -eq 0 ]; then
        echo "Flow list is empty"
        exit 1
    fi
}

ssh_machine() {
    local password="$1"
    local host="$2"
    local command="$3"

    sshpass -p "$password" \
        ssh -n \
        -o StrictHostKeyChecking=no \
        -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT" \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts=1 \
        "root@$host" \
        "$command"
}

remote_file_info() {
    local password="$1"
    local host="$2"
    local remote_file="$3"
    local remote_quoted

    remote_quoted="$(printf '%q' "$remote_file")"
    ssh_machine "$password" "$host" "test -f $remote_quoted && ls -lh $remote_quoted"
}

scp_from_machine() {
    local password="$1"
    local host="$2"
    local remote_file="$3"
    local local_dir="$4"

    sshpass -p "$password" \
        scp \
        -o StrictHostKeyChecking=no \
        -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT" \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts=1 \
        "root@$host:$remote_file" \
        "$local_dir/" </dev/null
}

checked_count=0
skip_count=0
copy_count=0
remote_missing_count=0
remote_check_failed_count=0
copy_failed_count=0
login_failed_count=0

sync_one_file() {
    local machine="$1"
    local password="$2"
    local host="$3"
    local file="$4"
    local local_dir="$REPO_ROOT/results/$RUN_ID/$machine"
    local local_file="$local_dir/$file"
    local remote_file="$REMOTE_DIR/$file"
    local info
    local status

    checked_count=$((checked_count + 1))
    mkdir -p "$local_dir"

    if [ -f "$local_file" ] && [ "$FORCE_COPY" != "true" ]; then
        echo "SKIP local exists: results/$RUN_ID/$machine/$file"
        skip_count=$((skip_count + 1))
        return 0
    fi

    echo "CHECK remote: $machine:$remote_file"
    info="$(remote_file_info "$password" "$host" "$remote_file" 2>&1)"
    status=$?

    if [ "$status" -ne 0 ]; then
        if [ "$status" -eq 1 ]; then
            echo "REMOTE MISSING: $machine:$remote_file"
            remote_missing_count=$((remote_missing_count + 1))
        else
            echo "REMOTE CHECK FAILED: $machine:$remote_file"
            echo "$info"
            remote_check_failed_count=$((remote_check_failed_count + 1))
        fi
        return 0
    fi

    echo "REMOTE OK: $info"
    if [ -f "$local_file" ] && [ "$FORCE_COPY" = "true" ]; then
        echo "FORCE copy over local file: results/$RUN_ID/$machine/$file"
    fi

    if scp_from_machine "$password" "$host" "$remote_file" "$local_dir"; then
        echo "COPY OK: results/$RUN_ID/$machine/$file"
        copy_count=$((copy_count + 1))
    else
        echo "COPY FAILED: $machine:$remote_file"
        copy_failed_count=$((copy_failed_count + 1))
    fi
}

sync_machine() {
    local machine="$1"
    local host
    local password
    local hostname
    local flow
    local flow_run_id

    host="$(machine_host "$machine" || true)"
    password="$(machine_password "$machine" || true)"

    echo ""
    echo "===================================="
    echo "Machine: $machine"
    echo "===================================="

    if [ -z "$host" ] || [ -z "$password" ]; then
        echo "LOGIN FAILED: $machine unknown host or missing password"
        login_failed_count=$((login_failed_count + 1))
        return 0
    fi

    echo "Checking login: $machine ($host)"
    hostname="$(ssh_machine "$password" "$host" "hostname" 2>&1)"
    if [ "$?" -ne 0 ]; then
        echo "LOGIN FAILED: $machine"
        echo "$hostname"
        login_failed_count=$((login_failed_count + 1))
        return 0
    fi
    echo "LOGIN OK: $machine hostname=$hostname"

    for flow in "${FLOWS[@]}"; do
        flow_run_id="${RUN_ID}_${machine}_${flow}"

        sync_one_file "$machine" "$password" "$host" "loadtest_${flow_run_id}.log"
        sync_one_file "$machine" "$password" "$host" "summary_${flow_run_id}.txt"
    done
}

generate_report() {
    if [ "$GENERATE_REPORT" != "true" ]; then
        echo ""
        echo "CSV report regeneration skipped by --no-report"
        return 0
    fi

    if [ ! -x "$REPO_ROOT/scripts/generate-load-test-report-csv.py" ]; then
        echo ""
        echo "CSV report generator not executable: scripts/generate-load-test-report-csv.py"
        return 1
    fi

    echo ""
    echo "===================================="
    echo "Generating CSV report"
    echo "===================================="

    if PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-/tmp/grafana-scrap-pycache}" \
        "$REPO_ROOT/scripts/generate-load-test-report-csv.py" "$REPO_ROOT/results/$RUN_ID"
    then
        echo "CSV report saved under: results/$RUN_ID/summary-csv"
        return 0
    fi

    echo "CSV report generation failed"
    return 1
}

main() {
    local machine
    local report_status=0
    local issue_count

    parse_args "$@"
    require_local_tools
    build_lists

    echo "RUN_ID=$RUN_ID"
    echo "RemoteDir=$REMOTE_DIR"
    echo "Timeout=${SSH_CONNECT_TIMEOUT}s"
    echo "Machines=${MACHINES[*]}"
    echo "Flows=${FLOWS[*]}"
    echo "ForceCopy=$FORCE_COPY"

    for machine in "${MACHINES[@]}"; do
        sync_machine "$machine"
    done

    generate_report || report_status=$?

    echo ""
    echo "===================================="
    echo "Sync summary"
    echo "===================================="
    echo "Checked files: $checked_count"
    echo "Skipped local existing: $skip_count"
    echo "Copied: $copy_count"
    echo "Remote missing: $remote_missing_count"
    echo "Remote check failed: $remote_check_failed_count"
    echo "Copy failed: $copy_failed_count"
    echo "Login failed: $login_failed_count"

    issue_count=$((remote_missing_count + remote_check_failed_count + copy_failed_count + login_failed_count + report_status))
    if [ "$issue_count" -ne 0 ]; then
        exit 1
    fi
}

main "$@"
