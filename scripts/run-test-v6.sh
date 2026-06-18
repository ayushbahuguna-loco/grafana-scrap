#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=machine-passwords.sh
. "$SCRIPT_DIR/machine-passwords.sh"

cd "$REPO_ROOT" || exit 1

# =========================
# Load Test Config
# =========================

SCRIPT_VERSION="regional_api_coverage_v6"
DEFAULT_DURATION="${DEFAULT_DURATION:-120s}"
RPS_DRAIN_TIMEOUT="${RPS_DRAIN_TIMEOUT:-60s}"
STREAM_UID="${STREAM_UID:-84e72fbf-f226-47ab-926b-55e9b2142e31}"
STREAMER_UID="${STREAMER_UID:-2L6YZ1RZU0}"

# Regional target model:
#   regional target RPS = (users_in_thousands * 1000 * API calls in flow) / duration_seconds
#   local target RPS = regional target RPS / selected machine count for that same region
#
# Region user inputs:
#   Brazil:        79.5k users  -> load-test-brazil-lightnode-01..04
#   Turkey:        55k users    -> load-test-turkey-01..03
#   Philippines:   18k users    -> load-test-linux-philippines-01..03
#   Saudi:         22.5k users  -> saudi-01..03 / load-test-saudi-01..03
#   Egypt:         13.5k users  -> egypt-01..02 / load-test-egypt-01..02
#   Iraq:          7.2k users   -> load-test-iraq-01
#   Jordan:        3.6k users   -> no local machine
#   Lebanon:       2.7k users   -> no local machine
#   Qatar:         2.25k users  -> load-test-qatar-01
#   Kuwait:        3.6k users   -> load-test-kuwait-01
#   Jordan+Lebanon 6.3k users  -> load-test-bahrain-01
#
# API calls per flow:
#   41 leaderboard   = 5
#   76 auth          = 7
#   77 feed          = 6
#   78 stream        = 6
#   79 chat          = 3
#   80 quest_rewards = 2
#   82 search        = 2
#
# The Go runner splits TARGET_RPS by LOAD_GENERATORS. To avoid distributing one
# target across unrelated regions, this script passes:
#   remote TARGET_RPS = local target RPS * configured machine count
# so the runner's local post-split target remains the machine's regional share.
FLOW_NAMES=(
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
    leaderboard_pre_soak
    leaderboard_burst
    leaderboard_soak
    search_pre_soak
    search_burst
    search_soak
)

FLOW_IDS=(
    76
    76
    76
    77
    77
    77
    78
    78
    78
    79
    79
    79
    80
    80
    80
    41
    41
    41
    82
    82
    82
)

FLOW_API_COUNTS=(
  7
  7
  7
  6
  6
  6
  6
  6
  6
  3
  3
  3
  2
  2
  2
  5
  5
  5
  2
  2
  2
)

# 0 lets the Go runner default workers to this generator's assigned local RPS.
FLOW_RPS_WORKERS=(
  0
  0
  0
  0
  0
  0
  0
  0
  0
  0
  0
  0
  0
  0
  0
  0
  0
  0
  0
  0
  0
)

# Duration for each flow, aligned by index with FLOW_NAMES/FLOW_IDS.
FLOW_DURATIONS=(
  180s
  60s
  600s
  180s
  60s
  600s
  180s
  60s
  600s
  180s
  60s
  600s
  180s
  60s
  600s
  180s
  60s
  600s
  180s
  60s
  600s
)

COLLECT_INSTANCE_METRICS="${COLLECT_INSTANCE_METRICS:-true}"
COLLECT_K8S_METRICS="${COLLECT_K8S_METRICS:-false}"
GENERATE_CSV_REPORT="${GENERATE_CSV_REPORT:-true}"
DRY_RUN="${DRY_RUN:-false}"
SSH_RETRY_ATTEMPTS="${SSH_RETRY_ATTEMPTS:-3}"
SSH_RETRY_DELAY_SECONDS="${SSH_RETRY_DELAY_SECONDS:-5}"
DURATION_OVERRIDE=""
MACHINE_PRESET="${MACHINE_PRESET:-middle-east}"
START_FLOW_NAME="${START_FLOW_NAME:-}"
START_FLOW_INDEX=0
INSTANCE_METRICS_MACHINES_OVERRIDE="${INSTANCE_METRICS_MACHINES_OVERRIDE:-}"
CUSTOM_FLOW_NAME="${CUSTOM_FLOW_NAME:-}"
CUSTOM_FLOW_ID="${CUSTOM_FLOW_ID:-}"
CUSTOM_FLOW_API_COUNT="${CUSTOM_FLOW_API_COUNT:-}"
CUSTOM_FLOW_DURATION="${CUSTOM_FLOW_DURATION:-}"
CUSTOM_FLOW_RPS_WORKERS="${CUSTOM_FLOW_RPS_WORKERS:-0}"
MACHINES=()

