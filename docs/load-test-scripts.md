# Load Test Scripts Handoff

This document describes the active load-test scripts in this repo:

```text
/Users/ayush/work/grafana-scrap
```

It focuses only on the shell scripts currently used to run the test, install/check `dstat`, collect instance metrics, collect Kubernetes metrics, generate CSV summaries, and generate local result files.

## Active Scripts

### `scripts/run-test-v3.sh`

Primary entry point. This is the script to run for the load test.

It does all of the following:

1. Builds a `RUN_ID`.
2. Creates a local result directory under `results/<RUN_ID>/`.
3. Runs `scripts/ensure-dstat.sh` against the configured load-generator machines.
4. SSH-checks the configured machines.
5. Starts `dstat` on each machine through `scripts/instance-metrics.sh start`.
6. Starts Kubernetes cluster metrics through `scripts/k8s-cluster-metrics.sh start`, unless `COLLECT_K8S_METRICS=false`.
7. Runs each configured flow sequentially.
8. Runs the same flow in parallel across all configured machines.
9. Copies each machine's remote load-test log and summary into `results/<RUN_ID>/<machine>/`.
10. Stops `dstat` and copies dstat logs into `results/<RUN_ID>/instance-metrics/`.
11. Stops Kubernetes metrics and copies cluster metrics into `results/<RUN_ID>/k8s-cluster-metrics/`.
12. Generates summary CSV files into `results/<RUN_ID>/summary-csv/`, unless `GENERATE_CSV_REPORT=false`.
13. Cleans up both metric collectors on `INT`/`TERM` through a trap.

Current active machines:

```text
brazil-01
brazil-02
brazil-03
```

Current active flows:

| Flow name | Flow ID | Target RPS |
|---|---:|---:|
| `auth_signup_bundle` | 24 | 16002 |
| `feed_v4` | 69 | 2667 |
| `stream_playback_v2` | 10 | 2667 |
| `stream_detail_v2` | 11 | 2667 |
| `store_wallet_stickers_bundle` | 33 | 8001 |
| `categories_listed` | 64 | 2667 |
| `sidenav` | 65 | 2667 |
| `sub_recipe_web_videos_global` | 66 | 2667 |
| `sub_recipe_streamer_profile_v2` | 67 | 1867 |
| `sub_recipe_web_home_global` | 68 | 1333 |
| `profile_me_permissions` | 63 | 2667 |
| `rewards` | 57 | 533 |
| `quests` | 56 | 533 |
| `refresh_token` | 6 | 2667 |
| `username_hai_kya` | 72 | 8001 |
| `stream_me_v2` | 59 | 2667 |
| `stream_playback_v1` | 58 | 2667 |
| `profile_followee` | 61 | 2667 |
| `profile_streams` | 62 | 2667 |
| `bundle_all` | 34 | 2667 |

Flow 7 is intentionally split into focused flows (`69`, `10`, and `11`) because
the bundled flow had 500/503 noise in previous runs. Chat flow 12 is excluded
because it is not a clean exact-RPS flow in `mode=rps`.

The script passes `LOAD_GENERATORS=3` and `LOAD_GENERATOR_INDEX=<0..2>` to the remote runner so the target is split across the configured machines.

Important: the remote load test is executed on each load generator from:

```text
~/load-test
```

The command run remotely is effectively:

```bash
MODE=rps \
RUN_ID=<flow_run_id> \
STREAM_UID=<stream uid> \
STREAMER_UID=<streamer uid> \
FLOW_ID=<flow id> \
TARGET_RPS=<flow target rps> \
RPS_WORKERS=<workers> \
DURATION=<duration> \
LOAD_GENERATORS=<machine count> \
LOAD_GENERATOR_INDEX=<machine index> \
RPS_DRAIN_TIMEOUT=<drain timeout> \
./scripts/run-direct.sh > <log_file> 2>&1
```

### `scripts/ensure-dstat.sh`

Checks whether `dstat` exists on each configured machine. If it is missing, it tries to install it.

Default machines:

```text
brazil-01 brazil-02 brazil-03
```

Install behavior:

- Uses `apt-get install -y dstat` when `apt-get` exists.
- Falls back to `apt-get install -y pcp` if `dstat` package is unavailable.
- Supports `dnf` and `yum` with the same `dstat` then `pcp` fallback.
- Exits non-zero if `dstat` is still unavailable after install.

