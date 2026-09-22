#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT" || exit 1

MACHINES="load-test-linux-philippines-01 load-test-linux-philippines-02 load-test-linux-philippines-03 load-test-linux-philippines-04 load-test-linux-philippines-05"
RUN_ID="${RUN_ID:-}"
PROFILE="${PROFILE:-core}"
USERS_K="${PHILIPPINES_USERS_K:-}"
USERS_K_EXPLICIT="false"
if [ -n "$USERS_K" ]; then
    USERS_K_EXPLICIT="true"
fi
DRY_RUN="${DRY_RUN:-false}"
GENERATE_FINAL_CSV="${GENERATE_FINAL_CSV:-true}"
COLLECT_K8S_METRICS="${COLLECT_K8S_METRICS:-false}"
FLOW_FILTER="${FLOW_FILTER:-}"

usage() {
    cat <<'EOF'
Usage:
  ./scripts/run-philippines-core-flows.sh [flags]

Runs a flow profile on the five Philippines load generators for a 100k-user
regional target.

Profiles:
  core (default)
    Flows: 76 auth, 77 feed, 90 stream_v2, 79 chat
    Timings: 1 minute pre-soak, 2 minute burst, 3 minute soak

  all
    Flows: 41 leaderboard, 76 auth, 77 feed, 78 stream, 79 chat,
           80 quest_rewards, 82 search, 83 flow_83, 90 stream_v2
    Timings: 4 minute pre-soak, 2 minute burst, 15 minute soak

  smoke
    Flows: all nine flows from the all profile
    Target: 0.1k (100 users)
    Timing: one 10-second smoke phase per flow

Flags:
  --profile NAME    Run the core, all, or smoke profile. Default: core.
  --users-k NUMBER  Set the Philippines regional user target in thousands. Default: 100.
                     The smoke profile defaults to 0.1 (100 users).
  --flows "76 78"   Run only these flow IDs from the selected profile.
  --no-k8s          Disable Kubernetes monitoring. Default.
  --with-k8s        Enable Kubernetes monitoring for each phase.
  --run-id ID       Use a fixed RUN_ID. Default: philippines_<profile>_flows_<timestamp>
  --dry-run         Print every resolved run without SSH or load generation.
  --no-csv          Skip final CSV generation.
  -h, --help        Show this help.

Environment overrides:
  PROFILE=all ./scripts/run-philippines-core-flows.sh
  PHILIPPINES_USERS_K=25 ./scripts/run-philippines-core-flows.sh
  RUN_ID=my_run ./scripts/run-philippines-core-flows.sh
  STREAM_UID=<stream_uid> STREAMER_UID=<streamer_uid> ./scripts/run-philippines-core-flows.sh
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --profile)
            if [ "$#" -lt 2 ]; then
                echo "--profile requires a value"
                exit 1
            fi
            PROFILE="$2"
            shift 2
            ;;
        --profile=*)
            PROFILE="${1#*=}"
            shift
            ;;
        --users-k|--philippines-users-k)
            if [ "$#" -lt 2 ]; then
                echo "--users-k requires a value"
                exit 1
            fi
            USERS_K="$2"
            USERS_K_EXPLICIT="true"
            shift 2
            ;;
        --users-k=*|--philippines-users-k=*)
            USERS_K="${1#*=}"
            USERS_K_EXPLICIT="true"
            shift
            ;;
        --flows)
            if [ "$#" -lt 2 ]; then
                echo "--flows requires a quoted, space-separated list of flow IDs"
                exit 1
            fi
            FLOW_FILTER="$2"
            shift 2
            ;;
        --flows=*)
            FLOW_FILTER="${1#*=}"
            shift
            ;;
        --no-k8s)
            COLLECT_K8S_METRICS="false"
            shift
            ;;
        --with-k8s|--k8s)
            COLLECT_K8S_METRICS="true"
            shift
            ;;
        --run-id)
            if [ "$#" -lt 2 ]; then
                echo "--run-id requires a value"
                exit 1
            fi
            RUN_ID="$2"
            shift 2
            ;;
        --run-id=*)
            RUN_ID="${1#*=}"
            shift
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --no-csv)
            GENERATE_FINAL_CSV="false"
            shift
            ;;
        *)
            echo "Unknown flag: $1"
            usage
            exit 1
            ;;
    esac
done

case "$PROFILE" in
    core|all|smoke)
        ;;
    *)
        echo "Unknown profile: $PROFILE"
        echo "Supported profiles: core, all, smoke"
        exit 1
        ;;
esac

if [ "$USERS_K_EXPLICIT" = "false" ]; then
    if [ "$PROFILE" = "smoke" ]; then
        USERS_K="0.1"
    else
        USERS_K="100"
    fi
fi

FLOW_FILTER="${FLOW_FILTER//,/ }"
for selected_flow_id in $FLOW_FILTER; do
    case "$selected_flow_id" in
        41|76|77|78|79|80|82|83|90)
            ;;
        *)
            echo "Unsupported flow ID in --flows: $selected_flow_id"
            echo "Supported flow IDs: 41, 76, 77, 78, 79, 80, 82, 83, 90"
            exit 1
            ;;
    esac

    if [ "$PROFILE" = "core" ]; then
        case "$selected_flow_id" in
            76|77|79|90)
                ;;
            *)
                echo "Flow ID $selected_flow_id is not part of the core profile"
                echo "Use --profile all or --profile smoke for this flow"
                exit 1
                ;;
        esac
    fi
done