usage() {
    cat <<'EOF'
Usage:
  ./scripts/run-test-v6.sh [flags]

Metric flags:
  --with-dstat, --dstat          Start/stop/collect dstat instance metrics. Default.
  --no-dstat                     Skip dstat install/check and instance metrics.
  --dstat-machines "LIST"        Collect dstat only from this machine subset.
                                  Load still runs on the full --test/--machines list.
  --with-k8s, --k8s              Start/stop/collect Kubernetes cluster metrics.
  --no-k8s                       Skip Kubernetes cluster metrics. Default.
  --all-metrics                  Enable both dstat and Kubernetes metrics.
  --no-metrics                   Disable both dstat and Kubernetes metrics.
  --with-csv, --csv              Generate summary CSV. Default.
  --no-csv                       Skip summary CSV generation.
  --dry-run                      Print resolved config and exit before SSH.

Run flags:
  --duration 120s                Override all per-flow durations and recalculate regional RPS.
  --run-id api_coverage_manual   Override RUN_ID.
  --start-flow stream_pre_soak    Resume from this flow name and skip earlier flows.
  --flow-id 81                   Run only this single flow ID instead of the default flow list.
  --api-count 4                  API calls in --flow-id. Required with --flow-id.
  --flow-name custom_flow_81      Optional name for --flow-id. Default: flow_<id>.
  --flow-duration 180s            Optional duration for --flow-id. Default: --duration or DEFAULT_DURATION.
  --preset middle-east           Use a saved machine set. Default: middle-east.
                                  Presets: middle-east, test1, brazil-turkey, test2, core-p0.
  --test 1                       Alias for --preset test1 (Brazil + Turkey).
  --test 2                       Alias for --preset test2 (Brazil + Turkey + Philippines + Saudi + Egypt).
  --machines "load-test-brazil-lightnode-01 load-test-turkey-01"
                                  Override machines directly. RPS is calculated from each machine's region.

Environment overrides still work:
  MACHINE_PRESET=test2 DEFAULT_DURATION=60s COLLECT_K8S_METRICS=true ./scripts/run-test-v6.sh
  SSH_RETRY_ATTEMPTS=3 SSH_RETRY_DELAY_SECONDS=5 ./scripts/run-test-v6.sh --test 2

Examples:
  ./scripts/run-test-v6.sh --no-k8s
  ./scripts/run-test-v6.sh --no-k8s --test 1
  ./scripts/run-test-v6.sh --no-k8s --test 2
  ./scripts/run-test-v6.sh --no-k8s --no-dstat --test 2 --flow-id 81 --api-count 4 --flow-duration 180s
  ./scripts/run-test-v6.sh --no-k8s --dry-run
  ./scripts/run-test-v6.sh --no-k8s --test 2 --dstat-machines "load-test-brazil-lightnode-01 load-test-turkey-01"
  ./scripts/run-test-v6.sh --no-k8s --no-dstat --test 1 --run-id regional_api_coverage_v6_20260612_163047 --start-flow stream_pre_soak
  ./scripts/run-test-v6.sh --no-k8s --duration 30s --no-dstat --no-csv
EOF
}

parse_bool() {
    case "$1" in
        true|TRUE|yes|YES|1|on|ON) printf '%s\n' 'true' ;;
        false|FALSE|no|NO|0|off|OFF) printf '%s\n' 'false' ;;
        *) return 1 ;;
    esac
}

set_bool_from_value() {
    var_name="$1"
    raw_value="$2"
    option_name="$3"

    parsed_value="$(parse_bool "$raw_value" || true)"
    if [ -z "$parsed_value" ]; then
        echo "Invalid boolean for $option_name: $raw_value"
        echo "Use true/false, yes/no, on/off, or 1/0."
        exit 1
    fi

    printf -v "$var_name" '%s' "$parsed_value"
}

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

machine_region_key() {
    case "$1" in
        brazil-01|brazil-02|brazil-03|brazil-04|load-test-brazil-lightnode-01|load-test-brazil-lightnode-02|load-test-brazil-lightnode-03|load-test-brazil-lightnode-04) printf '%s\n' 'brazil' ;;
        turkey-01|turkey-02|turkey-03|load-test-turkey-01|load-test-turkey-02|load-test-turkey-03) printf '%s\n' 'turkey' ;;
        philippines-01|philippines-02|philippines-03|load-test-linux-philippines-01|load-test-linux-philippines-02|load-test-linux-philippines-03) printf '%s\n' 'philippines' ;;
        saudi-01|saudi-02|saudi-03|load-test-saudi-01|load-test-saudi-02|load-test-saudi-03) printf '%s\n' 'saudi' ;;
        egypt-01|egypt-02|egypt-03|load-test-egypt-01|load-test-egypt-02|load-test-egypt-03) printf '%s\n' 'egypt' ;;
        iraq-01|load-test-iraq-01) printf '%s\n' 'iraq' ;;
        bahrain-01|load-test-bahrain-01) printf '%s\n' 'jordan_lebanon' ;;
        qatar-01|load-test-qatar-01) printf '%s\n' 'qatar' ;;
        kuwait-01|load-test-kuwait-01) printf '%s\n' 'kuwait' ;;
        *) return 1 ;;
    esac
}

region_label() {
    case "$1" in
        brazil) printf '%s\n' 'Brazil' ;;
        turkey) printf '%s\n' 'Turkey' ;;
        philippines) printf '%s\n' 'Philippines' ;;
        saudi) printf '%s\n' 'Saudi' ;;
        egypt) printf '%s\n' 'Egypt' ;;
        iraq) printf '%s\n' 'Iraq' ;;
        jordan_lebanon) printf '%s\n' 'Jordan+Lebanon via Bahrain' ;;
        qatar) printf '%s\n' 'Qatar' ;;
        kuwait) printf '%s\n' 'Kuwait' ;;
        *) return 1 ;;
    esac
}

region_users_k() {
    case "$1" in
        brazil) printf '%s\n' '79.5' ;;
        turkey) printf '%s\n' '55' ;;
        philippines) printf '%s\n' '18' ;;
        saudi) printf '%s\n' '22.5' ;;
        egypt) printf '%s\n' '13.5' ;;
        iraq) printf '%s\n' '7.2' ;;
        jordan_lebanon) printf '%s\n' '6.3' ;;
        qatar) printf '%s\n' '2.25' ;;
        kuwait) printf '%s\n' '3.6' ;;
        *) return 1 ;;
    esac
}

machine_region_label() {
    local region_key

    region_key="$(machine_region_key "$1")" || return 1
    region_label "$region_key"
}

machine_users_k() {
    local region_key

    region_key="$(machine_region_key "$1")" || return 1
    region_users_k "$region_key"
}

selected_region_machine_count() {
    local machine="$1"
    local target_region_key
    local selected_machine
    local selected_region_key
    local count=0

    target_region_key="$(machine_region_key "$machine")" || return 1

    for selected_machine in "${MACHINES[@]}"
    do
        selected_region_key="$(machine_region_key "$selected_machine" || true)"
        if [ "$selected_region_key" = "$target_region_key" ]; then
            count=$((count + 1))
        fi
    done

    if [ "$count" -le 0 ]; then
        return 1
    fi

    printf '%s\n' "$count"
}

duration_seconds() {
    local raw_duration="$1"
    local duration_value
    local duration_unit

    if [[ ! "$raw_duration" =~ ^([0-9]+)([smh]?)$ ]]; then
        return 1
    fi

    duration_value="${BASH_REMATCH[1]}"
    duration_unit="${BASH_REMATCH[2]}"

    case "$duration_unit" in
        s|'') printf '%s\n' "$duration_value" ;;
        m) printf '%s\n' "$((duration_value * 60))" ;;
        h) printf '%s\n' "$((duration_value * 3600))" ;;
        *) return 1 ;;
    esac
}