Useful commands:

```bash
./scripts/ensure-dstat.sh
INSTALL_DSTAT=false ./scripts/ensure-dstat.sh
MACHINES_OVERRIDE="brazil-01 brazil-02" ./scripts/ensure-dstat.sh
```

`INSTALL_DSTAT=false` performs a check-only run and does not install anything.

### `scripts/instance-metrics.sh`

Starts, stops, checks, and collects instance-level metrics using `dstat`.

Default dstat command:

```bash
dstat -tcmn --tcp --top-cpu --top-mem 1
```

What this captures:

- timestamp
- CPU utilization
- memory usage
- network send/receive
- TCP counters
- top CPU process
- top memory process

Actions:

```bash
./scripts/instance-metrics.sh start
./scripts/instance-metrics.sh stop
./scripts/instance-metrics.sh collect
./scripts/instance-metrics.sh status
```

The `run` action exists in the helper, but in this repo the preferred entry point is `scripts/run-test-v3.sh`. Use `run-test-v3.sh` because it coordinates the load test and metrics collection together.

Useful environment overrides:

| Variable | Purpose |
|---|---|
| `METRICS_RUN_ID` | Run ID used in remote and local dstat filenames. |
| `LOCAL_METRICS_DIR` | Local directory where copied dstat logs are saved. |
| `REMOTE_METRICS_DIR` | Remote directory where dstat writes logs. Default: `~/load-test/metrics`. |
| `DSTAT_COMMAND` | Overrides the dstat command. |
| `MACHINES_OVERRIDE` | Space-separated machine list to target. |

Remote files created by `instance-metrics.sh`:

```text
~/load-test/metrics/dstat_<RUN_ID>_<machine>.log
~/load-test/metrics/dstat_<RUN_ID>_<machine>.pid
```

Local copied files:

```text
results/<RUN_ID>/instance-metrics/dstat_<RUN_ID>_<machine>.log
```

## How To Run

From the active project:

```bash
cd /Users/ayush/work/grafana-scrap
./scripts/run-test-v3.sh
```

A short smoke run:

```bash
DEFAULT_DURATION=30s ./scripts/run-test-v3.sh
```

If the local shell has issues, run explicitly with Bash:

```bash
/bin/bash scripts/run-test-v3.sh
```

On machines with Homebrew Bash:

```bash
/opt/homebrew/bin/bash scripts/run-test-v3.sh
```

Common overrides:

```bash
RUN_ID=my_debug_run DEFAULT_DURATION=30s ./scripts/run-test-v3.sh
STREAM_UID=<stream-uid> STREAMER_UID=<streamer-uid> ./scripts/run-test-v3.sh
RPS_DRAIN_TIMEOUT=60s ./scripts/run-test-v3.sh
```

## Result Directory Layout

A run produces this local structure:

```text
results/<RUN_ID>/
  brazil-01/
    loadtest_<RUN_ID>_brazil-01_<flow_name>.log
    summary_<RUN_ID>_brazil-01_<flow_name>.txt
  brazil-02/
    loadtest_<RUN_ID>_brazil-02_<flow_name>.log
    summary_<RUN_ID>_brazil-02_<flow_name>.txt
  brazil-03/
    loadtest_<RUN_ID>_brazil-03_<flow_name>.log
    summary_<RUN_ID>_brazil-03_<flow_name>.txt
  instance-metrics/
    dstat_<RUN_ID>_brazil-01.log
    dstat_<RUN_ID>_brazil-02.log
    dstat_<RUN_ID>_brazil-03.log
  k8s-cluster-metrics/
    node_headroom.csv
    pod_usage.csv
    pod_network.csv
  summary-csv/
    report_sheet.csv
    api_flow_summary.csv
    api_flow_by_machine.csv
    backend_service_health.csv
    service_capacity.csv
    ec2_headroom_summary.csv
    load_generator_summary.csv
```

Example latest-run lookup:

```bash
latest=$(ls -td results/api_coverage_v1_* | head -1)
find "$latest" -maxdepth 3 -type f | sort
```

## CSV Summary Reports

`scripts/generate-load-test-report-csv.py` converts one result directory into
spreadsheet-friendly CSV summaries.

`run-test-v3.sh` runs it automatically after metrics are collected. Disable that
step only when debugging the raw files:

```bash
GENERATE_CSV_REPORT=false ./scripts/run-test-v3.sh
```

