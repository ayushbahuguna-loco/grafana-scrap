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

RUN_ID="run_$(date +%Y%m%d_%H%M%S)"

HOSTS["brazil-01"]="130.94.107.205"
HOSTS["brazil-02"]="38.54.45.95"
HOSTS["brazil-03"]="130.94.106.148"

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

FLOW_IDS["philippines-01"]=42
FLOW_IDS["philippines-02"]=42
FLOW_IDS["philippines-03"]=42

FLOW_IDS["turkey-01"]=42
FLOW_IDS["turkey-02"]=42
FLOW_IDS["turkey-03"]=42

TARGET_RPS["brazil-01"]=1200
TARGET_RPS["brazil-02"]=1200
TARGET_RPS["brazil-03"]=1200

TARGET_RPS["philippines-01"]=1200
TARGET_RPS["philippines-02"]=1200
TARGET_RPS["philippines-03"]=1200

TARGET_RPS["turkey-01"]=1200
TARGET_RPS["turkey-02"]=1200
TARGET_RPS["turkey-03"]=1200

RPS_WORKERS["brazil-01"]=3600
RPS_WORKERS["brazil-02"]=3600
RPS_WORKERS["brazil-03"]=3600

RPS_WORKERS["philippines-01"]=3600
RPS_WORKERS["philippines-02"]=3600
RPS_WORKERS["philippines-03"]=3600

RPS_WORKERS["turkey-01"]=3600
RPS_WORKERS["turkey-02"]=3600
RPS_WORKERS["turkey-03"]=3600

DURATION["brazil-01"]="30s"
DURATION["brazil-02"]="30s"
DURATION["brazil-03"]="30s"

DURATION["philippines-01"]="30s"
DURATION["philippines-02"]="30s"
DURATION["philippines-03"]="30s"

DURATION["turkey-01"]="30s"
DURATION["turkey-02"]="30s"
DURATION["turkey-03"]="30s"

# =========================
# Execute
# =========================

for machine in "${!HOSTS[@]}"
do
    echo "Checking $machine"

    password="$(machine_password "$machine" || true)"
    if [ -z "$password" ]; then
        exit 1
    fi

    sshpass -p "$password" \
    ssh -o StrictHostKeyChecking=no \
    root@"${HOSTS[$machine]}" \
    "hostname" >/dev/null

    if [ $? -eq 0 ]; then
        echo "✅ $machine"
    else
        echo "❌ $machine"
        exit 1
    fi
done

mkdir -p "results/$RUN_ID"

for machine in "${!HOSTS[@]}"
do
(
echo "Starting $machine"

password="$(machine_password "$machine" || true)"
if [ -z "$password" ]; then
    exit 1
fi

sshpass -p "$password" \
ssh -o StrictHostKeyChecking=no \
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

    # Support both Brazil/Turkey and Philippines machines
    export PATH=/usr/local/go/bin:/usr/lib/go-1.22/bin:/root/go/bin:\$PATH

    which go || true
    go version || true

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

sshpass -p "$password" \
scp -o StrictHostKeyChecking=no \
root@"${HOSTS[$machine]}":~/load-test/loadtest.log \
"results/$RUN_ID/$machine/" >/dev/null 2>&1

sshpass -p "$password" \
scp -o StrictHostKeyChecking=no \
root@"${HOSTS[$machine]}":~/load-test/summary.txt \
"results/$RUN_ID/$machine/" >/dev/null 2>&1

echo "Completed $machine"

) &
done

wait

echo ""
echo "===================================="
echo "ALL TESTS COMPLETED"
echo "Results saved under:"
echo "results/$RUN_ID"
echo "===================================="