flow_index_for_name() {
    local requested="$1"
    local flow_index

    for flow_index in "${!FLOW_NAMES[@]}"
    do
        if [ "${FLOW_NAMES[$flow_index]}" = "$requested" ]; then
            printf '%s\n' "$flow_index"
            return 0
        fi
    done

    return 1
}

local_target_rps() {
    local machine="$1"
    local flow_index="$2"
    local duration="$3"
    local users_k
    local api_count
    local seconds
    local region_machine_count

    users_k="$(machine_users_k "$machine")" || return 1
    api_count="${FLOW_API_COUNTS[$flow_index]}"
    seconds="$(duration_seconds "$duration")" || return 1
    region_machine_count="$(selected_region_machine_count "$machine")" || return 1

    if [ "$seconds" -le 0 ]; then
        return 1
    fi

    awk \
        -v users_k="$users_k" \
        -v api_count="$api_count" \
        -v seconds="$seconds" \
        -v region_machine_count="$region_machine_count" \
        'BEGIN { printf "%d\n", ((users_k * 1000 * api_count / seconds / region_machine_count) + 0.5) }'
}

regional_target_rps() {
    local machine="$1"
    local flow_index="$2"
    local duration="$3"
    local users_k
    local api_count
    local seconds

    users_k="$(machine_users_k "$machine")" || return 1
    api_count="${FLOW_API_COUNTS[$flow_index]}"
    seconds="$(duration_seconds "$duration")" || return 1

    if [ "$seconds" -le 0 ]; then
        return 1
    fi

    awk \
        -v users_k="$users_k" \
        -v api_count="$api_count" \
        -v seconds="$seconds" \
        'BEGIN { printf "%d\n", ((users_k * 1000 * api_count / seconds) + 0.5) }'
}

flow_duration_for_index() {
    if [ -n "$DURATION_OVERRIDE" ]; then
        printf '%s\n' "$DURATION_OVERRIDE"
    else
        printf '%s\n' "${FLOW_DURATIONS[$1]}"
    fi
}

local_target_triplet() {
    local machine="$1"
    local start_index="$2"
    local pre
    local burst
    local soak

    pre="$(local_target_rps "$machine" "$start_index" "$(flow_duration_for_index "$start_index")")" || return 1
    burst="$(local_target_rps "$machine" "$((start_index + 1))" "$(flow_duration_for_index "$((start_index + 1))")")" || return 1
    soak="$(local_target_rps "$machine" "$((start_index + 2))" "$(flow_duration_for_index "$((start_index + 2))")")" || return 1

    printf '%s/%s/%s\n' "$pre" "$burst" "$soak"
}

regional_target_triplet() {
    local machine="$1"
    local start_index="$2"
    local pre
    local burst
    local soak

    pre="$(regional_target_rps "$machine" "$start_index" "$(flow_duration_for_index "$start_index")")" || return 1
    burst="$(regional_target_rps "$machine" "$((start_index + 1))" "$(flow_duration_for_index "$((start_index + 1))")")" || return 1
    soak="$(regional_target_rps "$machine" "$((start_index + 2))" "$(flow_duration_for_index "$((start_index + 2))")")" || return 1

    printf '%s/%s/%s\n' "$pre" "$burst" "$soak"
}

