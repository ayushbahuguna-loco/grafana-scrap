#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=machine-passwords.sh
. "$SCRIPT_DIR/machine-passwords.sh"

ACTION="${1:-run}"
METRICS_RUN_ID="${METRICS_RUN_ID:-metrics_$(date +%Y%m%d_%H%M%S)}"
REMOTE_DIR="${REMOTE_DIR:-~/load-test}"
REMOTE_METRICS_DIR="${REMOTE_METRICS_DIR:-~/load-test/metrics}"
LOCAL_METRICS_DIR="${LOCAL_METRICS_DIR:-results/$METRICS_RUN_ID/instance-metrics}"
DSTAT_COMMAND="${DSTAT_COMMAND:-dstat -tcmn --tcp --top-cpu --top-mem 1}"

machine_host() {
    case "$1" in
        brazil-01) printf '%s\n' '130.94.106.105' ;;
        brazil-02) printf '%s\n' '130.94.107.80' ;;
        brazil-03) printf '%s\n' '130.94.107.139' ;;
        philippines-01) printf '%s\n' '38.60.246.239' ;;
        philippines-02) printf '%s\n' '38.54.36.76' ;;
        philippines-03) printf '%s\n' '38.54.87.127' ;;
        turkey-01) printf '%s\n' '38.60.208.217' ;;
        turkey-02) printf '%s\n' '130.94.1.175' ;;
        turkey-03) printf '%s\n' '38.54.105.77' ;;
        *) return 1 ;;
    esac
}


DEFAULT_MACHINES=(
  brazil-01
  brazil-02
  brazil-03
)

if [ -n "${MACHINES_OVERRIDE:-}" ]; then
    read -r -a MACHINES <<< "$MACHINES_OVERRIDE"
else
    MACHINES=("${DEFAULT_MACHINES[@]}")
fi

usage() {
    cat <<'EOF'
Usage:
  scripts/instance-metrics.sh run
  scripts/instance-metrics.sh start
  scripts/instance-metrics.sh stop
  scripts/instance-metrics.sh collect
  scripts/instance-metrics.sh status

Default dstat command:
  dstat -tcmn --tcp --top-cpu --top-mem 1

Examples:
  ./scripts/instance-metrics.sh run

  METRICS_RUN_ID=api_coverage_metrics ./scripts/instance-metrics.sh start
  bash scripts/load.sh
  METRICS_RUN_ID=api_coverage_metrics ./scripts/instance-metrics.sh stop
  METRICS_RUN_ID=api_coverage_metrics ./scripts/instance-metrics.sh collect

  watch -n 5 './scripts/instance-metrics.sh status'

Overrides:
  MACHINES_OVERRIDE="brazil-01 brazil-02" ./scripts/instance-metrics.sh run
  DSTAT_COMMAND="dstat -tcmn --tcp --top-cpu --top-mem 1" ./scripts/instance-metrics.sh start
EOF
}

require_local_tools() {
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "sshpass not found"
        exit 1
    fi
}

remote_log_file() {
    machine="$1"
    printf '%s/dstat_%s_%s.log' "$REMOTE_METRICS_DIR" "$METRICS_RUN_ID" "$machine"
}

remote_pid_file() {
    machine="$1"
    printf '%s/dstat_%s_%s.pid' "$REMOTE_METRICS_DIR" "$METRICS_RUN_ID" "$machine"
}

ssh_machine() {
    machine="$1"
    shift
    host="$(machine_host "$machine" || true)"
    password="$(machine_password "$machine" || true)"

    if [ -z "$host" ] || [ -z "$password" ]; then
        echo "[$machine] unknown machine"
        return 1
    fi

    sshpass -p "$password" \
        ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        root@"$host" \
        "$@"
}

scp_from_machine() {
    machine="$1"
    remote_file="$2"
    local_dir="$3"
    host="$(machine_host "$machine" || true)"
    password="$(machine_password "$machine" || true)"

    if [ -z "$host" ] || [ -z "$password" ]; then
        echo "[$machine] unknown machine"
        return 1
    fi

    sshpass -p "$password" \
        scp \
        -o StrictHostKeyChecking=no \
        root@"$host":"$remote_file" \
        "$local_dir/"
}

