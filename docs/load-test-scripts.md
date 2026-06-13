# Regional Load Test v6 Runbook

Use this doc for the current regional load-test script only:

```bash
./scripts/run-test-v6.sh
```

Run every command from this repo:

```bash
cd /Users/ayush/work/grafana-scrap
```

The main 188.5k-user test is:

```bash
./scripts/run-test-v6.sh --no-k8s --test 2
```

That targets Brazil, Turkey, Philippines, Saudi, and Egypt:

```text
79.5k + 55k + 18k + 22.5k + 13.5k = 188.5k users
```

For the most stable run, skip Kubernetes metrics and dstat:

```bash
./scripts/run-test-v6.sh --no-k8s --no-dstat --test 2
```

## Command Catalog

| Command | What it does |
|---|---|
| `./scripts/run-test-v6.sh --no-k8s --test 2` | Runs the current 188.5k-user regional test across Brazil, Turkey, Philippines, Saudi, and Egypt. Keeps dstat on, skips Kubernetes metrics. |
| `./scripts/run-test-v6.sh --no-k8s --no-dstat --test 2` | Runs the same 188.5k-user test without Kubernetes metrics or dstat. Use this when metrics are failing or you only need load-test logs and CSVs. |
| `./scripts/run-test-v6.sh --dry-run --no-k8s --no-dstat --test 2` | Prints selected machines, flows, durations, and calculated RPS. Does not SSH or run load. Use before a real test. |
| `./scripts/run-test-v6.sh --no-k8s --no-dstat --test 2 --duration 30s` | Short smoke test. Overrides every flow duration to 30 seconds, which increases calculated RPS. Use only for validation, not final numbers. |
| `./scripts/run-test-v6.sh --no-k8s --test 1` | Runs Brazil + Turkey only. |
| `./scripts/run-test-v6.sh --no-k8s --preset middle-east` | Runs Iraq, Jordan+Lebanon via Bahrain, Qatar, and Kuwait. |
| `./scripts/run-test-v6.sh --k8s --test 2` | Runs the 188.5k-user test and also starts Kubernetes metrics. Use only when `ssh my-machine` and `kubectl` are healthy. |
| `./scripts/run-test-v6.sh --no-k8s --no-csv --test 2` | Runs load but skips final CSV generation. Use only when debugging raw logs. |
| `RUN_ID=my_debug_run ./scripts/run-test-v6.sh --no-k8s --test 2` | Uses a fixed run id instead of generating one. Useful for controlled reruns. |
| `STREAM_UID=<stream_uid> STREAMER_UID=<streamer_uid> ./scripts/run-test-v6.sh --no-k8s --test 2` | Overrides the stream and streamer used by flows that need them. |
| `RPS_DRAIN_TIMEOUT=60s ./scripts/run-test-v6.sh --no-k8s --test 2` | Gives the remote runner more drain time after each flow. |

## Region Commands

The script calculates RPS from the region attached to each machine. Use
`--machines` when you want one region or a custom region mix.

| Region set | Command |
|---|---|
| Full 188.5k current test | `./scripts/run-test-v6.sh --no-k8s --test 2` |
| Brazil + Turkey | `./scripts/run-test-v6.sh --no-k8s --test 1` |
| Middle East preset | `./scripts/run-test-v6.sh --no-k8s --preset middle-east` |
| Brazil only | `./scripts/run-test-v6.sh --no-k8s --machines "load-test-brazil-lightnode-01 load-test-brazil-lightnode-02 load-test-brazil-lightnode-03 load-test-brazil-lightnode-04"` |
| Turkey only | `./scripts/run-test-v6.sh --no-k8s --machines "load-test-turkey-01 load-test-turkey-02 load-test-turkey-03"` |
| Philippines only | `./scripts/run-test-v6.sh --no-k8s --machines "load-test-linux-philippines-01 load-test-linux-philippines-02 load-test-linux-philippines-03"` |
| Saudi only | `./scripts/run-test-v6.sh --no-k8s --machines "load-test-saudi-01 load-test-saudi-02 load-test-saudi-03"` |
| Egypt only | `./scripts/run-test-v6.sh --no-k8s --machines "load-test-egypt-01 load-test-egypt-02"` |
| Iraq only | `./scripts/run-test-v6.sh --no-k8s --machines "load-test-iraq-01"` |
| Jordan+Lebanon only | `./scripts/run-test-v6.sh --no-k8s --machines "load-test-bahrain-01"` |
| Qatar only | `./scripts/run-test-v6.sh --no-k8s --machines "load-test-qatar-01"` |
| Kuwait only | `./scripts/run-test-v6.sh --no-k8s --machines "load-test-kuwait-01"` |

Known region user targets:

| Region | Users | Machines |
|---|---:|---|
| Brazil | 79.5k | `load-test-brazil-lightnode-01..04` |
| Turkey | 55k | `load-test-turkey-01..03` |
| Philippines | 18k | `load-test-linux-philippines-01..03` |
| Saudi | 22.5k | `load-test-saudi-01..03` |
| Egypt | 13.5k | `load-test-egypt-01..02` |
| Iraq | 7.2k | `load-test-iraq-01` |
| Jordan+Lebanon | 6.3k | `load-test-bahrain-01` |
| Qatar | 2.25k | `load-test-qatar-01` |
| Kuwait | 3.6k | `load-test-kuwait-01` |