print_regional_target_plan() {
    local machine
    local region_label
    local users_k
    local region_machine_count
    local flow_index
    local flow_name

    if [ "${#FLOW_IDS[@]}" -ne 21 ]; then
        echo "Selected flow target RPS:"
        for machine in "${MACHINES[@]}"
        do
            region_label="$(machine_region_label "$machine" || true)"
            users_k="$(machine_users_k "$machine" || true)"
            region_machine_count="$(selected_region_machine_count "$machine" || true)"

            if [ -z "$region_label" ] || [ -z "$users_k" ] || [ -z "$region_machine_count" ]; then
                echo "  $machine region_target=missing"
                continue
            fi

            for flow_index in "${!FLOW_IDS[@]}"
            do
                flow_name="${FLOW_NAMES[$flow_index]}"
                echo "  $machine region=\"$region_label\" users=${users_k}k region_machines=$region_machine_count flow=$flow_name flow_id=${FLOW_IDS[$flow_index]} api_count=${FLOW_API_COUNTS[$flow_index]} regional=$(regional_target_rps "$machine" "$flow_index" "$(flow_duration_for_index "$flow_index")") local=$(local_target_rps "$machine" "$flow_index" "$(flow_duration_for_index "$flow_index")") duration=$(flow_duration_for_index "$flow_index")"
            done
        done
        echo "Remote TARGET_RPS is local target RPS multiplied by LoadGenerators=$LOAD_GENERATORS so the Go runner split preserves these machine-local targets."
        return 0
    fi

    echo "Regional total target RPS (pre/burst/soak):"
    for machine in "${MACHINES[@]}"
    do
        region_label="$(machine_region_label "$machine" || true)"
        users_k="$(machine_users_k "$machine" || true)"
        region_machine_count="$(selected_region_machine_count "$machine" || true)"

        if [ -z "$region_label" ] || [ -z "$users_k" ] || [ -z "$region_machine_count" ]; then
            echo "  $machine region_target=missing"
            continue
        fi

        echo "  $machine region=\"$region_label\" users=${users_k}k region_machines=$region_machine_count auth=$(regional_target_triplet "$machine" 0) feed=$(regional_target_triplet "$machine" 3) stream=$(regional_target_triplet "$machine" 6) chat=$(regional_target_triplet "$machine" 9) quest_rewards=$(regional_target_triplet "$machine" 12) leaderboard=$(regional_target_triplet "$machine" 15) search=$(regional_target_triplet "$machine" 18)"
    done
    echo "Machine-local target RPS after same-region split (pre/burst/soak):"
    for machine in "${MACHINES[@]}"
    do
        region_label="$(machine_region_label "$machine" || true)"
        users_k="$(machine_users_k "$machine" || true)"
        region_machine_count="$(selected_region_machine_count "$machine" || true)"

        if [ -z "$region_label" ] || [ -z "$users_k" ] || [ -z "$region_machine_count" ]; then
            echo "  $machine region_target=missing"
            continue
        fi

        echo "  $machine region=\"$region_label\" users=${users_k}k region_machines=$region_machine_count auth=$(local_target_triplet "$machine" 0) feed=$(local_target_triplet "$machine" 3) stream=$(local_target_triplet "$machine" 6) chat=$(local_target_triplet "$machine" 9) quest_rewards=$(local_target_triplet "$machine" 12) leaderboard=$(local_target_triplet "$machine" 15) search=$(local_target_triplet "$machine" 18)"
    done
    echo "Remote TARGET_RPS is local target RPS multiplied by LoadGenerators=$LOAD_GENERATORS so the Go runner split preserves these machine-local targets."
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
        --with-dstat|--dstat|--instance-metrics)
            COLLECT_INSTANCE_METRICS="true"
            ;;
        --collect-dstat|--collect-instance-metrics)
            COLLECT_INSTANCE_METRICS="true"
            ;;
        --no-dstat|--no-instance-metrics)
            COLLECT_INSTANCE_METRICS="false"
            ;;
        --no-collect-dstat|--no-collect-instance-metrics)
            COLLECT_INSTANCE_METRICS="false"
            ;;
        --dstat=*|--instance-metrics=*)
            set_bool_from_value COLLECT_INSTANCE_METRICS "${1#*=}" "$1"
            ;;
        --dstat-machines|--instance-metrics-machines)
            if [ "$#" -lt 2 ]; then
                echo "--dstat-machines requires a quoted, space-separated value"
                exit 1
            fi
            INSTANCE_METRICS_MACHINES_OVERRIDE="$2"
            shift 2
            continue
            ;;
        --dstat-machines=*|--instance-metrics-machines=*)
            INSTANCE_METRICS_MACHINES_OVERRIDE="${1#*=}"
            ;;
        --with-k8s|--k8s|--kubernetes-metrics)
            COLLECT_K8S_METRICS="true"
            ;;
        --collect-k8s|--collect-kubernetes-metrics)
            COLLECT_K8S_METRICS="true"
            ;;
        --no-k8s|--no-kubernetes-metrics)
            COLLECT_K8S_METRICS="false"
            ;;
        --no-collect-k8s|--no-collect-kubernetes-metrics)
            COLLECT_K8S_METRICS="false"
            ;;
        --k8s=*|--kubernetes-metrics=*)
            set_bool_from_value COLLECT_K8S_METRICS "${1#*=}" "$1"
            ;;
        --all-metrics)
            COLLECT_INSTANCE_METRICS="true"
            COLLECT_K8S_METRICS="true"
            ;;
        --no-metrics)
            COLLECT_INSTANCE_METRICS="false"
            COLLECT_K8S_METRICS="false"
            ;;
        --with-csv|--csv)
            GENERATE_CSV_REPORT="true"
            ;;
        --no-csv)
            GENERATE_CSV_REPORT="false"
            ;;
        --csv=*)
            set_bool_from_value GENERATE_CSV_REPORT "${1#*=}" "$1"
            ;;
        --dry-run)
            DRY_RUN="true"
            ;;
        --dry-run=*)
            set_bool_from_value DRY_RUN "${1#*=}" "$1"
            ;;
        --duration)
            if [ "$#" -lt 2 ]; then
                echo "--duration requires a value"
                exit 1
            fi
            DEFAULT_DURATION="$2"
            DURATION_OVERRIDE="$2"
            shift 2
            continue
            ;;
        --duration=*)
            DEFAULT_DURATION="${1#*=}"
            DURATION_OVERRIDE="${1#*=}"
            ;;
        --run-id)
            if [ "$#" -lt 2 ]; then
                echo "--run-id requires a value"
                exit 1
            fi
            RUN_ID="$2"
            shift 2
            continue
            ;;
        --run-id=*)
            RUN_ID="${1#*=}"
            ;;
        --start-flow|--resume-from)
            if [ "$#" -lt 2 ]; then
                echo "--start-flow requires a flow name"
                exit 1
            fi
            START_FLOW_NAME="$2"
            shift 2
            continue
            ;;
        --start-flow=*|--resume-from=*)
            START_FLOW_NAME="${1#*=}"
            ;;
        --flow-id|--custom-flow-id)
            if [ "$#" -lt 2 ]; then
                echo "--flow-id requires a value"
                exit 1
            fi
            CUSTOM_FLOW_ID="$2"
            shift 2
            continue
            ;;
        --flow-id=*|--custom-flow-id=*)
            CUSTOM_FLOW_ID="${1#*=}"
            ;;
        --api-count|--flow-api-count)
            if [ "$#" -lt 2 ]; then
                echo "--api-count requires a value"
                exit 1
            fi
            CUSTOM_FLOW_API_COUNT="$2"
            shift 2
            continue
            ;;
        --api-count=*|--flow-api-count=*)
            CUSTOM_FLOW_API_COUNT="${1#*=}"
            ;;
        --flow-name|--custom-flow-name)
            if [ "$#" -lt 2 ]; then
                echo "--flow-name requires a value"
                exit 1
            fi
            CUSTOM_FLOW_NAME="$2"
            shift 2
            continue
            ;;
        --flow-name=*|--custom-flow-name=*)
            CUSTOM_FLOW_NAME="${1#*=}"
            ;;
        --flow-duration|--custom-flow-duration)
            if [ "$#" -lt 2 ]; then
                echo "--flow-duration requires a value"
                exit 1
            fi
            CUSTOM_FLOW_DURATION="$2"
            shift 2
            continue
            ;;
        --flow-duration=*|--custom-flow-duration=*)
            CUSTOM_FLOW_DURATION="${1#*=}"
            ;;
        --flow-workers|--custom-flow-workers)
            if [ "$#" -lt 2 ]; then
                echo "--flow-workers requires a value"
                exit 1
            fi
            CUSTOM_FLOW_RPS_WORKERS="$2"
            shift 2
            continue
            ;;
        --flow-workers=*|--custom-flow-workers=*)
            CUSTOM_FLOW_RPS_WORKERS="${1#*=}"
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
        *)
            echo "Unknown flag: $1"
            usage
            exit 1
            ;;
    esac

    shift
done

