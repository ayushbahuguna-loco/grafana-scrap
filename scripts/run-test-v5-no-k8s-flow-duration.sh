#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=machine-passwords.sh
. "$SCRIPT_DIR/machine-passwords.sh"

# =========================
# Machine Config
# =========================

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


# =========================
# Load Test Config
# =========================

SCRIPT_VERSION="api_coverage_v1_no_k8s"
DEFAULT_DURATION="${DEFAULT_DURATION:-600s}"
RPS_DRAIN_TIMEOUT="${RPS_DRAIN_TIMEOUT:-10s}"
STREAM_UID="${STREAM_UID:-e2c4c964-31b3-424e-a7c0-7a22a65a3bba}"
STREAMER_UID="${STREAMER_UID:-2L6YZ1RZU0}"

# These are total scenario targets for the full load-generator fleet. The
# script passes LOAD_GENERATORS and LOAD_GENERATOR_INDEX so each target is split
# across MACHINES. Do not divide TARGET_RPS manually per machine.
#
# Flow 7 is still split into focused flows here because the bundled flow had
# 500/503 noise in previous runs. Chat flow 12 is included at a deliberately
# low target because it is not a clean exact-RPS flow in mode=rps.
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
)

FLOW_TARGET_RPS=(
    1750
    5250
    525
    #
    1500
    4500
    450
    #
    1500
    4500
    450
    #
    750
    2250
    225
    #
    100
    300
    30
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
)