Regenerate the report for an existing run:

```bash
./scripts/generate-load-test-report-csv.py results/<RUN_ID>
```

Generated files:

| File | Purpose |
|---|---|
| `report_sheet.csv` | Single sectioned CSV suitable for importing into a sheet. |
| `api_flow_summary.csv` | Flow-level RPS, request totals, failed requests, error rate, and top error endpoints. |
| `api_flow_by_machine.csv` | Same API/flow counters split by load generator. |
| `backend_service_health.csv` | Authorization, Quests, and Loco Store readiness, restarts, HPA state, CPU/memory/network usage, and headroom. |
| `service_capacity.csv` | Current pods, HPA min/max, app-only requests/limits, and total pod requests/limits. |
| `ec2_headroom_summary.csv` | Cluster EC2/node CPU, memory, pod capacity, and request/usage headroom. |
| `load_generator_summary.csv` | Dstat-derived average/peak CPU, memory, and network for each load generator. |
| `report_notes.csv` | Caveats for values that cannot be captured from current logs. |

Latency percentiles are not generated because the current load-test logs do not
contain P90/P95/P99 values. API values are flow-level for bundled flows; the logs
do not contain clean per-endpoint success counters.

## Load Test Logs

Each `loadtest_*.log` is copied from the corresponding remote load generator after the flow finishes.

Typical contents include:

- Go/Fiber startup output.
- Direct runner configuration such as `run_id`, `flow_id`, `total_users`, or `target_rps`.
- Flow execution errors, if any.
- Per-run counters such as:

```text
TargetRPS=<value>
ActualRPS=<value>
Users=<value>
Req/User=<value>
TheoreticalRPS=<value>
TotalRequestsSent=<value>
SuccessfulRequests=<value>
FailedRequests=<value>
```

Use these logs to answer:

- Did the flow start?
- Did an API fail with a status code or application error?
- Did actual RPS reach expected RPS?
- How many requests succeeded or failed on that machine for that flow?

## Summary Files

Each `summary_*.txt` is created remotely before and after the flow, then copied locally.

Typical fields:

```text
Machine=<machine>
FlowName=<flow name>
FlowID=<flow id>
TargetRPS=<target rps>
Workers=<worker count>
Duration=<duration>
LoadGenerators=<machine count>
LoadGeneratorIndex=<index>
StreamUID=<stream uid>
StreamerUID=<streamer uid>
RunID=<flow run id>
StartTimeIST=<flow start time>
GoBinary=<remote go binary>
GoVersion=<remote go version>
ExitCode=<remote command exit code>
EndTimeIST=<flow end time>
```

Use summaries to map each flow's start and end time, especially when comparing against dstat metrics.

## Dstat Metrics Reports

Dstat is currently collected once per machine for the entire test run.

It is not split per flow.

The metrics start before the first flow and stop after the last flow. Therefore each file is one continuous timeline for all flows:

```text
dstat_<RUN_ID>_brazil-01.log
dstat_<RUN_ID>_brazil-02.log
dstat_<RUN_ID>_brazil-03.log
```

To analyze a specific flow:

1. Open that flow's `summary_*.txt`.
2. Read `StartTimeIST` and `EndTimeIST`.
3. Open the matching machine's `dstat_*.log`.
4. Compare rows within that timestamp window.

Example:

```bash
latest=$(ls -td results/api_coverage_v1_* | head -1)
cat "$latest/brazil-01/summary_${latest##*/}_brazil-01_auth_signup_bundle.txt"
less "$latest/instance-metrics/dstat_${latest##*/}_brazil-01.log"
```

## End-To-End Execution Order

`run-test-v3.sh` performs this sequence:

```text
create RUN_ID
create results/<RUN_ID>/
create results/<RUN_ID>/instance-metrics/
create results/<RUN_ID>/k8s-cluster-metrics/
ensure dstat on all machines
ssh preflight all machines
start dstat on all machines
start Kubernetes metrics on my-machine
run flow 24 on all machines in parallel
copy flow 24 logs and summaries
run flow 69 on all machines in parallel
copy flow 69 logs and summaries
run flow 10 on all machines in parallel
copy flow 10 logs and summaries
run flow 11 on all machines in parallel
copy flow 11 logs and summaries
run flow 33 on all machines in parallel
copy flow 33 logs and summaries
run flow 64 on all machines in parallel
copy flow 64 logs and summaries
run flow 65 on all machines in parallel
copy flow 65 logs and summaries
run flow 66 on all machines in parallel
copy flow 66 logs and summaries
run flow 67 on all machines in parallel
copy flow 67 logs and summaries
run flow 68 on all machines in parallel
copy flow 68 logs and summaries
run flow 63 on all machines in parallel
copy flow 63 logs and summaries
run flow 57 on all machines in parallel
copy flow 57 logs and summaries
run flow 56 on all machines in parallel
copy flow 56 logs and summaries
run flow 6 on all machines in parallel
copy flow 6 logs and summaries
run flow 72 on all machines in parallel
copy flow 72 logs and summaries
run flow 59 on all machines in parallel
copy flow 59 logs and summaries
run flow 58 on all machines in parallel
copy flow 58 logs and summaries
run flow 61 on all machines in parallel
copy flow 61 logs and summaries
run flow 62 on all machines in parallel
copy flow 62 logs and summaries
run flow 34 on all machines in parallel
copy flow 34 logs and summaries
stop dstat on all machines
copy dstat logs into instance-metrics/
stop Kubernetes metrics
copy Kubernetes metrics into k8s-cluster-metrics/
generate summary CSV files into summary-csv/
exit with overall load-test status
```

If interrupted with Ctrl-C, the trap still attempts to stop and collect both
metric collectors.

## What To Check After A Run

Check result root:

```bash
latest=$(ls -td results/api_coverage_v1_* | head -1)
echo "$latest"
```

Check all expected files exist:

```bash
find "$latest" -maxdepth 3 -type f | sort
```

Check dstat files:

```bash
ls -lh "$latest/instance-metrics"
```

Check Kubernetes cluster metrics:

```bash
ls -lh "$latest/k8s-cluster-metrics"
```

Check failures in load logs:

```bash
rg -n "ERR|FAILED|FailedRequests|statusCode:|error" "$latest"
```

Check flow timings:

```bash
rg -n "FlowName=|StartTimeIST=|EndTimeIST=|ExitCode=" "$latest"/*/summary_*.txt
```

## Kubernetes Cluster Metrics

`scripts/k8s-cluster-metrics.sh` collects Kubernetes-side metrics from the dev
machine that has cluster access. It defaults to:

```text
ssh my-machine
```

The script runs `kubectl` on that host, writes remote files under:

```text
~/k8s-load-test-metrics/<RUN_ID>/
```

and copies them locally into:

```text
results/<RUN_ID>/k8s-cluster-metrics/
```

`run-test-v3.sh` starts and stops this collector automatically by default.
Disable it only when you cannot reach `ssh my-machine`:

```bash
COLLECT_K8S_METRICS=false ./scripts/run-test-v3.sh
```

Standalone usage around a load test:

```bash
RUN_ID="api_coverage_v1_$(date +%Y%m%d_%H%M%S)"

RUN_ID="$RUN_ID" ./scripts/k8s-cluster-metrics.sh start
RUN_ID="$RUN_ID" ./scripts/run-test-v3.sh
RUN_ID="$RUN_ID" ./scripts/k8s-cluster-metrics.sh stop
RUN_ID="$RUN_ID" ./scripts/k8s-cluster-metrics.sh collect
```

For a standalone timed capture:

```bash
K8S_DURATION_SECONDS=120 ./scripts/k8s-cluster-metrics.sh run
```

Useful overrides:

```bash
K8S_INTERVAL_SECONDS=10 \
K8S_NODE_SUMMARY_CONCURRENCY=8 \
K8S_NAMESPACES="authorization quests loco-store ivory ibiza" \
K8S_DEPLOYMENTS="authorization/authorization-api-deployment quests/quests loco-store/loco-store-api-deployment ivory/feedv4 ivory/stream ivory/stream-playback ibiza/ibiza" \
./scripts/k8s-cluster-metrics.sh run
```

Default namespaces now include:

```text
authorization quests loco-store ivory ibiza
```

Default deployment profiles now include the existing Auth, Quests, Loco Store,
Ibiza, and HPA-targeted Ivory deployments:

```text
authorization/authorization-api-deployment
quests/quests
loco-store/loco-store-api-deployment
ivory/admin
ivory/dashboard
ivory/instream
ivory/apis-service
ivory/feedv4
ivory/sqs-service
ivory/leaderboard
ivory/leaderboard-sqs-service
ivory/liu-sqs-service
ivory/search
ivory/stream
ivory/stream-playback
ibiza/ibiza
```