set_bool_from_value COLLECT_INSTANCE_METRICS "$COLLECT_INSTANCE_METRICS" "COLLECT_INSTANCE_METRICS"
set_bool_from_value COLLECT_K8S_METRICS "$COLLECT_K8S_METRICS" "COLLECT_K8S_METRICS"
set_bool_from_value GENERATE_CSV_REPORT "$GENERATE_CSV_REPORT" "GENERATE_CSV_REPORT"
set_bool_from_value DRY_RUN "$DRY_RUN" "DRY_RUN"

if [ -n "$CUSTOM_FLOW_ID" ] || [ -n "$CUSTOM_FLOW_API_COUNT" ] || [ -n "$CUSTOM_FLOW_NAME" ] || [ -n "$CUSTOM_FLOW_DURATION" ]; then
    if [ -z "$CUSTOM_FLOW_ID" ]; then
        echo "--flow-id is required for custom single-flow mode"
        exit 1
    fi
    if [ -z "$CUSTOM_FLOW_API_COUNT" ]; then
        echo "--api-count is required with --flow-id"
        exit 1
    fi
    if ! [[ "$CUSTOM_FLOW_ID" =~ ^[0-9]+$ ]]; then
        echo "--flow-id must be a positive integer: $CUSTOM_FLOW_ID"
        exit 1
    fi
    if ! [[ "$CUSTOM_FLOW_API_COUNT" =~ ^[0-9]+$ ]] || [ "$CUSTOM_FLOW_API_COUNT" -le 0 ]; then
        echo "--api-count must be a positive integer: $CUSTOM_FLOW_API_COUNT"
        exit 1
    fi
    if ! [[ "$CUSTOM_FLOW_RPS_WORKERS" =~ ^[0-9]+$ ]]; then
        echo "--flow-workers must be zero or a positive integer: $CUSTOM_FLOW_RPS_WORKERS"
        exit 1
    fi

    CUSTOM_FLOW_NAME="${CUSTOM_FLOW_NAME:-flow_${CUSTOM_FLOW_ID}}"
    CUSTOM_FLOW_DURATION="${CUSTOM_FLOW_DURATION:-${DURATION_OVERRIDE:-$DEFAULT_DURATION}}"

    if ! duration_seconds "$CUSTOM_FLOW_DURATION" >/dev/null; then
        echo "Invalid --flow-duration: $CUSTOM_FLOW_DURATION"
        exit 1
    fi

    FLOW_NAMES=("$CUSTOM_FLOW_NAME")
    FLOW_IDS=("$CUSTOM_FLOW_ID")
    FLOW_API_COUNTS=("$CUSTOM_FLOW_API_COUNT")
    FLOW_RPS_WORKERS=("$CUSTOM_FLOW_RPS_WORKERS")
    FLOW_DURATIONS=("$CUSTOM_FLOW_DURATION")
    DURATION_OVERRIDE=""
fi

RUN_ID="${RUN_ID:-${SCRIPT_VERSION}_$(date +%Y%m%d_%H%M%S)}"
METRICS_DIR="results/$RUN_ID/instance-metrics"
K8S_METRICS_DIR="results/$RUN_ID/k8s-cluster-metrics"
REPORT_CSV_DIR="results/$RUN_ID/summary-csv"
CLEANUP_DONE=0
METRICS_ATTEMPTED=0
K8S_METRICS_ATTEMPTED=0
RUN_ARTIFACTS_ATTEMPTED=0
ARTIFACT_COLLECTION_DONE=0
ARTIFACT_FLOW_INDEXES=()

LOAD_GENERATORS="${#MACHINES[@]}"
if [ "$LOAD_GENERATORS" -eq 0 ]; then
    echo "At least one machine is required"
    exit 1
fi

if [ -n "$START_FLOW_NAME" ]; then
    START_FLOW_INDEX="$(flow_index_for_name "$START_FLOW_NAME" || true)"
    if [ -z "$START_FLOW_INDEX" ]; then
        echo "Unknown start flow: $START_FLOW_NAME"
        echo "Known flows: ${FLOW_NAMES[*]}"
        exit 1
    fi
fi

MACHINES_OVERRIDE_VALUE="${MACHINES[*]}"
INSTANCE_METRICS_MACHINES_VALUE="${INSTANCE_METRICS_MACHINES_OVERRIDE:-$MACHINES_OVERRIDE_VALUE}"

machine_ssh_retry() {
    local machine="$1"
    shift

    local attempt=1
    local status=0

    while true
    do
        machine_ssh "$machine" "$@"
        status=$?

        if [ "$status" -eq 0 ]; then
            return 0
        fi

        if [ "$status" -ne 255 ] || [ "$attempt" -ge "$SSH_RETRY_ATTEMPTS" ]; then
            return "$status"
        fi

        echo "[$machine] SSH transport failed with exit $status; retrying attempt $((attempt + 1))/$SSH_RETRY_ATTEMPTS after ${SSH_RETRY_DELAY_SECONDS}s"
        sleep "$SSH_RETRY_DELAY_SECONDS"
        attempt=$((attempt + 1))
    done
}

machine_scp_from_retry() {
    local machine="$1"
    local remote_file="$2"
    local local_target="$3"

    local attempt=1
    local status=0

    while true
    do
        machine_scp_from "$machine" "$remote_file" "$local_target"
        status=$?

        if [ "$status" -eq 0 ]; then
            return 0
        fi

        if [ "$status" -ne 255 ] || [ "$attempt" -ge "$SSH_RETRY_ATTEMPTS" ]; then
            return "$status"
        fi

        echo "[$machine] SCP transport failed with exit $status; retrying attempt $((attempt + 1))/$SSH_RETRY_ATTEMPTS after ${SSH_RETRY_DELAY_SECONDS}s"
        sleep "$SSH_RETRY_DELAY_SECONDS"
        attempt=$((attempt + 1))
    done
}

