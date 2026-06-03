#!/usr/bin/env bash
set -u

ACTION="${1:-run}"
K8S_SSH_HOST="${K8S_SSH_HOST:-my-machine}"
K8S_RUN_ID="${K8S_RUN_ID:-${RUN_ID:-k8s_metrics_$(date +%Y%m%d_%H%M%S)}}"
K8S_INTERVAL_SECONDS="${K8S_INTERVAL_SECONDS:-5}"
K8S_DURATION_SECONDS="${K8S_DURATION_SECONDS:-0}"
K8S_REMOTE_BASE_DIR="${K8S_REMOTE_BASE_DIR:-k8s-load-test-metrics}"
K8S_LOCAL_DIR="${K8S_LOCAL_DIR:-results/$K8S_RUN_ID/k8s-cluster-metrics}"
DEFAULT_K8S_NAMESPACES="authorization quests loco-store ivory ibiza"
DEFAULT_K8S_DEPLOYMENTS="authorization/authorization-api-deployment quests/quests loco-store/loco-store-api-deployment ivory/admin ivory/dashboard ivory/instream ivory/apis-service ivory/feedv4 ivory/sqs-service ivory/leaderboard ivory/leaderboard-sqs-service ivory/liu-sqs-service ivory/search ivory/stream ivory/stream-playback ibiza/ibiza"
K8S_NAMESPACES="${K8S_NAMESPACES:-$DEFAULT_K8S_NAMESPACES}"
K8S_DEPLOYMENTS="${K8S_DEPLOYMENTS:-$DEFAULT_K8S_DEPLOYMENTS}"
K8S_NODE_LABEL_SELECTOR="${K8S_NODE_LABEL_SELECTOR:-}"
K8S_TIMEZONE="${K8S_TIMEZONE:-Asia/Kolkata}"
K8S_COLLECT_AWS_EC2="${K8S_COLLECT_AWS_EC2:-auto}"
K8S_AWS_REGION="${K8S_AWS_REGION:-}"
K8S_COLLECT_EVENTS="${K8S_COLLECT_EVENTS:-false}"
K8S_NODE_SUMMARY_CONCURRENCY="${K8S_NODE_SUMMARY_CONCURRENCY:-8}"
K8S_STOP_GRACE_SECONDS="${K8S_STOP_GRACE_SECONDS:-90}"

usage() {
    cat <<'EOF'
Usage:
  scripts/k8s-cluster-metrics.sh start
  scripts/k8s-cluster-metrics.sh stop
  scripts/k8s-cluster-metrics.sh collect
  scripts/k8s-cluster-metrics.sh status
  scripts/k8s-cluster-metrics.sh run
  scripts/k8s-cluster-metrics.sh once

Defaults:
  Runs kubectl from ssh host: my-machine
  Saves local files under: results/<RUN_ID>/k8s-cluster-metrics/
  Samples every 5 seconds.

Useful examples:
  RUN_ID=api_coverage_v1_20260602_130010 ./scripts/k8s-cluster-metrics.sh start
  RUN_ID=api_coverage_v1_20260602_130010 ./scripts/k8s-cluster-metrics.sh stop
  RUN_ID=api_coverage_v1_20260602_130010 ./scripts/k8s-cluster-metrics.sh collect

  K8S_DURATION_SECONDS=120 ./scripts/k8s-cluster-metrics.sh run

  K8S_INTERVAL_SECONDS=10 \
  K8S_NAMESPACES="authorization quests loco-store ivory ibiza" \
  K8S_DEPLOYMENTS="authorization/authorization-api-deployment quests/quests loco-store/loco-store-api-deployment ivory/feedv4 ivory/stream ivory/stream-playback ibiza/ibiza" \
  ./scripts/k8s-cluster-metrics.sh run

Environment overrides:
  RUN_ID or K8S_RUN_ID        Run id used in local and remote metric paths.
  K8S_SSH_HOST                SSH alias/host for the Kubernetes dev box.
  K8S_INTERVAL_SECONDS        Collection interval. Recommended: 5s for short load tests, 10s for longer runs.
  K8S_DURATION_SECONDS        For run action. 0 means run until Ctrl-C.
  K8S_REMOTE_BASE_DIR         Remote directory under the SSH user's home. Default: k8s-load-test-metrics.
  K8S_NAMESPACES              Space-separated namespaces to sample for pod/top/HPA logs.
  K8S_DEPLOYMENTS             Space-separated namespace/deployment profiles for additional-pod headroom.
  K8S_NODE_LABEL_SELECTOR     Optional kubectl node label selector.
  K8S_COLLECT_EVENTS          true/false. Default false to avoid very large repeated event logs.
  K8S_NODE_SUMMARY_CONCURRENCY Parallel kubelet summary requests. Default: 8.
  K8S_STOP_GRACE_SECONDS      Seconds to wait for current sample to finish on stop. Default: 90.
  K8S_COLLECT_AWS_EC2         auto, true, or false. Captures EC2 details if aws CLI/auth exists on remote host.
  K8S_AWS_REGION              Optional AWS region for EC2 describe calls.

Output CSVs:
  pod_usage.csv               Per-container CPU/memory from kubelet summary stats.
  pod_network.csv             Per-pod RX/TX counters plus RX/TX bit rates.
  node_usage.csv              Per-node CPU/memory from kubelet summary stats.
  node_network.csv            Per-node RX/TX counters plus RX/TX bit rates.
  node_headroom.csv           Allocatable/requested/usage headroom per Kubernetes node/EC2.
  deployment_profiles.csv     CPU/memory request footprint for selected deployments.
  profile_headroom.csv        Additional pods each node can schedule for selected deployments.

Notes:
  Network data uses kubelet summary counters through kubectl get --raw.
  Scheduling headroom is based on resource requests, not only current usage.
EOF
}

