#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT" || exit 1

MACHINES="load-test-linux-philippines-01 load-test-linux-philippines-02 load-test-linux-philippines-03"
RUN_ID="${RUN_ID:-}"
PROFILE="${PROFILE:-core}"
DRY_RUN="${DRY_RUN:-false}"
GENERATE_FINAL_CSV="${GENERATE_FINAL_CSV:-true}"

usage() {
    cat <<'EOF'
Usage:
  ./scripts/run-philippines-core-flows.sh [flags]

Runs a flow profile on the three Philippines load generators for a 100k-user
regional target.

Profiles:
  core (default)
    Flows: 76 auth, 77 feed, 90 stream_v2, 79 chat
    Timings: 1 minute pre-soak, 2 minute burst, 3 minute soak

  all
    Flows: 41 leaderboard, 76 auth, 77 feed, 78 stream, 79 chat,
           80 quest_rewards, 82 search, 83 flow_83, 90 stream_v2
    Timings: 4 minute pre-soak, 2 minute burst, 15 minute soak

Flags:
  --profile NAME    Run the core or all profile. Default: core.
  --run-id ID       Use a fixed RUN_ID. Default: philippines_<profile>_flows_<timestamp>
  --dry-run         Print every resolved run without SSH or load generation.
  --no-csv          Skip final CSV generation.
  -h, --help        Show this help.

Environment overrides:
  PROFILE=all ./scripts/run-philippines-core-flows.sh
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
    core|all)
        ;;
    *)
        echo "Unknown profile: $PROFILE"
        echo "Supported profiles: core, all"
        exit 1
        ;;
esac

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
        --no-k8s
        --no-dstat
        --no-csv
        --machines "$MACHINES"
        --run-id "$RUN_ID"
        --flow-id "$flow_id"
        --api-count "$api_count"
        --flow-name "$flow_name"
        --flow-duration "$duration"
    )

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

echo "RUN_ID=$RUN_ID"
echo "Profile=$PROFILE"
echo "Machines=$MACHINES"
echo "PhilippinesUsers=100k"
echo "ResultsDir=results/$RUN_ID"

if [ "$PROFILE" = "core" ]; then
    run_flow 76 auth 7 60s 120s 180s
    run_flow 77 feed 5 60s 120s 180s
    run_flow 90 stream_v2 2 60s 120s 180s
    run_flow 79 chat 3 60s 120s 180s
else
    run_flow 41 leaderboard 5 240s 120s 900s
    run_flow 76 auth 7 240s 120s 900s
    run_flow 77 feed 5 240s 120s 900s
    run_flow 78 stream 6 240s 120s 900s
    run_flow 79 chat 3 240s 120s 900s
    run_flow 80 quest_rewards 2 240s 120s 900s
    run_flow 82 search 2 240s 120s 900s
    run_flow 83 flow_83 6 240s 120s 900s
    run_flow 90 stream_v2 2 240s 120s 900s
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