collect_run_artifacts() {
    local artifact_flow_index
    local flow_name
    local copy_pids
    local machine_index
    local pid
    local flow_copy_status
    local copy_overall_status=0

    if [ "$ARTIFACT_COLLECTION_DONE" -eq 1 ]; then
        return 0
    fi

    ARTIFACT_COLLECTION_DONE=1

    if [ "${#ARTIFACT_FLOW_INDEXES[@]}" -eq 0 ]; then
        return 0
    fi

    echo ""
    echo "===================================="
    echo "Copying load-test logs and summaries"
    echo "===================================="

    for artifact_flow_index in "${ARTIFACT_FLOW_INDEXES[@]}"
    do
        flow_name="${FLOW_NAMES[$artifact_flow_index]}"
        echo "Copying flow=$flow_name"

        copy_pids=()
        for machine_index in "${!MACHINES[@]}"
        do
        (
            machine="${MACHINES[$machine_index]}"
            flow_run_id="${RUN_ID}_${machine}_${flow_name}"
            log_file="loadtest_${flow_run_id}.log"
            summary_file="summary_${flow_run_id}.txt"
            copy_status=0

            mkdir -p "results/$RUN_ID/$machine"

            # Download log
            if machine_scp_from_retry "$machine" "load-test/$log_file" "results/$RUN_ID/$machine/"
            then
                echo "[$machine][$flow_name] ✅ log copied"
            else
                echo "[$machine][$flow_name] ❌ log copy FAILED"
                copy_status=1
            fi

            # Download summary
            if machine_scp_from_retry "$machine" "load-test/$summary_file" "results/$RUN_ID/$machine/"
            then
                echo "[$machine][$flow_name] ✅ summary copied"
            else
                echo "[$machine][$flow_name] ❌ summary copy FAILED"
                copy_status=1
            fi

            if [ "$copy_status" -eq 0 ] && \
            [ -f "results/$RUN_ID/$machine/$log_file" ] && \
            [ -f "results/$RUN_ID/$machine/$summary_file" ]
            then
                echo "[$machine][$flow_name] ✅ copy complete"
                exit 0
            else
                echo "[$machine][$flow_name] ❌ copy FAILED"
                exit 1
            fi
        ) &
            copy_pids+=("$!")
        done

        flow_copy_status=0
        for pid in "${copy_pids[@]}"
        do
            if ! wait "$pid"; then
                flow_copy_status=1
            fi
        done

        if [ "$flow_copy_status" -eq 0 ]; then
            echo "[$flow_name] ✅ copied on all machines"
        else
            echo "[$flow_name] ❌ copy completed with failures"
            copy_overall_status=1
        fi
    done

    return "$copy_overall_status"
}

cleanup_metrics() {
    status="$1"

    if [ "$CLEANUP_DONE" -eq 0 ]; then
        CLEANUP_DONE=1

        if [ "$RUN_ARTIFACTS_ATTEMPTED" -eq 1 ]; then
            if ! collect_run_artifacts && [ "$status" -eq 0 ]; then
                status=1
            fi
        fi

        if [ "$METRICS_ATTEMPTED" -eq 1 ]; then
            echo ""
            echo "===================================="
            echo "Stopping and collecting instance metrics"
            echo "===================================="

            METRICS_RUN_ID="$RUN_ID" \
            LOCAL_METRICS_DIR="$METRICS_DIR" \
            MACHINES_OVERRIDE="$INSTANCE_METRICS_MACHINES_VALUE" \
            ./scripts/instance-metrics.sh stop

            METRICS_RUN_ID="$RUN_ID" \
            LOCAL_METRICS_DIR="$METRICS_DIR" \
            MACHINES_OVERRIDE="$INSTANCE_METRICS_MACHINES_VALUE" \
            ./scripts/instance-metrics.sh collect
        fi

        if [ "$K8S_METRICS_ATTEMPTED" -eq 1 ]; then
            echo ""
            echo "===================================="
            echo "Stopping and collecting Kubernetes metrics"
            echo "===================================="

            K8S_RUN_ID="$RUN_ID" \
            K8S_LOCAL_DIR="$K8S_METRICS_DIR" \
            ./scripts/k8s-cluster-metrics.sh stop

            K8S_RUN_ID="$RUN_ID" \
            K8S_LOCAL_DIR="$K8S_METRICS_DIR" \
            ./scripts/k8s-cluster-metrics.sh collect
        fi

        if [ "$GENERATE_CSV_REPORT" != "false" ]; then
            echo ""
            echo "===================================="
            echo "Generating CSV report"
            echo "===================================="

            if PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-/tmp/grafana-scrap-pycache}" \
                ./scripts/generate-load-test-report-csv.py "results/$RUN_ID"
            then
                echo "CSV report saved under:"
                echo "$REPORT_CSV_DIR"
            else
                echo "CSV report generation failed; keeping load-test exit status=$status"
            fi
        fi
    fi

    exit "$status"
}

trap 'cleanup_metrics 130' INT
trap 'cleanup_metrics 143' TERM

echo "===================================="
echo "RUN_ID=$RUN_ID"
echo "DefaultDuration=$DEFAULT_DURATION"
if [ -n "$DURATION_OVERRIDE" ]; then
    echo "DurationOverride=$DURATION_OVERRIDE"
else
    echo "FlowDurations=${FLOW_DURATIONS[*]}"
fi
echo "StreamUID=$STREAM_UID"
echo "StreamerUID=$STREAMER_UID"
echo "MachinePreset=$MACHINE_PRESET"
if [ -n "$START_FLOW_NAME" ]; then
    echo "StartFlow=$START_FLOW_NAME"
fi
echo "Machines=$MACHINES_OVERRIDE_VALUE"
echo "LoadGenerators=$LOAD_GENERATORS"
if [ "$COLLECT_INSTANCE_METRICS" != "false" ]; then
    echo "Instance metrics will be saved under:"
    echo "$METRICS_DIR"
    echo "Instance metrics machines=$INSTANCE_METRICS_MACHINES_VALUE"
else
    echo "Instance metrics disabled: COLLECT_INSTANCE_METRICS=$COLLECT_INSTANCE_METRICS"
fi
if [ "$COLLECT_K8S_METRICS" != "false" ]; then
    echo "Kubernetes metrics will be saved under:"
    echo "$K8S_METRICS_DIR"
else
    echo "Kubernetes metrics disabled: COLLECT_K8S_METRICS=$COLLECT_K8S_METRICS"
fi
if [ "$GENERATE_CSV_REPORT" != "false" ]; then
    echo "CSV report will be saved under:"
    echo "$REPORT_CSV_DIR"
else
    echo "CSV report disabled: GENERATE_CSV_REPORT=$GENERATE_CSV_REPORT"
fi
if [ "$DRY_RUN" = "true" ]; then
    echo "Dry run enabled: no SSH, dstat, Kubernetes, or load-test commands will run"
fi
print_regional_target_plan
echo "===================================="