remote_run_dir() {
    printf '%s/%s' "$K8S_REMOTE_BASE_DIR" "$K8S_RUN_ID"
}

remote_script_path() {
    printf '%s/k8s-cluster-metrics.sh' "$(remote_run_dir)"
}

local_pid_file() {
    printf '%s/collector.pid' "$(remote_run_dir)"
}

require_local_tools() {
    if ! command -v ssh >/dev/null 2>&1; then
        echo "ssh not found"
        exit 1
    fi

    if ! command -v scp >/dev/null 2>&1; then
        echo "scp not found"
        exit 1
    fi
}

remote_env_prefix() {
    printf 'K8S_REMOTE_RUN_DIR=%q ' "$(remote_run_dir)"
    printf 'K8S_RUN_ID=%q ' "$K8S_RUN_ID"
    printf 'K8S_INTERVAL_SECONDS=%q ' "$K8S_INTERVAL_SECONDS"
    printf 'K8S_DURATION_SECONDS=%q ' "$K8S_DURATION_SECONDS"
    printf 'K8S_NAMESPACES=%q ' "$K8S_NAMESPACES"
    printf 'K8S_DEPLOYMENTS=%q ' "$K8S_DEPLOYMENTS"
    printf 'K8S_NODE_LABEL_SELECTOR=%q ' "$K8S_NODE_LABEL_SELECTOR"
    printf 'K8S_TIMEZONE=%q ' "$K8S_TIMEZONE"
    printf 'K8S_COLLECT_AWS_EC2=%q ' "$K8S_COLLECT_AWS_EC2"
    printf 'K8S_AWS_REGION=%q ' "$K8S_AWS_REGION"
    printf 'K8S_COLLECT_EVENTS=%q ' "$K8S_COLLECT_EVENTS"
    printf 'K8S_NODE_SUMMARY_CONCURRENCY=%q ' "$K8S_NODE_SUMMARY_CONCURRENCY"
    printf 'K8S_STOP_GRACE_SECONDS=%q ' "$K8S_STOP_GRACE_SECONDS"
}

ssh_remote() {
    ssh "$K8S_SSH_HOST" "$@"
}

copy_self_to_remote() {
    remote_dir="$(remote_run_dir)"
    remote_script="$(remote_script_path)"

    ssh_remote "mkdir -p $(printf '%q' "$remote_dir")" || return 1
    scp "$0" "$K8S_SSH_HOST:$remote_script" >/dev/null || return 1
    ssh_remote "chmod +x $(printf '%q' "$remote_script")" || return 1
}