## Default Flows

Each default flow runs in this order:

```text
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
```

API counts used for RPS:

| Flow ID | Name | API calls |
|---:|---|---:|
| 41 | leaderboard | 5 |
| 76 | auth | 7 |
| 77 | feed | 6 |
| 78 | stream | 6 |
| 79 | chat | 3 |
| 80 | quest_rewards | 2 |
| 82 | search | 2 |

Default durations:

| Phase | Duration |
|---|---:|
| `pre_soak` | `180s` |
| `burst` | `60s` |
| `soak` | `600s` |

## RPS Tuning

The script does not take a direct `--target-rps` flag. It calculates RPS from
users, API count, duration, and selected same-region machine count.

Formula:

```text
regional target RPS = users_in_thousands * 1000 * API calls in flow / duration_seconds
machine-local target RPS = regional target RPS / selected machine count for that region
```

Rules:

- Shorter duration means higher RPS.
- Longer duration means lower RPS.
- Do not manually divide RPS by machine count. The script does same-region split.
- `--duration` overrides all flow durations.
- `--flow-id` + `--api-count` runs one custom flow instead of the default list.

Print the calculated RPS before a test:

```bash
./scripts/run-test-v6.sh --dry-run --no-k8s --no-dstat --test 2
```

Increase RPS for all flows by shortening duration:

```bash
./scripts/run-test-v6.sh --no-k8s --no-dstat --test 2 --duration 60s
```

Decrease RPS for all flows by lengthening duration:

```bash
./scripts/run-test-v6.sh --no-k8s --no-dstat --test 2 --duration 900s
```

Run one custom flow only:

```bash
./scripts/run-test-v6.sh --no-k8s --no-dstat --test 2 \
  --flow-id 82 \
  --api-count 2 \
  --flow-name search_debug \
  --flow-duration 180s
```

## Failure Recovery

If the test fails or exits early, retry the same command first. Most failures
are transient SSH, SCP, or remote load-generator issues.

```bash
./scripts/run-test-v6.sh --no-k8s --no-dstat --test 2
```

If a few flows already completed, resume using the same `RUN_ID` and the next
flow name:

```bash
./scripts/run-test-v6.sh --no-k8s --no-dstat --test 2 \
  --run-id <RUN_ID> \
  --start-flow <flow_name>
```

Example:

```bash
./scripts/run-test-v6.sh --no-k8s --no-dstat --test 2 \
  --run-id regional_api_coverage_v6_20260612_163047 \
  --start-flow leaderboard_pre_soak
```

If Kubernetes metrics fail, rerun with `--no-k8s`:

```bash
./scripts/run-test-v6.sh --no-k8s --test 2
```

If dstat fails or installation is noisy, rerun with `--no-dstat`:

```bash
./scripts/run-test-v6.sh --no-k8s --no-dstat --test 2
```

If the local shell has issues, run with Bash directly:

```bash
/bin/bash scripts/run-test-v6.sh --no-k8s --test 2
```

## Sync Failed Or Missing Files

If the run completed remotely but local copy failed, sync logs and summaries
again with `scripts/sync-load-test-run-files.sh`.

Always pass the v6 machine list. The sync helper's built-in default machine list
is legacy Brazil-only.

Sync all default flows for the 188.5k test:

```bash
scripts/sync-load-test-run-files.sh <RUN_ID> \
  --machines "load-test-brazil-lightnode-01 load-test-brazil-lightnode-02 load-test-brazil-lightnode-03 load-test-brazil-lightnode-04 load-test-turkey-01 load-test-turkey-02 load-test-turkey-03 load-test-linux-philippines-01 load-test-linux-philippines-02 load-test-linux-philippines-03 load-test-saudi-01 load-test-saudi-02 load-test-saudi-03 load-test-egypt-01 load-test-egypt-02"
```

Sync only a few flows:

```bash
scripts/sync-load-test-run-files.sh <RUN_ID> \
  --machines "load-test-brazil-lightnode-01 load-test-brazil-lightnode-02" \
  --flows "feed_soak leaderboard_soak search_soak"
```

Force recopies even if local files already exist:

```bash
scripts/sync-load-test-run-files.sh <RUN_ID> \
  --force \
  --machines "load-test-brazil-lightnode-01 load-test-brazil-lightnode-02"
```

Skip report regeneration while syncing:

```bash
scripts/sync-load-test-run-files.sh <RUN_ID> \
  --no-report \
  --machines "load-test-brazil-lightnode-01 load-test-brazil-lightnode-02"
```

## Result Locations

Every run prints a `RUN_ID` at the top. Results are saved under:

```text
results/<RUN_ID>/
```

Find the latest v6 run:

```bash
latest=$(ls -td results/regional_api_coverage_v6_* | head -1)
echo "$latest"
```

Load-test logs and per-flow summaries:

```text
results/<RUN_ID>/<machine>/loadtest_<RUN_ID>_<machine>_<flow_name>.log
results/<RUN_ID>/<machine>/summary_<RUN_ID>_<machine>_<flow_name>.txt
```

Example:

```bash
machine=load-test-brazil-lightnode-01
less "$latest/$machine/loadtest_${latest##*/}_${machine}_feed_soak.log"
cat "$latest/$machine/summary_${latest##*/}_${machine}_feed_soak.txt"
```

CSV reports:

```text
results/<RUN_ID>/summary-csv/
```

Important CSV files:

| File | What it answers |
|---|---|
| `report_sheet.csv` | Single combined report for spreadsheet import. |
| `api_flow_summary.csv` | Flow-level RPS, request totals, failures, error rate, and top errors. |
| `api_flow_by_machine.csv` | Same counters split by machine. |
| `load_generator_summary.csv` | Dstat-derived CPU, memory, and network by load generator. |
| `backend_service_health.csv` | Kubernetes service health, restarts, HPA, and resource usage when k8s metrics exist. |
| `service_capacity.csv` | Pod request/limit capacity when k8s metrics exist. |
| `ec2_headroom_summary.csv` | EC2/node request and usage headroom when k8s metrics exist. |

Regenerate CSV reports for an existing run:

```bash
./scripts/generate-load-test-report-csv.py results/<RUN_ID>
```

## Dstat Reports

Dstat is enabled by default unless `--no-dstat` is used.

Raw dstat files:

```text
results/<RUN_ID>/instance-metrics/dstat_<RUN_ID>_<machine>.log
```

CSV summary derived from dstat:

```text
results/<RUN_ID>/summary-csv/load_generator_summary.csv
```

Example:

```bash
ls -lh "$latest/instance-metrics"
cat "$latest/summary-csv/load_generator_summary.csv"
```

Dstat is one continuous file per machine for the whole run. It is not split per
flow. To inspect one flow:

1. Open that flow's `summary_*.txt`.
2. Read `StartTimeIST` and `EndTimeIST`.
3. Compare that time window in the matching `dstat_*.log`.

## Kubernetes Reports

Kubernetes metrics are disabled by default in v6. Use `--k8s` only when
`ssh my-machine` and `kubectl` are working.

Enable Kubernetes metrics:

```bash
./scripts/run-test-v6.sh --k8s --test 2
```

Skip Kubernetes metrics:

```bash
./scripts/run-test-v6.sh --no-k8s --test 2
```

Raw Kubernetes metrics:

```text
results/<RUN_ID>/k8s-cluster-metrics/
```

Important Kubernetes files:

| File | What it answers |
|---|---|
| `node_headroom.csv` | Node CPU, memory, pod request headroom, and usage headroom. |
| `pod_usage.csv` | Per-container CPU and memory usage. |
| `pod_network.csv` | Per-pod network RX/TX counters and bit rates. |
| `deployment_profiles.csv` | Request footprint for selected deployments. |
| `profile_headroom.csv` | Estimated additional pods by deployment profile. |

CSV summaries derived from Kubernetes metrics:

```text
results/<RUN_ID>/summary-csv/backend_service_health.csv
results/<RUN_ID>/summary-csv/service_capacity.csv
results/<RUN_ID>/summary-csv/ec2_headroom_summary.csv
```

If Kubernetes metrics fail, rerun with `--no-k8s`. The load-test logs and API
CSV reports can still be used.

## What To Check After A Run

Find the latest run:

```bash
latest=$(ls -td results/regional_api_coverage_v6_* | head -1)
echo "$latest"
```

List files:

```bash
find "$latest" -maxdepth 3 -type f | sort
```

Check failures:

```bash
rg -n "ERR|FAILED|FailedRequests|statusCode:|error" "$latest"
```

Check flow timing and exit codes:

```bash
rg -n "FlowName=|StartTimeIST=|EndTimeIST=|ExitCode=" "$latest"/*/summary_*.txt
```

Open the main report:

```bash
cat "$latest/summary-csv/report_sheet.csv"
```

## Notes For TGPT Or Future Operators

- Current script: `scripts/run-test-v6.sh`.
- Current 188.5k command: `./scripts/run-test-v6.sh --no-k8s --test 2`.
- Most stable no-metrics command: `./scripts/run-test-v6.sh --no-k8s --no-dstat --test 2`.
- Use `--dry-run` to answer "what machines, flows, and RPS will this run use?"
- Use `--machines` to run one region or any custom machine mix.
- Use `--duration` to tune RPS for all flows.
- Use `--flow-id` and `--api-count` to run one custom flow.
- Use `--start-flow` with the same `--run-id` to resume a partial run.
- Use `scripts/sync-load-test-run-files.sh` to recover missing local logs and summaries.
- Dstat raw reports are under `results/<RUN_ID>/instance-metrics/`.
- Kubernetes raw reports are under `results/<RUN_ID>/k8s-cluster-metrics/`.
- CSV reports are under `results/<RUN_ID>/summary-csv/`.
- The scripts contain machine connection details. Do not paste secrets into public places.