if [ "$DRY_RUN" = "true" ]; then
    exit 0
fi

if ! require_machine_scp_tools "${MACHINES[@]}"; then
    exit 1
fi

mkdir -p "results/$RUN_ID"
if [ "$COLLECT_INSTANCE_METRICS" != "false" ]; then
    mkdir -p "$METRICS_DIR"
fi
if [ "$COLLECT_K8S_METRICS" != "false" ]; then
    mkdir -p "$K8S_METRICS_DIR"
fi

if [ "$COLLECT_INSTANCE_METRICS" != "false" ]; then
    MACHINES_OVERRIDE="$INSTANCE_METRICS_MACHINES_VALUE" ./scripts/ensure-dstat.sh
    ENSURE_DSTAT_STATUS=$?
    if [ "$ENSURE_DSTAT_STATUS" -ne 0 ]; then
        echo "dstat check/install failed; aborting test"
        exit "$ENSURE_DSTAT_STATUS"
    fi
fi

# =========================
# Pre-flight validation
# =========================

if [ "${#FLOW_NAMES[@]}" -ne "${#FLOW_IDS[@]}" ] || \
    [ "${#FLOW_API_COUNTS[@]}" -ne "${#FLOW_IDS[@]}" ] || \
    [ "${#FLOW_RPS_WORKERS[@]}" -ne "${#FLOW_IDS[@]}" ] || \
    [ "${#FLOW_DURATIONS[@]}" -ne "${#FLOW_IDS[@]}" ]
then
    echo "Flow config length mismatch:"
    echo "  FLOW_NAMES=${#FLOW_NAMES[@]}"
    echo "  FLOW_IDS=${#FLOW_IDS[@]}"
    echo "  FLOW_API_COUNTS=${#FLOW_API_COUNTS[@]}"
    echo "  FLOW_RPS_WORKERS=${#FLOW_RPS_WORKERS[@]}"
    echo "  FLOW_DURATIONS=${#FLOW_DURATIONS[@]}"
    exit 1
fi

for flow_index in "${!FLOW_IDS[@]}"
do
    if [ -z "${FLOW_NAMES[$flow_index]}" ] || \
        [ -z "${FLOW_IDS[$flow_index]}" ] || \
        [ -z "${FLOW_API_COUNTS[$flow_index]}" ] || \
        [ -z "${FLOW_RPS_WORKERS[$flow_index]}" ] || \
        [ -z "${FLOW_DURATIONS[$flow_index]}" ]
    then
        echo "Flow config has an empty value at index $flow_index"
        echo "  name=${FLOW_NAMES[$flow_index]}"
        echo "  id=${FLOW_IDS[$flow_index]}"
        echo "  api_count=${FLOW_API_COUNTS[$flow_index]}"
        echo "  rps_workers=${FLOW_RPS_WORKERS[$flow_index]}"
        echo "  duration=${FLOW_DURATIONS[$flow_index]}"
        exit 1
    fi

    if ! duration_seconds "${FLOW_DURATIONS[$flow_index]}" >/dev/null; then
        echo "Invalid duration at index $flow_index: ${FLOW_DURATIONS[$flow_index]}"
        exit 1
    fi
done

for machine in "${MACHINES[@]}"
do
    echo "Checking $machine"

    host="$(machine_host "$machine" || true)"

    if [ -z "$host" ]; then
        echo "❌ $machine unknown machine"
        exit 1
    fi

    if ! machine_region_label "$machine" >/dev/null || ! machine_users_k "$machine" >/dev/null; then
        echo "❌ $machine does not have a regional v6 user target"
        exit 1
    fi

    if machine_ssh_retry "$machine" "hostname" >/dev/null
    then
        echo "✅ $machine"
    else
        echo "❌ $machine"
        exit 1
    fi
done

if [ "$COLLECT_INSTANCE_METRICS" != "false" ]; then
    METRICS_ATTEMPTED=1
    METRICS_RUN_ID="$RUN_ID" \
    LOCAL_METRICS_DIR="$METRICS_DIR" \
    MACHINES_OVERRIDE="$INSTANCE_METRICS_MACHINES_VALUE" \
    ./scripts/instance-metrics.sh start
    METRICS_START_STATUS=$?
    if [ "$METRICS_START_STATUS" -ne 0 ]; then
        echo "instance metrics start failed; stopping any partial collectors"
        cleanup_metrics "$METRICS_START_STATUS"
    fi
fi

if [ "$COLLECT_K8S_METRICS" != "false" ]; then
    K8S_METRICS_ATTEMPTED=1
    K8S_RUN_ID="$RUN_ID" \
    K8S_LOCAL_DIR="$K8S_METRICS_DIR" \
    ./scripts/k8s-cluster-metrics.sh start
    K8S_METRICS_START_STATUS=$?
    if [ "$K8S_METRICS_START_STATUS" -ne 0 ]; then
        echo "Kubernetes metrics start failed; stopping any partial collectors"
        cleanup_metrics "$K8S_METRICS_START_STATUS"
    fi
fi

# =========================
# Execute
# =========================

OVERALL_STATUS=0