# Duration for each flow, aligned by index with FLOW_NAMES/FLOW_IDS.
FLOW_DURATIONS=(
  180s
  60s
  600s
  1800s
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

RUN_ID="${RUN_ID:-${SCRIPT_VERSION}_$(date +%Y%m%d_%H%M%S)}"
METRICS_DIR="results/$RUN_ID/instance-metrics"
K8S_METRICS_DIR="results/$RUN_ID/k8s-cluster-metrics"
REPORT_CSV_DIR="results/$RUN_ID/summary-csv"
# No-K8S clone: keep this hard-disabled so the script does not SSH into
# K8S_SSH_HOST (`my-machine` by default) through scripts/k8s-cluster-metrics.sh.
COLLECT_K8S_METRICS="false"
GENERATE_CSV_REPORT="${GENERATE_CSV_REPORT:-true}"
CLEANUP_DONE=0
METRICS_ATTEMPTED=0
K8S_METRICS_ATTEMPTED=0

MACHINES=(
    turkey-01
    turkey-02
    turkey-03
)

LOAD_GENERATORS="${#MACHINES[@]}"
MACHINES_OVERRIDE_VALUE="${MACHINES[*]}"

cleanup_metrics() {
    status="$1"

    if [ "$CLEANUP_DONE" -eq 0 ]; then
        CLEANUP_DONE=1

        if [ "$METRICS_ATTEMPTED" -eq 1 ]; then
            echo ""
            echo "===================================="
            echo "Stopping and collecting instance metrics"
            echo "===================================="

            METRICS_RUN_ID="$RUN_ID" \
            LOCAL_METRICS_DIR="$METRICS_DIR" \
            MACHINES_OVERRIDE="$MACHINES_OVERRIDE_VALUE" \
            ./scripts/instance-metrics.sh stop

            METRICS_RUN_ID="$RUN_ID" \
            LOCAL_METRICS_DIR="$METRICS_DIR" \
            MACHINES_OVERRIDE="$MACHINES_OVERRIDE_VALUE" \
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
echo "FlowDurations=${FLOW_DURATIONS[*]}"
echo "StreamUID=$STREAM_UID"
echo "StreamerUID=$STREAMER_UID"
echo "Instance metrics will be saved under:"
echo "$METRICS_DIR"
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
echo "===================================="

mkdir -p "results/$RUN_ID" "$METRICS_DIR"
if [ "$COLLECT_K8S_METRICS" != "false" ]; then
    mkdir -p "$K8S_METRICS_DIR"
fi

MACHINES_OVERRIDE="$MACHINES_OVERRIDE_VALUE" ./scripts/ensure-dstat.sh
ENSURE_DSTAT_STATUS=$?
if [ "$ENSURE_DSTAT_STATUS" -ne 0 ]; then
    echo "dstat check/install failed; aborting test"
    exit "$ENSURE_DSTAT_STATUS"
fi

# =========================
# Pre-flight validation
# =========================

if [ "${#FLOW_NAMES[@]}" -ne "${#FLOW_IDS[@]}" ] || \
    [ "${#FLOW_TARGET_RPS[@]}" -ne "${#FLOW_IDS[@]}" ] || \
    [ "${#FLOW_RPS_WORKERS[@]}" -ne "${#FLOW_IDS[@]}" ] || \
    [ "${#FLOW_DURATIONS[@]}" -ne "${#FLOW_IDS[@]}" ]
then
    echo "Flow config length mismatch:"
    echo "  FLOW_NAMES=${#FLOW_NAMES[@]}"
    echo "  FLOW_IDS=${#FLOW_IDS[@]}"
    echo "  FLOW_TARGET_RPS=${#FLOW_TARGET_RPS[@]}"
    echo "  FLOW_RPS_WORKERS=${#FLOW_RPS_WORKERS[@]}"
    echo "  FLOW_DURATIONS=${#FLOW_DURATIONS[@]}"
    exit 1
fi

for flow_index in "${!FLOW_IDS[@]}"
do
    if [ -z "${FLOW_NAMES[$flow_index]}" ] || \
        [ -z "${FLOW_IDS[$flow_index]}" ] || \
        [ -z "${FLOW_TARGET_RPS[$flow_index]}" ] || \
        [ -z "${FLOW_RPS_WORKERS[$flow_index]}" ] || \
        [ -z "${FLOW_DURATIONS[$flow_index]}" ]
    then
        echo "Flow config has an empty value at index $flow_index"
        echo "  name=${FLOW_NAMES[$flow_index]}"
        echo "  id=${FLOW_IDS[$flow_index]}"
        echo "  target_rps=${FLOW_TARGET_RPS[$flow_index]}"
        echo "  rps_workers=${FLOW_RPS_WORKERS[$flow_index]}"
        echo "  duration=${FLOW_DURATIONS[$flow_index]}"
        exit 1
    fi
done

for machine in "${MACHINES[@]}"
do
    echo "Checking $machine"

    host="$(machine_host "$machine" || true)"
    password="$(machine_password "$machine" || true)"

    if [ -z "$host" ] || [ -z "$password" ]; then
        echo "❌ $machine unknown machine"
        exit 1
    fi

    if sshpass -p "$password" \
        ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=30 \
        root@"$host" \
        "hostname" >/dev/null
    then
        echo "✅ $machine"
    else
        echo "❌ $machine"
        exit 1
    fi
done

METRICS_ATTEMPTED=1
METRICS_RUN_ID="$RUN_ID" \
LOCAL_METRICS_DIR="$METRICS_DIR" \
MACHINES_OVERRIDE="$MACHINES_OVERRIDE_VALUE" \
./scripts/instance-metrics.sh start
METRICS_START_STATUS=$?
if [ "$METRICS_START_STATUS" -ne 0 ]; then
    echo "instance metrics start failed; stopping any partial collectors"
    cleanup_metrics "$METRICS_START_STATUS"
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
    flow_name="${FLOW_NAMES[$flow_index]}"
    flow_id="${FLOW_IDS[$flow_index]}"
    target_rps="${FLOW_TARGET_RPS[$flow_index]}"
    rps_workers="${FLOW_RPS_WORKERS[$flow_index]}"
    duration="${FLOW_DURATIONS[$flow_index]}"

    echo ""
    echo "===================================="
    echo "Starting flow=$flow_name flow_id=$flow_id target_rps=$target_rps duration=$duration"
    echo "===================================="

    pids=()

    for machine_index in "${!MACHINES[@]}"
    do
    (
        machine="${MACHINES[$machine_index]}"
        host="$(machine_host "$machine" || true)"
        password="$(machine_password "$machine" || true)"

        if [ -z "$host" ] || [ -z "$password" ]; then
            echo "[$machine][$flow_name] ❌ unknown machine"
            exit 1
        fi

        mkdir -p "results/$RUN_ID/$machine"

        flow_run_id="${RUN_ID}_${machine}_${flow_name}"
        log_file="loadtest_${flow_run_id}.log"
        summary_file="summary_${flow_run_id}.txt"

        echo "[$machine][$flow_name] FlowID=$flow_id TargetRPS=$target_rps Duration=$duration"

        sshpass -p "$password" \
        ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=30 \
        root@"$host" "
            cd ~/load-test || exit 1

            LOG_FILE=$log_file
            SUMMARY_FILE=$summary_file

            START_TIME=\$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')

            echo '=================================' > \$SUMMARY_FILE
            echo 'Machine=$machine' >> \$SUMMARY_FILE
            echo 'FlowName=$flow_name' >> \$SUMMARY_FILE
            echo 'FlowID=$flow_id' >> \$SUMMARY_FILE
            echo 'TargetRPS=$target_rps' >> \$SUMMARY_FILE
            echo 'Workers=$rps_workers' >> \$SUMMARY_FILE
            echo 'Duration=$duration' >> \$SUMMARY_FILE
            echo 'LoadGenerators=$LOAD_GENERATORS' >> \$SUMMARY_FILE
            echo 'LoadGeneratorIndex=$machine_index' >> \$SUMMARY_FILE
            echo 'StreamUID=$STREAM_UID' >> \$SUMMARY_FILE
            echo 'StreamerUID=$STREAMER_UID' >> \$SUMMARY_FILE
            echo 'RunID=$flow_run_id' >> \$SUMMARY_FILE
            echo 'StartTimeIST='\$START_TIME >> \$SUMMARY_FILE

            export PATH=/usr/local/go/bin:/usr/lib/go-1.22/bin:/root/go/bin:\$PATH

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
            TARGET_RPS=$target_rps \
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
        copy_status=0

        # Download log
        if sshpass -p "$password" \
            scp \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=30 \
            root@"$host":~/load-test/"$log_file" \
            "results/$RUN_ID/$machine/"
        then
            echo "[$machine][$flow_name] ✅ log copied"
        else
            echo "[$machine][$flow_name] ❌ log copy FAILED"
            copy_status=1
        fi

        # Download summary
        if sshpass -p "$password" \
            scp \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=30 \
            root@"$host":~/load-test/"$summary_file" \
            "results/$RUN_ID/$machine/"
        then
            echo "[$machine][$flow_name] ✅ summary copied"
        else
            echo "[$machine][$flow_name] ❌ summary copy FAILED"
            copy_status=1
        fi

        if [ "$remote_status" -eq 0 ] && \
        [ "$copy_status" -eq 0 ] && \
        [ -f "results/$RUN_ID/$machine/$log_file" ] && \
        [ -f "results/$RUN_ID/$machine/$summary_file" ]
        then
            echo "[$machine][$flow_name] ✅ SUCCESS"
            exit 0
        else
            echo "[$machine][$flow_name] ❌ FAILED"
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
        echo "[$flow_name] ✅ completed on all machines"
    else
        echo "[$flow_name] ❌ completed with failures"
        OVERALL_STATUS=1
    fi
done

echo ""
echo "===================================="
echo "ALL TESTS COMPLETED"
echo "Results saved under:"
echo "results/$RUN_ID"
echo "Instance metrics saved under:"
echo "$METRICS_DIR"
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