Primary files:

| File | Purpose |
|---|---|
| `pod_usage.csv` | Per-container CPU and memory from kubelet summary stats. |
| `pod_network.csv` | Per-pod RX/TX counters and RX/TX bit rates. |
| `node_usage.csv` | Per-node CPU and memory from kubelet summary stats. |
| `node_network.csv` | Per-node RX/TX counters and RX/TX bit rates. |
| `node_headroom.csv` | EC2/Kubernetes node allocatable, requested, actual usage, and remaining headroom. |
| `deployment_profiles.csv` | CPU/memory request footprint for selected deployment pods. |
| `profile_headroom.csv` | Estimated additional pods per node and cluster total for selected deployment profiles. |

Pod-level CSVs are scoped by `K8S_NAMESPACES`. Node headroom is cluster-wide
because Kubernetes scheduling capacity must include all non-terminal pods
already placed on each node.

`node_headroom.csv` is the main file for checking whether EC2 nodes are
actually full. Scheduling headroom should be read from request headroom:

```text
cpu_request_headroom_m
memory_request_headroom_mib
pods_headroom
```

Actual usage headroom is also captured:

```text
cpu_usage_headroom_m
memory_usage_headroom_mib
```

Use request headroom for "can Kubernetes place more pods?" and usage headroom
for "are existing EC2 nodes actually busy?"

### Sampling Interval

Use `5s` for short load tests around 30 seconds to 2 minutes. This gives enough
points to see the ramp without hammering the Kubernetes API and every kubelet.

Use `10s` for longer runs. Use `15s` to `30s` for soak tests.

Avoid `1s` or `2s` as the default. CPU and HPA/KEDA signals are not normally
meaningfully updated at that granularity, CloudWatch-backed KEDA metrics in this
cluster use 60-second collection periods, and per-node kubelet summary scraping
across the cluster can become noisy at 1-second intervals.

For clusters with many nodes, `K8S_NODE_SUMMARY_CONCURRENCY=8` keeps per-node
kubelet summary scraping bounded while still completing samples faster than a
serial scrape. On stop, the collector waits for the current sample to complete
before copying files; tune that with `K8S_STOP_GRACE_SECONDS` if a large cluster
needs more time.

## Troubleshooting

### No dstat files were generated

Likely causes:

- The test was run from the wrong repo.
- `scripts/run-test-v3.sh` did not call `scripts/instance-metrics.sh`.
- `dstat` failed to start remotely.
- `scp` failed during collect.

Check:

```bash
pwd
ls scripts/ensure-dstat.sh scripts/instance-metrics.sh scripts/run-test-v3.sh
rg -n "instance-metrics|ensure-dstat|METRICS_DIR" scripts/run-test-v3.sh
```

### `bad array subscript` or `declare -A: invalid option`

This means an older shell or the wrong shell is running a script that uses unsupported Bash features. Current scripts avoid associative arrays, but they still require Bash, not `sh`.

Run explicitly:

```bash
/bin/bash scripts/run-test-v3.sh
```

or:

```bash
/opt/homebrew/bin/bash scripts/run-test-v3.sh
```

### `sshpass not found`

Install `sshpass` locally before running the scripts.

### `dstat missing; installing`

This is expected on first run if `dstat` is absent on remote machines. The script attempts install through the remote package manager.

### Dstat is present but logs are tiny or empty

Check whether the load test exited very early. Also inspect:

```bash
./scripts/instance-metrics.sh status
```

and remote files under:

```text
~/load-test/metrics/
```

## Notes For Future Bot Context

- The active project for these scripts is `grafana-scrap`, not the separate `load-test` repo.
- `scripts/run-test-v3.sh` is the only script a user normally needs to run.
- `scripts/ensure-dstat.sh` only checks/installs dstat; it does not run the load test or collect metrics.
- `scripts/instance-metrics.sh` is a helper used by `run-test-v3.sh`; do not ask the user to run it manually unless debugging metrics collection.
- Dstat output is one file per machine for the whole test run, not one file per flow.
- Flow-to-metrics mapping is done by comparing `summary_*.txt` `StartTimeIST`/`EndTimeIST` with dstat timestamps.
- The scripts contain hard-coded machine addresses and passwords. Avoid printing those values in user-facing summaries unless the user explicitly asks.