for flow_index in "${!FLOW_IDS[@]}"
do
    if [ "$flow_index" -lt "$START_FLOW_INDEX" ]; then
        if [ -n "$START_FLOW_NAME" ]; then
            echo "Skipping flow=${FLOW_NAMES[$flow_index]} before StartFlow=$START_FLOW_NAME"
        fi
        continue
    fi

    flow_name="${FLOW_NAMES[$flow_index]}"
    flow_id="${FLOW_IDS[$flow_index]}"
    api_count="${FLOW_API_COUNTS[$flow_index]}"
    rps_workers="${FLOW_RPS_WORKERS[$flow_index]}"
    duration="${DURATION_OVERRIDE:-${FLOW_DURATIONS[$flow_index]}}"

    echo ""
    echo "===================================="
    echo "Starting flow=$flow_name flow_id=$flow_id api_count=$api_count duration=$duration"
    echo "===================================="

    RUN_ARTIFACTS_ATTEMPTED=1
    ARTIFACT_FLOW_INDEXES+=("$flow_index")
    pids=()

    for machine_index in "${!MACHINES[@]}"
    do
    (
        machine="${MACHINES[$machine_index]}"
        host="$(machine_host "$machine" || true)"
        region_label="$(machine_region_label "$machine" || true)"
        users_k="$(machine_users_k "$machine" || true)"
        region_machine_count="$(selected_region_machine_count "$machine" || true)"
        regional_target_rps="$(regional_target_rps "$machine" "$flow_index" "$duration" || true)"
        local_target_rps="$(local_target_rps "$machine" "$flow_index" "$duration" || true)"

        if [ -z "$host" ] || \
            [ -z "$region_label" ] || \
            [ -z "$users_k" ] || \
            [ -z "$region_machine_count" ] || \
            [ -z "$regional_target_rps" ] || \
            [ -z "$local_target_rps" ]
        then
            echo "[$machine][$flow_name] ❌ unknown machine"
            exit 1
        fi

        remote_target_rps=$((local_target_rps * LOAD_GENERATORS))

        mkdir -p "results/$RUN_ID/$machine"

        flow_run_id="${RUN_ID}_${machine}_${flow_name}"
        log_file="loadtest_${flow_run_id}.log"
        summary_file="summary_${flow_run_id}.txt"

        echo "[$machine][$flow_name] Region=$region_label UsersK=$users_k RegionMachines=$region_machine_count FlowID=$flow_id ApiCount=$api_count RegionalTargetRPS=$regional_target_rps LocalTargetRPS=$local_target_rps RemoteTargetRPS=$remote_target_rps Duration=$duration"

        machine_ssh_retry "$machine" "
            cd ~/load-test || exit 1

            LOG_FILE=$log_file
            SUMMARY_FILE=$summary_file

            START_TIME=\$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')

            echo '=================================' > \$SUMMARY_FILE
            echo 'Machine=$machine' >> \$SUMMARY_FILE
            echo 'Region=$region_label' >> \$SUMMARY_FILE
            echo 'UsersK=$users_k' >> \$SUMMARY_FILE
            echo 'RegionMachines=$region_machine_count' >> \$SUMMARY_FILE
            echo 'FlowName=$flow_name' >> \$SUMMARY_FILE
            echo 'FlowID=$flow_id' >> \$SUMMARY_FILE
            echo 'ApiCount=$api_count' >> \$SUMMARY_FILE
            echo 'RegionalTargetRPS=$regional_target_rps' >> \$SUMMARY_FILE
            echo 'LocalTargetRPS=$local_target_rps' >> \$SUMMARY_FILE
            echo 'TargetRPS=$local_target_rps' >> \$SUMMARY_FILE
            echo 'RemoteTargetRPS=$remote_target_rps' >> \$SUMMARY_FILE
            echo 'Workers=$rps_workers' >> \$SUMMARY_FILE
            echo 'Duration=$duration' >> \$SUMMARY_FILE
            echo 'LoadGenerators=$LOAD_GENERATORS' >> \$SUMMARY_FILE
            echo 'LoadGeneratorIndex=$machine_index' >> \$SUMMARY_FILE
            echo 'StreamUID=$STREAM_UID' >> \$SUMMARY_FILE
            echo 'StreamerUID=$STREAMER_UID' >> \$SUMMARY_FILE
            echo 'RunID=$flow_run_id' >> \$SUMMARY_FILE
            echo 'StartTimeIST='\$START_TIME >> \$SUMMARY_FILE

            export PATH=/usr/local/go/bin:/usr/lib/go-1.22/bin:\$HOME/go/bin:/root/go/bin:\$PATH

            GO_BIN=\$(command -v go || true)

            if [ -z \"\$GO_BIN\" ]; then
                echo 'Go not found' >> \$SUMMARY_FILE
                exit 1
            fi

            echo 'GoBinary='\$GO_BIN >> \$SUMMARY_FILE
            echo 'GoVersion='\"\$(go version)\" >> \$SUMMARY_FILE

            MODE=rps \
            RUN_ID=$flow_run_id \
            STREAM_UID=$STREAM_UID \
            STREAMER_UID=$STREAMER_UID \
            FLOW_ID=$flow_id \
            TARGET_RPS=$remote_target_rps \
            RPS_WORKERS=$rps_workers \
            DURATION=$duration \
            LOAD_GENERATORS=$LOAD_GENERATORS \
            LOAD_GENERATOR_INDEX=$machine_index \
            RPS_DRAIN_TIMEOUT=$RPS_DRAIN_TIMEOUT \
            ./scripts/run-direct.sh > \$LOG_FILE 2>&1

            EXIT_CODE=\$?
            END_TIME=\$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')

            echo 'ExitCode='\$EXIT_CODE >> \$SUMMARY_FILE
            echo 'EndTimeIST='\$END_TIME >> \$SUMMARY_FILE
            echo '=================================' >> \$SUMMARY_FILE
            exit \$EXIT_CODE
        "

        remote_status=$?

        if [ "$remote_status" -eq 0 ]; then
            echo "[$machine][$flow_name] ✅ remote run completed"
            exit 0
        else
            echo "[$machine][$flow_name] ❌ remote run FAILED"
            exit 1
        fi
    ) &
        pids+=("$!")
    done

    flow_status=0
    for pid in "${pids[@]}"
    do
        if ! wait "$pid"; then
            flow_status=1
        fi
    done

    if [ "$flow_status" -eq 0 ]; then
        echo "[$flow_name] ✅ remote run completed on all machines"
    else
        echo "[$flow_name] ❌ remote run completed with failures"
        OVERALL_STATUS=1
    fi
done

if [ "$RUN_ARTIFACTS_ATTEMPTED" -eq 1 ]; then
    if ! collect_run_artifacts; then
        OVERALL_STATUS=1
    fi
fi

echo ""
echo "===================================="
echo "ALL TESTS COMPLETED"
echo "Results saved under:"
echo "results/$RUN_ID"
if [ "$COLLECT_INSTANCE_METRICS" != "false" ]; then
    echo "Instance metrics saved under:"
    echo "$METRICS_DIR"
fi
if [ "$COLLECT_K8S_METRICS" != "false" ]; then
    echo "Kubernetes metrics saved under:"
    echo "$K8S_METRICS_DIR"
fi
if [ "$GENERATE_CSV_REPORT" != "false" ]; then
    echo "CSV report will be generated under:"
    echo "$REPORT_CSV_DIR"
fi
echo "===================================="

cleanup_metrics "$OVERALL_STATUS"