start_metrics() {
    echo "Starting instance metrics: METRICS_RUN_ID=$METRICS_RUN_ID"
    echo "DSTAT_COMMAND=$DSTAT_COMMAND"

    pids=()
    for machine in "${MACHINES[@]}"
    do
        log_file="$(remote_log_file "$machine")"
        pid_file="$(remote_pid_file "$machine")"

        echo "[$machine] starting dstat"
        ssh_machine "$machine" "
            mkdir -p $REMOTE_METRICS_DIR
            if ! command -v dstat >/dev/null 2>&1; then
                echo 'dstat not found' > $log_file
                exit 1
            fi
            if [ -f $pid_file ] && kill -0 \$(cat $pid_file) >/dev/null 2>&1; then
                echo 'dstat already running with pid '\$(cat $pid_file)
                exit 0
            fi
            BUFFER_PREFIX=''
            if command -v stdbuf >/dev/null 2>&1; then
                BUFFER_PREFIX='stdbuf -oL -eL'
            fi
            nohup sh -c \"\$BUFFER_PREFIX $DSTAT_COMMAND\" > $log_file 2>&1 &
            echo \$! > $pid_file
            echo 'started pid '\$(cat $pid_file)
        " &
        pids+=("$!")
    done

    status=0
    for pid in "${pids[@]}"
    do
        if ! wait "$pid"; then
            status=1
        fi
    done

    return "$status"
}

stop_metrics() {
    echo "Stopping instance metrics: METRICS_RUN_ID=$METRICS_RUN_ID"

    pids=()
    for machine in "${MACHINES[@]}"
    do
        pid_file="$(remote_pid_file "$machine")"

        echo "[$machine] stopping dstat"
        ssh_machine "$machine" "
            if [ -f $pid_file ]; then
                PID=\$(cat $pid_file)
                if kill -0 \$PID >/dev/null 2>&1; then
                    kill \$PID
                    sleep 1
                    if kill -0 \$PID >/dev/null 2>&1; then
                        kill -9 \$PID
                    fi
                fi
                rm -f $pid_file
                echo 'stopped'
            else
                echo 'pid file not found'
            fi
        " &
        pids+=("$!")
    done

    status=0
    for pid in "${pids[@]}"
    do
        if ! wait "$pid"; then
            status=1
        fi
    done

    return "$status"
}

collect_metrics() {
    echo "Collecting instance metrics into $LOCAL_METRICS_DIR"
    mkdir -p "$LOCAL_METRICS_DIR"

    status=0
    for machine in "${MACHINES[@]}"
    do
        log_file="$(remote_log_file "$machine")"

        if scp_from_machine "$machine" "$log_file" "$LOCAL_METRICS_DIR"; then
            echo "[$machine] copied"
        else
            echo "[$machine] copy failed"
            status=1
        fi
    done

    return "$status"
}

status_metrics() {
    echo "Instance metrics status: METRICS_RUN_ID=$METRICS_RUN_ID"

    for machine in "${MACHINES[@]}"
    do
        pid_file="$(remote_pid_file "$machine")"
        ssh_machine "$machine" "
            if [ -f $pid_file ] && kill -0 \$(cat $pid_file) >/dev/null 2>&1; then
                echo '$machine running pid '\$(cat $pid_file)
            else
                echo '$machine not running'
            fi
        "
    done
}

run_with_metrics() {
    cleanup_done=0
    cleanup() {
        status="$1"
        if [ "$cleanup_done" -eq 0 ]; then
            cleanup_done=1
            stop_metrics
            collect_metrics
        fi
        exit "$status"
    }

    trap 'cleanup 130' INT
    trap 'cleanup 143' TERM

    start_metrics

    bash scripts/load.sh
    status=$?

    cleanup "$status"
}

if [ "$ACTION" = "-h" ] || [ "$ACTION" = "--help" ]; then
    usage
    exit 0
fi

require_local_tools

case "$ACTION" in
    run)
        run_with_metrics
        ;;
    start)
        start_metrics
        ;;
    stop)
        stop_metrics
        ;;
    collect)
        collect_metrics
        ;;
    status)
        status_metrics
        ;;
    *)
        usage
        exit 1
        ;;
esac