start_collector() {
    require_local_tools
    copy_self_to_remote || {
        echo "Failed to copy collector to $K8S_SSH_HOST"
        return 1
    }

    remote_script="$(remote_script_path)"
    remote_dir="$(remote_run_dir)"
    env_prefix="$(remote_env_prefix)"

    echo "Starting Kubernetes metrics on $K8S_SSH_HOST"
    echo "K8S_RUN_ID=$K8S_RUN_ID"
    echo "Remote dir: $remote_dir"
    echo "Local dir: $K8S_LOCAL_DIR"

    ssh_remote "
        set -u
        mkdir -p $(printf '%q' "$remote_dir")
        pid_file=$(printf '%q' "$(local_pid_file)")

        command -v kubectl >/dev/null 2>&1 || {
            echo 'kubectl not found on remote host'
            exit 1
        }

        command -v jq >/dev/null 2>&1 || {
            echo 'jq not found on remote host'
            exit 1
        }

        kubectl get pods -A -o name >/dev/null 2>&1 || {
            echo 'kubectl cannot access pods across namespaces; check Kubernetes credentials on the Kubernetes SSH host'
            exit 1
        }

        if [ -f \"\$pid_file\" ] && kill -0 \$(cat \"\$pid_file\") >/dev/null 2>&1; then
            echo 'collector already running with pid '\$(cat \"\$pid_file\")
            exit 0
        fi

        nohup env $env_prefix bash $(printf '%q' "$remote_script") _remote_loop \
            > $(printf '%q' "$remote_dir")/collector.log 2>&1 &
        echo \$! > \"\$pid_file\"
        echo 'started pid '\$(cat \"\$pid_file\")
    "
}

stop_collector() {
    require_local_tools

    remote_dir="$(remote_run_dir)"
    pid_file="$(local_pid_file)"

    echo "Stopping Kubernetes metrics on $K8S_SSH_HOST"
    ssh_remote "
        set -u
        pid_file=$(printf '%q' "$pid_file")
        remote_dir=$(printf '%q' "$remote_dir")

        if [ -f \"\$pid_file\" ]; then
            pid=\$(cat \"\$pid_file\")
            if kill -0 \"\$pid\" >/dev/null 2>&1; then
                kill \"\$pid\"
                waited=0
                while kill -0 \"\$pid\" >/dev/null 2>&1 && [ \"\$waited\" -lt \"$K8S_STOP_GRACE_SECONDS\" ]; do
                    sleep 1
                    waited=\$((waited + 1))
                done
                if kill -0 \"\$pid\" >/dev/null 2>&1; then
                    kill -9 \"\$pid\"
                fi
            fi
            rm -f \"\$pid_file\"
            date '+%Y-%m-%d %H:%M:%S %z' > \"\$remote_dir/stopped_at.txt\"
            echo 'stopped'
        else
            echo 'pid file not found'
        fi
    "
}

collect_metrics() {
    require_local_tools

    mkdir -p "$K8S_LOCAL_DIR"
    remote_dir="$(remote_run_dir)"

    echo "Collecting Kubernetes metrics into $K8S_LOCAL_DIR"
    scp -r "$K8S_SSH_HOST:$remote_dir/"* "$K8S_LOCAL_DIR/" || return 1
}

status_collector() {
    require_local_tools

    pid_file="$(local_pid_file)"
    ssh_remote "
        set -u
        pid_file=$(printf '%q' "$pid_file")
        if [ -f \"\$pid_file\" ] && kill -0 \$(cat \"\$pid_file\") >/dev/null 2>&1; then
            echo 'running pid '\$(cat \"\$pid_file\")
        else
            echo 'not running'
        fi
    "
}

run_collector() {
    cleanup_done=0
    cleanup() {
        status="$1"
        if [ "$cleanup_done" -eq 0 ]; then
            cleanup_done=1
            stop_collector || true
            collect_metrics || true
        fi
        exit "$status"
    }

    trap 'cleanup 130' INT
    trap 'cleanup 143' TERM

    start_collector || exit 1

    if [ "$K8S_DURATION_SECONDS" -gt 0 ]; then
        sleep "$K8S_DURATION_SECONDS"
        cleanup 0
    fi

    echo "Collector running. Press Ctrl-C to stop and collect."
    while true
    do
        sleep 3600
    done
}

once_collector() {
    require_local_tools
    copy_self_to_remote || {
        echo "Failed to copy collector to $K8S_SSH_HOST"
        return 1
    }

    remote_script="$(remote_script_path)"
    env_prefix="$(remote_env_prefix)"

    ssh_remote "env $env_prefix bash $(printf '%q' "$remote_script") _remote_once" || return 1
    collect_metrics
}

csv_init() {
    file="$1"
    header="$2"
    if [ ! -f "$file" ]; then
        printf '%s\n' "$header" > "$file"
    fi
}

remote_require_tools() {
    missing=0

    if ! command -v kubectl >/dev/null 2>&1; then
        echo "kubectl not found on remote host"
        missing=1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo "jq not found on remote host"
        missing=1
    fi

    if [ "$missing" -ne 0 ]; then
        exit 1
    fi
}

namespace_args() {
    for ns in $K8S_NAMESPACES
    do
        printf ' -n %q' "$ns"
    done
}

kubectl_node_selector_args() {
    if [ -n "$K8S_NODE_LABEL_SELECTOR" ]; then
        printf ' -l %q' "$K8S_NODE_LABEL_SELECTOR"
    fi
}

append_section() {
    file="$1"
    title="$2"
    shift 2

    {
        printf '\n===== %s %s =====\n' "$title" "$(TZ="$K8S_TIMEZONE" date '+%Y-%m-%d %H:%M:%S')"
        "$@" 2>&1 || true
    } >> "$file"
}

write_remote_metadata() {
    metadata_file="$K8S_REMOTE_RUN_DIR/metadata.txt"

    {
        printf 'K8S_RUN_ID=%s\n' "$K8S_RUN_ID"
        printf 'StartedAt=%s\n' "$(TZ="$K8S_TIMEZONE" date '+%Y-%m-%d %H:%M:%S %z')"
        printf 'SSHHost=%s\n' "${K8S_SSH_HOST:-remote}"
        printf 'IntervalSeconds=%s\n' "$K8S_INTERVAL_SECONDS"
        printf 'Namespaces=%s\n' "$K8S_NAMESPACES"
        printf 'Deployments=%s\n' "$K8S_DEPLOYMENTS"
        printf 'NodeLabelSelector=%s\n' "$K8S_NODE_LABEL_SELECTOR"
        printf 'CollectEvents=%s\n' "$K8S_COLLECT_EVENTS"
        printf 'NodeSummaryConcurrency=%s\n' "$K8S_NODE_SUMMARY_CONCURRENCY"
        printf 'StopGraceSeconds=%s\n' "$K8S_STOP_GRACE_SECONDS"
        printf 'KubeContext=%s\n' "$(kubectl config current-context 2>/dev/null || true)"
        printf 'KubectlClient=%s\n' "$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null || true)"
        printf 'JqVersion=%s\n' "$(jq --version 2>/dev/null || true)"
    } > "$metadata_file"
}

aws_region_from_nodes() {
    nodes_file="$1"

    jq -r '
      .items[]
      | .spec.providerID // empty
      | capture("aws:///((?<region>[a-z0-9-]+)[a-z])/.*")?
      | .region
    ' "$nodes_file" 2>/dev/null | head -1
}

collect_aws_ec2_snapshot() {
    nodes_file="$1"

    if [ "$K8S_COLLECT_AWS_EC2" = "false" ]; then
        return 0
    fi

    if ! command -v aws >/dev/null 2>&1; then
        return 0
    fi

    instance_ids="$(
        jq -r '
          .items[]
          | .spec.providerID // empty
          | split("/")[-1]
          | select(startswith("i-"))
        ' "$nodes_file" 2>/dev/null | sort -u
    )"

    if [ -z "$instance_ids" ]; then
        return 0
    fi

    region="$K8S_AWS_REGION"
    if [ -z "$region" ]; then
        region="$(aws_region_from_nodes "$nodes_file")"
    fi

    if [ -z "$region" ]; then
        return 0
    fi

    aws ec2 describe-instances \
        --region "$region" \
        --instance-ids $instance_ids \
        > "$K8S_REMOTE_RUN_DIR/ec2_instances.json" 2>"$K8S_REMOTE_RUN_DIR/ec2_instances.err" || true

    instance_types="$(
        jq -r '
          .items[]
          | .metadata.labels["node.kubernetes.io/instance-type"]
            // .metadata.labels["beta.kubernetes.io/instance-type"]
            // empty
        ' "$nodes_file" 2>/dev/null | sort -u
    )"

    if [ -n "$instance_types" ]; then
        aws ec2 describe-instance-types \
            --region "$region" \
            --instance-types $instance_types \
            > "$K8S_REMOTE_RUN_DIR/ec2_instance_types.json" 2>"$K8S_REMOTE_RUN_DIR/ec2_instance_types.err" || true
    fi
}

init_remote_files() {
    mkdir -p "$K8S_REMOTE_RUN_DIR" "$K8S_REMOTE_RUN_DIR/state" "$K8S_REMOTE_RUN_DIR/raw"

    csv_init "$K8S_REMOTE_RUN_DIR/pod_usage.csv" \
        "timestamp,epoch_seconds,namespace,pod,container,node,cpu_mcores,memory_mib"
    csv_init "$K8S_REMOTE_RUN_DIR/pod_network.csv" \
        "timestamp,epoch_seconds,namespace,pod,node,rx_bytes,tx_bytes,rx_bps,tx_bps"
    csv_init "$K8S_REMOTE_RUN_DIR/node_usage.csv" \
        "timestamp,epoch_seconds,node,cpu_mcores,memory_mib"
    csv_init "$K8S_REMOTE_RUN_DIR/node_network.csv" \
        "timestamp,epoch_seconds,node,rx_bytes,tx_bytes,rx_bps,tx_bps"
    csv_init "$K8S_REMOTE_RUN_DIR/node_headroom.csv" \
        "timestamp,epoch_seconds,node,instance_id,instance_type,zone,cpu_allocatable_m,cpu_requested_m,cpu_usage_m,cpu_request_headroom_m,cpu_usage_headroom_m,cpu_requested_pct,cpu_usage_pct,memory_allocatable_mib,memory_requested_mib,memory_usage_mib,memory_request_headroom_mib,memory_usage_headroom_mib,memory_requested_pct,memory_usage_pct,pods_allocatable,pods_running,pods_headroom"
    csv_init "$K8S_REMOTE_RUN_DIR/deployment_profiles.csv" \
        "timestamp,epoch_seconds,namespace,deployment,cpu_request_m,memory_request_mib,cpu_limit_m,memory_limit_mib,replicas,ready_replicas"
    csv_init "$K8S_REMOTE_RUN_DIR/profile_headroom.csv" \
        "timestamp,epoch_seconds,namespace,deployment,node,profile_cpu_request_m,profile_memory_request_mib,additional_pods_by_requests,limiting_resource"
}

sample_text_tables() {
    for ns in $K8S_NAMESPACES
    do
        append_section "$K8S_REMOTE_RUN_DIR/pods.log" "$ns" \
            kubectl get pods -n "$ns" -o wide
        append_section "$K8S_REMOTE_RUN_DIR/pod_metrics_top.log" "$ns" \
            kubectl top pods -n "$ns" --containers
        append_section "$K8S_REMOTE_RUN_DIR/hpa.log" "$ns" \
            kubectl get hpa -n "$ns"
        append_section "$K8S_REMOTE_RUN_DIR/scaledobjects.log" "$ns" \
            kubectl get scaledobject -n "$ns"
        append_section "$K8S_REMOTE_RUN_DIR/deployments.log" "$ns" \
            kubectl get deploy -n "$ns" -o wide
    done

    append_section "$K8S_REMOTE_RUN_DIR/node_metrics_top.log" "nodes" \
        kubectl top nodes
    append_section "$K8S_REMOTE_RUN_DIR/nodes.log" "nodes" \
        kubectl get nodes -o wide
    if [ "$K8S_COLLECT_EVENTS" = "true" ]; then
        append_section "$K8S_REMOTE_RUN_DIR/events.log" "events" \
            kubectl get events -A --field-selector type!=Normal --sort-by=.lastTimestamp
    fi
}

write_network_rates() {
    kind="$1"
    current_file="$2"
    previous_file="$3"
    output_file="$4"
    timestamp="$5"
    epoch="$6"

    if [ "$kind" = "pod" ]; then
        awk -F '\t' -v OFS=',' -v ts="$timestamp" -v epoch="$epoch" '
            NR == FNR {
                key = $1 SUBSEP $2 SUBSEP $3
                prev_rx[key] = $4
                prev_tx[key] = $5
                prev_epoch[key] = $6
                next
            }
            {
                key = $1 SUBSEP $2 SUBSEP $3
                rx_bps = ""
                tx_bps = ""
                if (key in prev_epoch) {
                    dt = epoch - prev_epoch[key]
                    if (dt > 0) {
                        rx_bps = (($4 - prev_rx[key]) * 8) / dt
                        tx_bps = (($5 - prev_tx[key]) * 8) / dt
                    }
                }
                print ts, epoch, $1, $2, $3, $4, $5, rx_bps, tx_bps
            }
        ' "$previous_file" "$current_file" >> "$output_file"
    else
        awk -F '\t' -v OFS=',' -v ts="$timestamp" -v epoch="$epoch" '
            NR == FNR {
                key = $1
                prev_rx[key] = $2
                prev_tx[key] = $3
                prev_epoch[key] = $4
                next
            }
            {
                key = $1
                rx_bps = ""
                tx_bps = ""
                if (key in prev_epoch) {
                    dt = epoch - prev_epoch[key]
                    if (dt > 0) {
                        rx_bps = (($2 - prev_rx[key]) * 8) / dt
                        tx_bps = (($3 - prev_tx[key]) * 8) / dt
                    }
                }
                print ts, epoch, $1, $2, $3, rx_bps, tx_bps
            }
        ' "$previous_file" "$current_file" >> "$output_file"
    fi
}

collect_summary_stats() {
    nodes_file="$1"
    timestamp="$2"
    epoch="$3"
    state_dir="$K8S_REMOTE_RUN_DIR/state"
    current_pod_network="$state_dir/pod_network.current.tsv"
    current_node_network="$state_dir/node_network.current.tsv"
    previous_pod_network="$state_dir/pod_network.previous.tsv"
    previous_node_network="$state_dir/node_network.previous.tsv"

    : > "$current_pod_network"
    : > "$current_node_network"

    if [ ! -f "$previous_pod_network" ]; then
        : > "$previous_pod_network"
    fi

    if [ ! -f "$previous_node_network" ]; then
        : > "$previous_node_network"
    fi

    nodes_list="$state_dir/nodes.current.txt"
    jq -r '.items[].metadata.name' "$nodes_file" > "$nodes_list"

    running_jobs=0
    while IFS= read -r node
    do
        [ -n "$node" ] || continue

        summary_file="$state_dir/summary-$node.json"

        (
            if ! kubectl get --raw "/api/v1/nodes/$node/proxy/stats/summary" > "$summary_file" 2>"$summary_file.err"; then
                printf '%s node=%s failed to collect kubelet summary\n' "$timestamp" "$node" >> "$K8S_REMOTE_RUN_DIR/collector-errors.log"
                exit 1
            fi
        ) &
        running_jobs=$((running_jobs + 1))

        if [ "$running_jobs" -ge "$K8S_NODE_SUMMARY_CONCURRENCY" ]; then
            wait -n || true
            running_jobs=$((running_jobs - 1))
        fi
    done < "$nodes_list"

    while [ "$running_jobs" -gt 0 ]
    do
        wait -n || true
        running_jobs=$((running_jobs - 1))
    done

    while IFS= read -r node
    do
        [ -n "$node" ] || continue

        summary_file="$state_dir/summary-$node.json"
        if [ ! -s "$summary_file" ]; then
            continue
        fi

        jq -r --arg ts "$timestamp" --arg epoch "$epoch" --arg node "$node" '
          def nz: . // 0;
          .node as $n
          | [
              $ts,
              $epoch,
              ($n.nodeName // $node),
              (($n.cpu.usageNanoCores // 0) / 1000000),
              (($n.memory.workingSetBytes // 0) / 1048576)
            ]
          | @csv
        ' "$summary_file" >> "$K8S_REMOTE_RUN_DIR/node_usage.csv"

        jq -r --arg epoch "$epoch" --arg node "$node" '
          .node as $n
          | [
              ($n.nodeName // $node),
              ($n.network.rxBytes // 0),
              ($n.network.txBytes // 0),
              $epoch
            ]
          | @tsv
        ' "$summary_file" >> "$current_node_network"

        jq -r --arg ts "$timestamp" --arg epoch "$epoch" --arg node "$node" --arg namespaces "$K8S_NAMESPACES" '
          def keep_ns($ns):
            ($namespaces | split(" ") | map(select(length > 0)) | index($ns)) != null;
          .pods[]?
          | select(keep_ns(.podRef.namespace))
          | . as $pod
          | $pod.containers[]?
          | [
              $ts,
              $epoch,
              $pod.podRef.namespace,
              $pod.podRef.name,
              .name,
              $node,
              ((.cpu.usageNanoCores // 0) / 1000000),
              ((.memory.workingSetBytes // 0) / 1048576)
            ]
          | @csv
        ' "$summary_file" >> "$K8S_REMOTE_RUN_DIR/pod_usage.csv"

        jq -r --arg epoch "$epoch" --arg node "$node" --arg namespaces "$K8S_NAMESPACES" '
          def keep_ns($ns):
            ($namespaces | split(" ") | map(select(length > 0)) | index($ns)) != null;
          .pods[]?
          | select(keep_ns(.podRef.namespace))
          | [
              .podRef.namespace,
              .podRef.name,
              $node,
              (.network.rxBytes // 0),
              (.network.txBytes // 0),
              $epoch
            ]
          | @tsv
        ' "$summary_file" >> "$current_pod_network"
    done < "$nodes_list"

    write_network_rates "pod" "$current_pod_network" "$previous_pod_network" \
        "$K8S_REMOTE_RUN_DIR/pod_network.csv" "$timestamp" "$epoch"
    write_network_rates "node" "$current_node_network" "$previous_node_network" \
        "$K8S_REMOTE_RUN_DIR/node_network.csv" "$timestamp" "$epoch"

    cp "$current_pod_network" "$previous_pod_network"
    cp "$current_node_network" "$previous_node_network"
}

collect_headroom() {
    nodes_file="$1"
    pods_file="$2"
    deployments_file="$3"
    latest_node_usage_file="$4"
    timestamp="$5"
    epoch="$6"

    jq -r -n \
      --arg ts "$timestamp" \
      --arg epoch "$epoch" \
      --slurpfile nodes "$nodes_file" \
      --slurpfile pods "$pods_file" \
      --slurpfile usage "$latest_node_usage_file" '
      def cpu_m:
        if . == null or . == "" then 0
        elif test("n$") then (sub("n$"; "") | tonumber / 1000000)
        elif test("u$") then (sub("u$"; "") | tonumber / 1000)
        elif test("m$") then (sub("m$"; "") | tonumber)
        else tonumber * 1000
        end;
      def mem_mib:
        if . == null or . == "" then 0
        elif test("Ki$") then (sub("Ki$"; "") | tonumber / 1024)
        elif test("Mi$") then (sub("Mi$"; "") | tonumber)
        elif test("Gi$") then (sub("Gi$"; "") | tonumber * 1024)
        elif test("Ti$") then (sub("Ti$"; "") | tonumber * 1048576)
        elif test("K$") then (sub("K$"; "") | tonumber * 1000 / 1048576)
        elif test("M$") then (sub("M$"; "") | tonumber * 1000000 / 1048576)
        elif test("G$") then (sub("G$"; "") | tonumber * 1000000000 / 1048576)
        else tonumber / 1048576
        end;
      def pct($used; $total):
        if ($total // 0) > 0 then (($used / $total) * 100) else 0 end;
      def pod_cpu_req:
        ([.spec.containers[]? | (.resources.requests.cpu // "0" | cpu_m)] | add // 0) as $app
        | ([.spec.initContainers[]? | (.resources.requests.cpu // "0" | cpu_m)] | max // 0) as $init
        | if $app > $init then $app else $init end;
      def pod_mem_req:
        ([.spec.containers[]? | (.resources.requests.memory // "0" | mem_mib)] | add // 0) as $app
        | ([.spec.initContainers[]? | (.resources.requests.memory // "0" | mem_mib)] | max // 0) as $init
        | if $app > $init then $app else $init end;
      def nonterminal:
        (.status.phase != "Succeeded" and .status.phase != "Failed");

      ($nodes[0].items) as $node_items
      | ($pods[0].items) as $pod_items
      | ($usage[0]) as $usage_map
      | (reduce $pod_items[] as $p ({};
          if ($p | nonterminal) and ($p.spec.nodeName // "") != "" then
            .[$p.spec.nodeName].cpu_m = ((.[$p.spec.nodeName].cpu_m // 0) + ($p | pod_cpu_req))
            | .[$p.spec.nodeName].memory_mib = ((.[$p.spec.nodeName].memory_mib // 0) + ($p | pod_mem_req))
            | .[$p.spec.nodeName].pods = ((.[$p.spec.nodeName].pods // 0) + 1)
          else
            .
          end
        )) as $requests_by_node
      | $node_items[]
      | .metadata.name as $node
      | (.status.allocatable.cpu | cpu_m) as $cpu_alloc
      | (.status.allocatable.memory | mem_mib) as $mem_alloc
      | (.status.allocatable.pods | tonumber) as $pods_alloc
      | ($requests_by_node[$node].cpu_m // 0) as $cpu_req
      | ($requests_by_node[$node].memory_mib // 0) as $mem_req
      | ($requests_by_node[$node].pods // 0) as $pods_running
      | ($usage_map[$node].cpu_m // 0) as $cpu_usage
      | ($usage_map[$node].memory_mib // 0) as $mem_usage
      | [
          $ts,
          $epoch,
          $node,
          (.spec.providerID // "" | split("/")[-1]),
          (.metadata.labels["node.kubernetes.io/instance-type"]
            // .metadata.labels["beta.kubernetes.io/instance-type"]
            // ""),
          (.metadata.labels["topology.kubernetes.io/zone"]
            // .metadata.labels["failure-domain.beta.kubernetes.io/zone"]
            // ""),
          $cpu_alloc,
          $cpu_req,
          $cpu_usage,
          ($cpu_alloc - $cpu_req),
          ($cpu_alloc - $cpu_usage),
          pct($cpu_req; $cpu_alloc),
          pct($cpu_usage; $cpu_alloc),
          $mem_alloc,
          $mem_req,
          $mem_usage,
          ($mem_alloc - $mem_req),
          ($mem_alloc - $mem_usage),
          pct($mem_req; $mem_alloc),
          pct($mem_usage; $mem_alloc),
          $pods_alloc,
          $pods_running,
          ($pods_alloc - $pods_running)
        ]
      | @csv
    ' >> "$K8S_REMOTE_RUN_DIR/node_headroom.csv"

    jq -r -n \
      --arg ts "$timestamp" \
      --arg epoch "$epoch" \
      --arg deployments "$K8S_DEPLOYMENTS" \
      --slurpfile deploys "$deployments_file" '
      def cpu_m:
        if . == null or . == "" then 0
        elif test("n$") then (sub("n$"; "") | tonumber / 1000000)
        elif test("u$") then (sub("u$"; "") | tonumber / 1000)
        elif test("m$") then (sub("m$"; "") | tonumber)
        else tonumber * 1000
        end;
      def mem_mib:
        if . == null or . == "" then 0
        elif test("Ki$") then (sub("Ki$"; "") | tonumber / 1024)
        elif test("Mi$") then (sub("Mi$"; "") | tonumber)
        elif test("Gi$") then (sub("Gi$"; "") | tonumber * 1024)
        elif test("Ti$") then (sub("Ti$"; "") | tonumber * 1048576)
        elif test("K$") then (sub("K$"; "") | tonumber * 1000 / 1048576)
        elif test("M$") then (sub("M$"; "") | tonumber * 1000000 / 1048576)
        elif test("G$") then (sub("G$"; "") | tonumber * 1000000000 / 1048576)
        else tonumber / 1048576
        end;
      def container_cpu_req: .resources.requests.cpu // "0" | cpu_m;
      def container_mem_req: .resources.requests.memory // "0" | mem_mib;
      def container_cpu_lim: .resources.limits.cpu // "0" | cpu_m;
      def container_mem_lim: .resources.limits.memory // "0" | mem_mib;
      ($deployments | split(" ") | map(select(length > 0))) as $profiles
      | $deploys[0].items[]
      | (.metadata.namespace + "/" + .metadata.name) as $key
      | select($profiles | index($key))
      | [
          $ts,
          $epoch,
          .metadata.namespace,
          .metadata.name,
          ([.spec.template.spec.containers[]? | container_cpu_req] | add // 0),
          ([.spec.template.spec.containers[]? | container_mem_req] | add // 0),
          ([.spec.template.spec.containers[]? | container_cpu_lim] | add // 0),
          ([.spec.template.spec.containers[]? | container_mem_lim] | add // 0),
          (.status.replicas // 0),
          (.status.readyReplicas // 0)
        ]
      | @csv
    ' >> "$K8S_REMOTE_RUN_DIR/deployment_profiles.csv"

    tail -n +2 "$K8S_REMOTE_RUN_DIR/deployment_profiles.csv" \
        | awk -F, -v OFS=, -v ts="$timestamp" -v epoch="$epoch" '
            $1 == "\"" ts "\"" || $1 == ts {
                ns_value = $3
                dep_value = $4
                gsub(/^"|"$/, "", ns_value)
                gsub(/^"|"$/, "", dep_value)
                key = ns_value "/" dep_value
                cpu[key] = $5 + 0
                mem[key] = $6 + 0
                ns[key] = ns_value
                dep[key] = dep_value
                keys[key] = 1
            }
            END {
                for (key in keys) {
                    print key, cpu[key], mem[key], ns[key], dep[key]
                }
            }
        ' > "$K8S_REMOTE_RUN_DIR/state/profiles.current.csv"

    tail -n +2 "$K8S_REMOTE_RUN_DIR/node_headroom.csv" \
        | awk -F, -v OFS=, -v ts="$timestamp" '
            $1 == "\"" ts "\"" || $1 == ts {
                node = $3
                gsub(/^"|"$/, "", node)
                cpu_headroom[node] = $10 + 0
                mem_headroom[node] = $17 + 0
                pod_headroom[node] = $23 + 0
                nodes[node] = 1
            }
            END {
                for (node in nodes) {
                    print node, cpu_headroom[node], mem_headroom[node], pod_headroom[node]
                }
            }
        ' > "$K8S_REMOTE_RUN_DIR/state/node_headroom.current.csv"

    awk -F, -v OFS=, -v ts="$timestamp" -v epoch="$epoch" '
        NR == FNR {
            key = $1
            profile_cpu[key] = $2 + 0
            profile_mem[key] = $3 + 0
            profile_ns[key] = $4
            profile_dep[key] = $5
            profile_keys[key] = 1
            next
        }
        {
            node = $1
            node_cpu = $2 + 0
            node_mem = $3 + 0
            node_pods = $4 + 0
            for (key in profile_keys) {
                cpu_fit = profile_cpu[key] > 0 ? int(node_cpu / profile_cpu[key]) : 999999
                mem_fit = profile_mem[key] > 0 ? int(node_mem / profile_mem[key]) : 999999
                pods_fit = int(node_pods)
                fit = cpu_fit
                limiting = "cpu"
                if (mem_fit < fit) {
                    fit = mem_fit
                    limiting = "memory"
                }
                if (pods_fit < fit) {
                    fit = pods_fit
                    limiting = "pods"
                }
                if (fit < 0) {
                    fit = 0
                }
                print ts, epoch, profile_ns[key], profile_dep[key], node, profile_cpu[key], profile_mem[key], fit, limiting
                cluster_key = key
                cluster_fit[cluster_key] += fit
            }
        }
        END {
            for (key in profile_keys) {
                print ts, epoch, profile_ns[key], profile_dep[key], "__cluster_total__", profile_cpu[key], profile_mem[key], cluster_fit[key] + 0, "sum_per_node"
            }
        }
    ' "$K8S_REMOTE_RUN_DIR/state/profiles.current.csv" \
      "$K8S_REMOTE_RUN_DIR/state/node_headroom.current.csv" \
      >> "$K8S_REMOTE_RUN_DIR/profile_headroom.csv"
}

collect_one_sample() {
    timestamp="$(TZ="$K8S_TIMEZONE" date '+%Y-%m-%dT%H:%M:%S%z')"
    epoch="$(date '+%s')"
    sample_dir="$K8S_REMOTE_RUN_DIR/raw/$epoch"
    node_selector_args="$(kubectl_node_selector_args)"

    mkdir -p "$sample_dir"

    if [ -n "$node_selector_args" ]; then
        kubectl get nodes $node_selector_args -o json > "$sample_dir/nodes.json"
    else
        kubectl get nodes -o json > "$sample_dir/nodes.json"
    fi

    kubectl get pods -A -o json > "$sample_dir/pods.json"
    kubectl get deploy -A -o json > "$sample_dir/deployments.json"
    kubectl get hpa -A -o json > "$sample_dir/hpa.json" 2>"$sample_dir/hpa.err" || true
    kubectl get scaledobject -A -o json > "$sample_dir/scaledobjects.json" 2>"$sample_dir/scaledobjects.err" || true

    sample_text_tables
    collect_summary_stats "$sample_dir/nodes.json" "$timestamp" "$epoch"

    latest_usage="$sample_dir/node_usage.latest.json"
    tail -n +2 "$K8S_REMOTE_RUN_DIR/node_usage.csv" \
        | awk -F, -v ts="$timestamp" '
            $1 == "\"" ts "\"" || $1 == ts {
                node = $3
                gsub(/^"|"$/, "", node)
                printf "%s\t%s\t%s\n", node, $4, $5
            }
        ' \
        | jq -Rn '
            reduce inputs as $line ({};
              ($line | split("\t")) as $row
              | .[$row[0]] = {
                  cpu_m: ($row[1] | tonumber),
                  memory_mib: ($row[2] | tonumber)
                }
            )
        ' > "$latest_usage"

    collect_headroom "$sample_dir/nodes.json" "$sample_dir/pods.json" \
        "$sample_dir/deployments.json" "$latest_usage" "$timestamp" "$epoch"

    if [ ! -f "$K8S_REMOTE_RUN_DIR/ec2_snapshot_attempted" ]; then
        collect_aws_ec2_snapshot "$sample_dir/nodes.json"
        touch "$K8S_REMOTE_RUN_DIR/ec2_snapshot_attempted"
    fi
}

remote_loop() {
    K8S_REMOTE_RUN_DIR="${K8S_REMOTE_RUN_DIR:?K8S_REMOTE_RUN_DIR is required}"
    remote_require_tools
    init_remote_files
    write_remote_metadata

    echo "collector started at $(TZ="$K8S_TIMEZONE" date '+%Y-%m-%d %H:%M:%S %z')"

    stop_requested=0
    trap 'stop_requested=1' TERM INT

    while true
    do
        collect_one_sample || true
        if [ "$stop_requested" -eq 1 ]; then
            break
        fi

        sleep "$K8S_INTERVAL_SECONDS" || true
        if [ "$stop_requested" -eq 1 ]; then
            break
        fi
    done

    echo "collector stopped after finishing sample at $(TZ="$K8S_TIMEZONE" date '+%Y-%m-%d %H:%M:%S %z')"
}

remote_once() {
    K8S_REMOTE_RUN_DIR="${K8S_REMOTE_RUN_DIR:?K8S_REMOTE_RUN_DIR is required}"
    remote_require_tools
    init_remote_files
    write_remote_metadata
    collect_one_sample
}

if [ "$ACTION" = "-h" ] || [ "$ACTION" = "--help" ]; then
    usage
    exit 0
fi

case "$ACTION" in
    start)
        start_collector
        ;;
    stop)
        stop_collector
        ;;
    collect)
        collect_metrics
        ;;
    status)
        status_collector
        ;;
    run)
        run_collector
        ;;
    once)
        once_collector
        ;;
    _remote_loop)
        remote_loop
        ;;
    _remote_once)
        remote_once
        ;;
    *)
        usage
        exit 1
        ;;
esac
