#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=machine-passwords.sh
. "$SCRIPT_DIR/machine-passwords.sh"

# =========================
# Machine Config
# =========================

declare -A HOSTS
declare -A FLOW_IDS
declare -A TARGET_RPS
declare -A RPS_WORKERS
declare -A DURATION

HOSTS["brazil-01"]="130.94.106.105"
HOSTS["brazil-02"]="130.94.107.80"
HOSTS["brazil-03"]="130.94.107.139"
HOSTS["brazil-04"]="130.94.106.176"

HOSTS["philippines-01"]="38.60.246.239"
HOSTS["philippines-02"]="38.54.36.76"
HOSTS["philippines-03"]="38.54.87.127"

HOSTS["turkey-01"]="38.54.105.173"
HOSTS["turkey-02"]="38.60.208.90"
HOSTS["turkey-03"]="38.60.255.75"

# =========================
# Load Test Config
# =========================

FLOW_IDS["brazil-01"]=42
FLOW_IDS["brazil-02"]=42
FLOW_IDS["brazil-03"]=42
FLOW_IDS["brazil-04"]=42

FLOW_IDS["philippines-01"]=42
FLOW_IDS["philippines-02"]=42
FLOW_IDS["philippines-03"]=42

FLOW_IDS["turkey-01"]=42
FLOW_IDS["turkey-02"]=42
FLOW_IDS["turkey-03"]=42

TARGET_RPS["brazil-01"]=1900
TARGET_RPS["brazil-02"]=1900
TARGET_RPS["brazil-03"]=1900
TARGET_RPS["brazil-04"]=1900

TARGET_RPS["philippines-01"]=1200
TARGET_RPS["philippines-02"]=1200
TARGET_RPS["philippines-03"]=1200

TARGET_RPS["turkey-01"]=1200
TARGET_RPS["turkey-02"]=1200
TARGET_RPS["turkey-03"]=1200

RPS_WORKERS["brazil-01"]=4800
RPS_WORKERS["brazil-02"]=4800
RPS_WORKERS["brazil-03"]=4800
RPS_WORKERS["brazil-04"]=4800

RPS_WORKERS["philippines-01"]=3600
RPS_WORKERS["philippines-02"]=3600
RPS_WORKERS["philippines-03"]=3600

RPS_WORKERS["turkey-01"]=3600
RPS_WORKERS["turkey-02"]=3600
RPS_WORKERS["turkey-03"]=3600

DURATION["brazil-01"]="30s"
DURATION["brazil-02"]="30s"
DURATION["brazil-03"]="30s"
DURATION["brazil-04"]="30s"

DURATION["philippines-01"]="30s"
DURATION["philippines-02"]="30s"
DURATION["philippines-03"]="30s"

DURATION["turkey-01"]="30s"
DURATION["turkey-02"]="30s"
DURATION["turkey-03"]="30s"

SCRIPT_VERSION="v2"

RUN_ID="${SCRIPT_VERSION}_$(date +%Y%m%d_%H%M%S)"

echo "===================================="
echo "RUN_ID=$RUN_ID"
echo "===================================="

MACHINES=(
  brazil-01
  brazil-02
  brazil-03
  brazil-04
)

# =========================
# Pre-flight validation
# =========================

for machine in "${MACHINES[@]}"
do
    echo "Checking $machine"

    password="$(machine_password "$machine" || true)"
    if [ -z "$password" ]; then
        exit 1
    fi

    if sshpass -p "$password" \
        ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        root@"${HOSTS[$machine]}" \
        "hostname" >/dev/null
    then
        echo "✅ $machine"
    else
        echo "❌ $machine"
        exit 1
    fi
done

mkdir -p "results/$RUN_ID"

# =========================
# Execute
# =========================

for machine in "${MACHINES[@]}"
do
(
    echo "[$machine] Starting"

    password="$(machine_password "$machine" || true)"
    if [ -z "$password" ]; then
        exit 1
    fi

    sshpass -p "$password" \
    ssh \
    -o StrictHostKeyChecking=no \
    root@"${HOSTS[$machine]}" "
        cd ~/load-test || exit 1

        LOG_FILE=loadtest_${RUN_ID}.log
        SUMMARY_FILE=summary_${RUN_ID}.txt

        START_TIME=\$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')

        echo '=================================' > \$SUMMARY_FILE
        echo 'Machine=$machine' >> \$SUMMARY_FILE
        echo 'FlowID=${FLOW_IDS[$machine]}' >> \$SUMMARY_FILE
        echo 'TargetRPS=${TARGET_RPS[$machine]}' >> \$SUMMARY_FILE
        echo 'Workers=${RPS_WORKERS[$machine]}' >> \$SUMMARY_FILE
        echo 'Duration=${DURATION[$machine]}' >> \$SUMMARY_FILE
        echo 'StartTimeIST='\$START_TIME >> \$SUMMARY_FILE

        export PATH=/usr/local/go/bin:/usr/lib/go-1.22/bin:/root/go/bin:\$PATH

        GO_BIN=\$(which go)

        if [ -z \"\$GO_BIN\" ]; then
            echo 'Go not found' >> \$SUMMARY_FILE
            exit 1
        fi

        echo 'GoBinary='\$GO_BIN >> \$SUMMARY_FILE
        echo 'GoVersion='\"\$(go version)\" >> \$SUMMARY_FILE

        MODE=rps \
        FLOW_ID=${FLOW_IDS[$machine]} \
        TARGET_RPS=${TARGET_RPS[$machine]} \
        RPS_WORKERS=${RPS_WORKERS[$machine]} \
        DURATION=${DURATION[$machine]} \
        RPS_DRAIN_TIMEOUT=30s \
        ./scripts/run-direct.sh > \$LOG_FILE 2>&1

        END_TIME=\$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')

        echo 'EndTimeIST='\$END_TIME >> \$SUMMARY_FILE
        echo '=================================' >> \$SUMMARY_FILE
    "

    mkdir -p "results/$RUN_ID/$machine"

    # Download log
    if sshpass -p "$password" \
        scp \
        -o StrictHostKeyChecking=no \
        root@"${HOSTS[$machine]}":~/load-test/loadtest_${RUN_ID}.log \
        "results/$RUN_ID/$machine/"
    then
        echo "[$machine] ✅ log copied"
    else
        echo "[$machine] ❌ log copy FAILED"
    fi

    # Download summary
    if sshpass -p "$password" \
        scp \
        -o StrictHostKeyChecking=no \
        root@"${HOSTS[$machine]}":~/load-test/summary_${RUN_ID}.txt \
        "results/$RUN_ID/$machine/"
    then
        echo "[$machine] ✅ summary copied"
    else
        echo "[$machine] ❌ summary copy FAILED"
    fi

    if [ -f "results/$RUN_ID/$machine/loadtest_${RUN_ID}.log" ] && \
    [ -f "results/$RUN_ID/$machine/summary_${RUN_ID}.txt" ]
    then
        echo "[$machine] ✅ SUCCESS"
    else
        echo "[$machine] ❌ FAILED"
    fi

) &
done

wait

echo ""
echo "===================================="
echo "ALL TESTS COMPLETED"
echo "Results saved under:"
echo "results/$RUN_ID"
echo "===================================="