if ! [[ "$USERS_K" =~ ^[0-9]+([.][0-9]+)?$ ]] || \
    ! awk -v users_k="$USERS_K" 'BEGIN { exit !(users_k > 0) }'
then
    echo "--users-k must be a positive number: $USERS_K"
    exit 1
fi

RUN_ID="${RUN_ID:-philippines_${PROFILE}_flows_$(date +%Y%m%d_%H%M%S)}"

run_phase() {
    local flow_id="$1"
    local flow_base="$2"
    local api_count="$3"
    local phase="$4"
    local duration="$5"
    local flow_name="${flow_base}_${phase}"
    local args

    echo ""
    echo "===================================="
    echo "Running flow_id=$flow_id flow=$flow_name api_count=$api_count duration=$duration RUN_ID=$RUN_ID"
    echo "===================================="

    args=(
        --no-dstat
        --no-csv
        --machines "$MACHINES"
        --philippines-users-k "$USERS_K"
        --run-id "$RUN_ID"
        --flow-id "$flow_id"
        --api-count "$api_count"
        --flow-name "$flow_name"
        --flow-duration "$duration"
    )

    if [ "$COLLECT_K8S_METRICS" = "true" ]; then
        args+=(--with-k8s)
    else
        args+=(--no-k8s)
    fi

    if [ "$DRY_RUN" = "true" ]; then
        args+=(--dry-run)
    fi

    ./scripts/run-test-v6.sh "${args[@]}"
}

run_flow() {
    local flow_id="$1"
    local flow_base="$2"
    local api_count="$3"
    local pre_soak_duration="$4"
    local burst_duration="$5"
    local soak_duration="$6"

    run_phase "$flow_id" "$flow_base" "$api_count" pre_soak "$pre_soak_duration"
    run_phase "$flow_id" "$flow_base" "$api_count" burst "$burst_duration"
    run_phase "$flow_id" "$flow_base" "$api_count" soak "$soak_duration"
}

should_run_flow() {
    local flow_id="$1"
    local selected_flow_id

    if [ -z "$FLOW_FILTER" ]; then
        return 0
    fi

    for selected_flow_id in $FLOW_FILTER; do
        if [ "$selected_flow_id" = "$flow_id" ]; then
            return 0
        fi
    done

    return 1
}

run_selected_flow() {
    local flow_id="$1"
    shift

    if should_run_flow "$flow_id"; then
        run_flow "$flow_id" "$@"
    fi
}

run_smoke_flow() {
    local flow_id="$1"
    local flow_base="$2"
    local api_count="$3"

    if should_run_flow "$flow_id"; then
        run_phase "$flow_id" "$flow_base" "$api_count" smoke 10s
    fi
}

run_all_flows() {
    local pre_soak_duration="$1"
    local burst_duration="$2"
    local soak_duration="$3"

    run_selected_flow 41 leaderboard 5 "$pre_soak_duration" "$burst_duration" "$soak_duration"
    run_selected_flow 76 auth 7 "$pre_soak_duration" "$burst_duration" "$soak_duration"
    run_selected_flow 77 feed 5 "$pre_soak_duration" "$burst_duration" "$soak_duration"
    run_selected_flow 78 stream 6 "$pre_soak_duration" "$burst_duration" "$soak_duration"
    run_selected_flow 79 chat 3 "$pre_soak_duration" "$burst_duration" "$soak_duration"
    run_selected_flow 80 quest_rewards 2 "$pre_soak_duration" "$burst_duration" "$soak_duration"
    run_selected_flow 82 search 2 "$pre_soak_duration" "$burst_duration" "$soak_duration"
    run_selected_flow 83 flow_83 6 "$pre_soak_duration" "$burst_duration" "$soak_duration"
    run_selected_flow 90 stream_v2 2 "$pre_soak_duration" "$burst_duration" "$soak_duration"
}

run_smoke_flows() {
    run_smoke_flow 41 leaderboard 5
    run_smoke_flow 76 auth 7
    run_smoke_flow 77 feed 5
    run_smoke_flow 78 stream 6
    run_smoke_flow 79 chat 3
    run_smoke_flow 80 quest_rewards 2
    run_smoke_flow 82 search 2
    run_smoke_flow 83 flow_83 6
    run_smoke_flow 90 stream_v2 2
}

echo "RUN_ID=$RUN_ID"
echo "Profile=$PROFILE"
echo "Machines=$MACHINES"
echo "PhilippinesUsers=${USERS_K}k"
echo "KubernetesMetrics=$COLLECT_K8S_METRICS"
if [ -n "$FLOW_FILTER" ]; then
    echo "FlowFilter=$FLOW_FILTER"
fi
echo "ResultsDir=results/$RUN_ID"

if [ "$PROFILE" = "core" ]; then
    run_selected_flow 76 auth 7 60s 120s 180s
    run_selected_flow 77 feed 5 60s 120s 180s
    run_selected_flow 90 stream_v2 2 60s 120s 180s
    run_selected_flow 79 chat 3 60s 120s 180s
elif [ "$PROFILE" = "all" ]; then
    run_all_flows 240s 120s 900s
else
    run_smoke_flows
fi

if [ "$DRY_RUN" != "true" ] && [ "$GENERATE_FINAL_CSV" != "false" ]; then
    echo ""
    echo "===================================="
    echo "Generating final CSV report"
    echo "===================================="
    PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-/tmp/grafana-scrap-pycache}" \
        ./scripts/generate-load-test-report-csv.py "results/$RUN_ID"
fi

echo ""
echo "Done. Results saved under results/$RUN_ID"
