#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT" || exit 1

MACHINES="${MACHINES:-load-test-linux-philippines-01 load-test-linux-philippines-02 load-test-linux-philippines-03 load-test-linux-philippines-04 load-test-linux-philippines-05}"
RUN_ID="${RUN_ID:-philippines_single_api_flows_$(date +%Y%m%d_%H%M%S)}"
DRY_RUN="${DRY_RUN:-false}"
GENERATE_FINAL_CSV="${GENERATE_FINAL_CSV:-true}"

usage() {
    cat <<'EOF'
Usage:
  ./scripts/run-philippines-single-api-flows.sh [flags]

Runs Philippines single-api flows 84-89 and Feed v5 flow 91 with:
  - 3 minute pre-soak
  - 1 minute burst
  - 1 API per flow
  - one shared RUN_ID/results folder

Flags:
  --run-id ID       Use a fixed RUN_ID. Default: philippines_single_api_flows_<timestamp>
  --machines LIST   Override target machines.
  --dry-run         Print resolved runs without SSH/load.
  --no-csv          Skip final CSV generation.
  -h, --help        Show this help.

Environment overrides:
  RUN_ID=my_run ./scripts/run-philippines-single-api-flows.sh
  STREAM_UID=<stream_uid> STREAMER_UID=<streamer_uid> ./scripts/run-philippines-single-api-flows.sh
  FEED_BASE_URL=https://qa-api.loco.com/fd/ ./scripts/run-philippines-single-api-flows.sh
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
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
        --machines)
            if [ "$#" -lt 2 ]; then
                echo "--machines requires a quoted, space-separated value"
                exit 1
            fi
            MACHINES="$2"
            shift 2
            ;;
        --machines=*)
            MACHINES="${1#*=}"
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

run_phase() {
    local flow_id="$1"
    local flow_base="$2"
    local phase="$3"
    local duration="$4"
    local flow_name="${flow_base}_${phase}"

    echo ""
    echo "===================================="
    echo "Running flow_id=$flow_id flow=$flow_name duration=$duration RUN_ID=$RUN_ID"
    echo "===================================="

    args=(
        --no-k8s
        --no-dstat
        --no-csv
        --machines "$MACHINES"
        --run-id "$RUN_ID"
        --flow-id "$flow_id"
        --api-count 1
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

    run_phase "$flow_id" "$flow_base" pre_soak 180s
    run_phase "$flow_id" "$flow_base" burst 60s
}

echo "RUN_ID=$RUN_ID"
echo "Machines=$MACHINES"
echo "ResultsDir=results/$RUN_ID"

# Keep the feed-like APIs spaced out; run Feed v5 after the existing focused flows.
run_flow 87 fetch_web_home_feed_1
run_flow 84 wallet_all
run_flow 85 sticker_tabs_all
run_flow 88 fetch_web_home_feed_2
run_flow 86 stickers_all
run_flow 89 fetch_trending_v2_feed
run_flow 91 feed_v5_webhome

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
