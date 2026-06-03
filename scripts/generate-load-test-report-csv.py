#!/usr/bin/env python3
"""Generate CSV summaries for one load-test result directory."""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


TARGET_DEPLOYMENTS = {
    ("authorization", "authorization-api-deployment"): "Authorization",
    ("quests", "quests"): "Quests",
    ("loco-store", "loco-store-api-deployment"): "Loco Store",
    ("ivory", "admin"): "Ivory Admin",
    ("ivory", "dashboard"): "Ivory Dashboard",
    ("ivory", "instream"): "Ivory Instream",
    ("ivory", "apis-service"): "Ivory APIs",
    ("ivory", "feedv4"): "Ivory Feed V4",
    ("ivory", "sqs-service"): "Ivory SQS",
    ("ivory", "leaderboard"): "Ivory Leaderboard",
    ("ivory", "leaderboard-sqs-service"): "Ivory Leaderboard SQS",
    ("ivory", "liu-sqs-service"): "Ivory LIU SQS",
    ("ivory", "search"): "Ivory Search",
    ("ivory", "stream"): "Ivory Stream",
    ("ivory", "stream-playback"): "Ivory Stream Playback",
    ("ibiza", "ibiza"): "Ibiza",
}

SIDECAR_NAMES = {"fluentbit", "fluentbit-v2", "fluent-bit", "fluent-bit-v2", "redis"}
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
SUMMARY_RE = re.compile(r"^([A-Za-z0-9_]+)=(.*)$")
METRIC_RE = re.compile(
    r"TargetRPS=(?P<target>[0-9.]+)\s+"
    r"ActualRPS=(?P<actual>[0-9.]+)\s+"
    r"Users=(?P<users>[0-9.]+)\s+"
    r"Req/User=(?P<req_user>[0-9.]+)\s+"
    r"TheoreticalRPS=(?P<theoretical>[0-9.]+)\s+"
    r"TotalRequestsSent=(?P<sent>[0-9.]+)\s+"
    r"SuccessfulRequests=(?P<success>[0-9.]+)\s+"
    r"FailedRequests=(?P<failed>[0-9.]+)"
)
URL_RE = re.compile(r'\b(Get|Post|Put|Patch|Delete)\s+"([^"]+)"')


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", help="Path to results/<run_id>")
    parser.add_argument(
        "--output-dir",
        help="Output directory. Defaults to <run_dir>/summary-csv",
    )
    return parser.parse_args()


def csv_float(value: Any, digits: int = 2) -> str:
    try:
        num = float(value)
    except (TypeError, ValueError):
        return ""
    if math.isnan(num) or math.isinf(num):
        return ""
    return f"{num:.{digits}f}"


def csv_int(value: Any) -> str:
    try:
        return str(int(round(float(value))))
    except (TypeError, ValueError):
        return ""


def read_csv(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: list[dict[str, Any]], fieldnames: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open() as handle:
        try:
            return json.load(handle)
        except json.JSONDecodeError as exc:
            print(f"Warning: skipping invalid JSON file {path}: {exc}", file=sys.stderr)
            return {}


def latest_raw_dir(k8s_dir: Path) -> Path | None:
    raw_dir = k8s_dir / "raw"
    if not raw_dir.exists():
        return None
    candidates = [p for p in raw_dir.iterdir() if p.is_dir() and p.name.isdigit()]
    if not candidates:
        return None
    return max(candidates, key=lambda p: int(p.name))


def latest_by_key(rows: list[dict[str, str]], keys: tuple[str, ...]) -> dict[tuple[str, ...], dict[str, str]]:
    latest: dict[tuple[str, ...], dict[str, str]] = {}
    for row in rows:
        key = tuple(row.get(item, "") for item in keys)
        current = latest.get(key)
        if current is None or float(row.get("epoch_seconds") or 0) >= float(current.get("epoch_seconds") or 0):
            latest[key] = row
    return latest


def parse_cpu_to_m(value: Any) -> float:
    if value is None:
        return 0.0
    text = str(value)
    if text.endswith("m"):
        return float(text[:-1])
    if text.endswith("n"):
        return float(text[:-1]) / 1_000_000
    if text.endswith("u"):
        return float(text[:-1]) / 1000
    return float(text) * 1000


def parse_mem_to_mib(value: Any) -> float:
    if value is None:
        return 0.0
    text = str(value)
    units = {
        "Ki": 1 / 1024,
        "Mi": 1,
        "Gi": 1024,
        "Ti": 1024 * 1024,
        "K": 1 / 1024,
        "M": 1,
        "G": 1024,
        "T": 1024 * 1024,
    }
    for suffix, factor in units.items():
        if text.endswith(suffix):
            return float(text[: -len(suffix)]) * factor
    return float(text) / 1024 / 1024


def parse_size_to_bytes(value: str) -> float:
    text = value.strip()
    if not text:
        return 0.0
    units = {"B": 1, "k": 1024, "K": 1024, "M": 1024**2, "G": 1024**3}
    suffix = text[-1]
    if suffix in units:
        return float(text[:-1]) * units[suffix]
    return float(text)


def load_summary(summary_file: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    for line in summary_file.read_text(errors="replace").splitlines():
        match = SUMMARY_RE.match(line.strip())
        if match:
            data[match.group(1)] = match.group(2)
    return data


def classify_error(line: str) -> str:
    normalized = ANSI_RE.sub("", line).lower()
    if "timeout awaiting response headers" in normalized:
        return "timeout awaiting response headers"
    if "connection reset by peer" in normalized:
        return "connection reset by peer"
    if "5xx" in normalized:
        return "5xx"
    if "error while executing step" in normalized:
        return "step execution error"
    if "err" in normalized:
        return "application error log"
    return "other error"


def extract_endpoint(line: str) -> str:
    clean = ANSI_RE.sub("", line)
    match = URL_RE.search(clean)
    if not match:
        return ""
    method = match.group(1).upper()
    url = match.group(2)
    path = re.sub(r"^https?://[^/]+", "", url)
    return f"{method} {path}"


def parse_load_log(log_file: Path) -> dict[str, Any]:
    snapshots: list[dict[str, float]] = []
    error_types: Counter[str] = Counter()
    endpoint_errors: Counter[str] = Counter()
    for raw_line in log_file.read_text(errors="replace").splitlines():
        metric_match = METRIC_RE.search(raw_line)
        if metric_match:
            snapshots.append({key: float(value) for key, value in metric_match.groupdict().items()})
            continue
        lower_line = raw_line.lower()
        if "error while executing step" in lower_line or "\x1b[31merr\x1b" in lower_line or "connection reset" in lower_line:
            error_types[classify_error(raw_line)] += 1
            endpoint = extract_endpoint(raw_line)
            if endpoint:
                endpoint_errors[endpoint] += 1

    last = snapshots[-1] if snapshots else {}
    actual_values = [row["actual"] for row in snapshots if "actual" in row]
    return {
        "snapshot_count": len(snapshots),
        "avg_actual_rps": statistics.fmean(actual_values) if actual_values else 0,
        "peak_actual_rps": max(actual_values) if actual_values else 0,
        "last_actual_rps": last.get("actual", 0),
        "target_rps_per_machine": last.get("target", 0),
        "total_requests_sent": last.get("sent", 0),
        "successful_requests": last.get("success", 0),
        "failed_requests": last.get("failed", 0),
        "error_types": error_types,
        "endpoint_errors": endpoint_errors,
    }


def build_api_rows(run_dir: Path) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    by_machine: list[dict[str, Any]] = []
    summary_files = sorted(run_dir.glob("*/summary_*.txt"))
    for summary_file in summary_files:
        machine = summary_file.parent.name
        if machine == "instance-metrics":
            continue
        summary = load_summary(summary_file)
        flow = summary.get("FlowName", "")
        if not flow:
            continue
        log_name = summary_file.name.replace("summary_", "loadtest_").replace(".txt", ".log")
        log_file = summary_file.with_name(log_name)
        metrics = parse_load_log(log_file) if log_file.exists() else {}
        sent = metrics.get("total_requests_sent", 0)
        failed = metrics.get("failed_requests", 0)
        error_rate = (failed / sent * 100) if sent else 0
        error_types = metrics.get("error_types", Counter())
        endpoint_errors = metrics.get("endpoint_errors", Counter())
        by_machine.append(
            {
                "flow_name": flow,
                "flow_id": summary.get("FlowID", ""),
                "machine": machine,
                "target_rps_total": summary.get("TargetRPS", ""),
                "target_rps_per_machine": csv_float(metrics.get("target_rps_per_machine"), 0),
                "avg_actual_rps": csv_float(metrics.get("avg_actual_rps"), 2),
                "peak_actual_rps": csv_float(metrics.get("peak_actual_rps"), 2),
                "last_actual_rps": csv_float(metrics.get("last_actual_rps"), 2),
                "total_requests_sent": csv_int(sent),
                "successful_requests": csv_int(metrics.get("successful_requests", 0)),
                "failed_requests": csv_int(failed),
                "error_rate_pct": csv_float(error_rate, 2),
                "exit_code": summary.get("ExitCode", ""),
                "start_time_ist": summary.get("StartTimeIST", ""),
                "end_time_ist": summary.get("EndTimeIST", ""),
                "top_error_types": "; ".join(f"{name}={count}" for name, count in error_types.most_common(5)),
                "top_error_endpoints": "; ".join(f"{name}={count}" for name, count in endpoint_errors.most_common(5)),
                "latency_note": "P90/P95/P99 not captured in current logs",
            }
        )

    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in by_machine:
        grouped[row["flow_name"]].append(row)

    flow_rows: list[dict[str, Any]] = []
    for flow, rows in sorted(grouped.items()):
        sent = sum(float(row["total_requests_sent"] or 0) for row in rows)
        success = sum(float(row["successful_requests"] or 0) for row in rows)
        failed = sum(float(row["failed_requests"] or 0) for row in rows)
        error_rate = failed / sent * 100 if sent else 0
        error_counter: Counter[str] = Counter()
        endpoint_counter: Counter[str] = Counter()
        for row in rows:
            for chunk in row["top_error_types"].split("; "):
                if "=" in chunk:
                    key, value = chunk.rsplit("=", 1)
                    error_counter[key] += int(value)
            for chunk in row["top_error_endpoints"].split("; "):
                if "=" in chunk:
                    key, value = chunk.rsplit("=", 1)
                    endpoint_counter[key] += int(value)
        flow_rows.append(
            {
                "flow_name": flow,
                "flow_id": rows[0]["flow_id"],
                "machines": ", ".join(sorted(row["machine"] for row in rows)),
                "target_rps_total": rows[0]["target_rps_total"],
                "avg_actual_rps_total": csv_float(sum(float(row["avg_actual_rps"] or 0) for row in rows), 2),
                "peak_actual_rps_total_sum": csv_float(sum(float(row["peak_actual_rps"] or 0) for row in rows), 2),
                "last_actual_rps_total": csv_float(sum(float(row["last_actual_rps"] or 0) for row in rows), 2),
                "total_requests_sent": csv_int(sent),
                "successful_requests": csv_int(success),
                "failed_requests": csv_int(failed),
                "error_rate_pct": csv_float(error_rate, 2),
                "top_error_types": "; ".join(f"{name}={count}" for name, count in error_counter.most_common(5)),
                "top_error_endpoints": "; ".join(f"{name}={count}" for name, count in endpoint_counter.most_common(5)),
                "latency_note": "P90/P95/P99 not captured in current logs",
            }
        )
    return flow_rows, by_machine


def app_container_resources(deployment: dict[str, Any]) -> dict[str, Any]:
    containers = deployment.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
    app_containers = [item for item in containers if item.get("name", "").lower() not in SIDECAR_NAMES]
    if not app_containers and containers:
        app_containers = [containers[0]]
    names: list[str] = []
    cpu_request = cpu_limit = mem_request = mem_limit = 0.0
    for container in app_containers:
        names.append(container.get("name", ""))
        resources = container.get("resources", {})
        requests = resources.get("requests", {})
        limits = resources.get("limits", {})
        cpu_request += parse_cpu_to_m(requests.get("cpu"))
        cpu_limit += parse_cpu_to_m(limits.get("cpu"))
        mem_request += parse_mem_to_mib(requests.get("memory"))
        mem_limit += parse_mem_to_mib(limits.get("memory"))
    return {
        "app_containers": "+".join(names),
        "app_cpu_request_m": cpu_request,
        "app_cpu_limit_m": cpu_limit,
        "app_memory_request_mib": mem_request,
        "app_memory_limit_mib": mem_limit,
    }


def deployment_key_for_pod(namespace: str, pod_name: str, deployment_keys: list[tuple[str, str]]) -> tuple[str, str] | None:
    matches = [
        (ns, deployment)
        for ns, deployment in deployment_keys
        if ns == namespace and pod_name.startswith(f"{deployment}-")
    ]
    if not matches:
        return None
    return max(matches, key=lambda item: len(item[1]))


def aggregate_service_usage(
    rows: list[dict[str, str]],
    deployment_keys: list[tuple[str, str]],
) -> dict[tuple[str, str], dict[str, float]]:
    by_sample: dict[tuple[str, str], dict[str, float]] = defaultdict(lambda: defaultdict(float))
    for row in rows:
        key = deployment_key_for_pod(row.get("namespace", ""), row.get("pod", ""), deployment_keys)
        if key is None:
            continue
        sample_key = (*key, row.get("epoch_seconds", ""))
        by_sample[sample_key]["cpu_m"] += float(row.get("cpu_mcores") or 0)
        by_sample[sample_key]["memory_mib"] += float(row.get("memory_mib") or 0)

    values: dict[tuple[str, str], dict[str, list[float]]] = defaultdict(lambda: {"cpu": [], "memory": []})
    for sample_key, totals in by_sample.items():
        key = (sample_key[0], sample_key[1])
        values[key]["cpu"].append(totals["cpu_m"])
        values[key]["memory"].append(totals["memory_mib"])

    result: dict[tuple[str, str], dict[str, float]] = {}
    for key, totals in values.items():
        cpu_values = totals["cpu"]
        mem_values = totals["memory"]
        result[key] = {
            "avg_cpu_m": statistics.fmean(cpu_values) if cpu_values else 0,
            "peak_cpu_m": max(cpu_values) if cpu_values else 0,
            "avg_memory_mib": statistics.fmean(mem_values) if mem_values else 0,
            "peak_memory_mib": max(mem_values) if mem_values else 0,
            "samples": len(cpu_values),
        }
    return result


def aggregate_service_network(
    rows: list[dict[str, str]],
    deployment_keys: list[tuple[str, str]],
) -> dict[tuple[str, str], dict[str, float]]:
    by_sample: dict[tuple[str, str], dict[str, float]] = defaultdict(lambda: defaultdict(float))
    for row in rows:
        key = deployment_key_for_pod(row.get("namespace", ""), row.get("pod", ""), deployment_keys)
        if key is None:
            continue
        sample_key = (*key, row.get("epoch_seconds", ""))
        by_sample[sample_key]["rx"] += float(row.get("rx_bps") or 0) / 1024
        by_sample[sample_key]["tx"] += float(row.get("tx_bps") or 0) / 1024

    values: dict[tuple[str, str], dict[str, list[float]]] = defaultdict(lambda: {"rx": [], "tx": []})
    for sample_key, totals in by_sample.items():
        key = (sample_key[0], sample_key[1])
        values[key]["rx"].append(totals["rx"])
        values[key]["tx"].append(totals["tx"])

    result: dict[tuple[str, str], dict[str, float]] = {}
    for key, totals in values.items():
        rx_values = totals["rx"]
        tx_values = totals["tx"]
        result[key] = {
            "avg_rx_kib_s": statistics.fmean(rx_values) if rx_values else 0,
            "peak_rx_kib_s": max(rx_values) if rx_values else 0,
            "avg_tx_kib_s": statistics.fmean(tx_values) if tx_values else 0,
            "peak_tx_kib_s": max(tx_values) if tx_values else 0,
        }
    return result


def pod_health_from_json(
    pods: dict[str, Any],
    deployment_keys: list[tuple[str, str]],
) -> dict[tuple[str, str], dict[str, int]]:
    health: dict[tuple[str, str], dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for pod in pods.get("items", []):
        namespace = pod.get("metadata", {}).get("namespace", "")
        name = pod.get("metadata", {}).get("name", "")
        key = deployment_key_for_pod(namespace, name, deployment_keys)
        if key is None:
            continue
        status = pod.get("status", {})
        phase = status.get("phase", "")
        container_statuses = status.get("containerStatuses", [])
        ready_containers = sum(1 for item in container_statuses if item.get("ready"))
        restart_count = sum(int(item.get("restartCount") or 0) for item in container_statuses)
        h = health[key]
        h["pods_seen"] += 1
        h["running_pods"] += 1 if phase == "Running" else 0
        h["not_running_pods"] += 0 if phase == "Running" else 1
        h["restart_total"] += restart_count
        h["restarted_pods"] += 1 if restart_count else 0
        h["ready_pods"] += 1 if container_statuses and ready_containers == len(container_statuses) else 0
        h["not_ready_pods"] += 0 if container_statuses and ready_containers == len(container_statuses) else 1
    return health


def hpa_by_deployment(hpas: dict[str, Any]) -> dict[tuple[str, str], dict[str, Any]]:
    result: dict[tuple[str, str], dict[str, Any]] = {}
    for hpa in hpas.get("items", []):
        namespace = hpa.get("metadata", {}).get("namespace", "")
        target = hpa.get("spec", {}).get("scaleTargetRef", {}).get("name", "")
        if not target:
            continue
        status = hpa.get("status", {})
        current_metrics = status.get("currentMetrics", [])
        metric_parts: list[str] = []
        for metric in current_metrics:
            metric_type = metric.get("type", "")
            if metric_type == "Resource":
                name = metric.get("resource", {}).get("name", "")
                current = metric.get("resource", {}).get("current", {})
                value = current.get("averageUtilization") or current.get("averageValue") or current.get("value") or ""
                metric_parts.append(f"{name}={value}")
            elif metric_type == "External":
                metric_name = metric.get("external", {}).get("metric", {}).get("name", "external")
                current = metric.get("external", {}).get("current", {})
                value = current.get("value") or current.get("averageValue") or ""
                metric_parts.append(f"{metric_name}={value}")
        result[(namespace, target)] = {
            "hpa_name": hpa.get("metadata", {}).get("name", ""),
            "hpa_min": hpa.get("spec", {}).get("minReplicas", ""),
            "hpa_max": hpa.get("spec", {}).get("maxReplicas", ""),
            "hpa_current": status.get("currentReplicas", ""),
            "hpa_desired": status.get("desiredReplicas", ""),
            "hpa_current_metrics": "; ".join(metric_parts),
        }
    return result


def deployment_status_by_key(deployments: dict[str, Any]) -> dict[tuple[str, str], dict[str, Any]]:
    result: dict[tuple[str, str], dict[str, Any]] = {}
    for deployment in deployments.get("items", []):
        namespace = deployment.get("metadata", {}).get("namespace", "")
        name = deployment.get("metadata", {}).get("name", "")
        status = deployment.get("status", {})
        conditions = status.get("conditions", [])
        condition_summary = "; ".join(
            f"{item.get('type')}={item.get('status')}" for item in conditions if item.get("type")
        )
        result[(namespace, name)] = {
            "deployment_generation": deployment.get("metadata", {}).get("generation", ""),
            "observed_generation": status.get("observedGeneration", ""),
            "deployment_replicas": status.get("replicas", ""),
            "deployment_ready": status.get("readyReplicas", 0),
            "deployment_available": status.get("availableReplicas", 0),
            "deployment_unavailable": status.get("unavailableReplicas", 0),
            "deployment_conditions": condition_summary,
            **app_container_resources(deployment),
        }
    return result


def cluster_headroom_summary(node_rows: list[dict[str, str]]) -> dict[str, Any]:
    latest_nodes = latest_by_key(node_rows, ("node",))
    rows = list(latest_nodes.values())
    if not rows:
        return {}

    def total(column: str) -> float:
        return sum(float(row.get(column) or 0) for row in rows)

    instance_types = Counter(row.get("instance_type", "") for row in rows if row.get("instance_type"))
    zones = Counter(row.get("zone", "") for row in rows if row.get("zone"))
    cpu_alloc = total("cpu_allocatable_m")
    cpu_req = total("cpu_requested_m")
    cpu_use = total("cpu_usage_m")
    mem_alloc = total("memory_allocatable_mib")
    mem_req = total("memory_requested_mib")
    mem_use = total("memory_usage_mib")
    return {
        "node_count": len(rows),
        "instance_types": "; ".join(f"{name}={count}" for name, count in sorted(instance_types.items())),
        "zones": "; ".join(f"{name}={count}" for name, count in sorted(zones.items())),
        "cpu_allocatable_m": csv_float(cpu_alloc, 0),
        "cpu_requested_m": csv_float(cpu_req, 0),
        "cpu_usage_m": csv_float(cpu_use, 0),
        "cpu_request_headroom_m": csv_float(cpu_alloc - cpu_req, 0),
        "cpu_usage_headroom_m": csv_float(cpu_alloc - cpu_use, 0),
        "cpu_requested_pct": csv_float(cpu_req / cpu_alloc * 100 if cpu_alloc else 0, 2),
        "cpu_usage_pct": csv_float(cpu_use / cpu_alloc * 100 if cpu_alloc else 0, 2),
        "memory_allocatable_mib": csv_float(mem_alloc, 0),
        "memory_requested_mib": csv_float(mem_req, 0),
        "memory_usage_mib": csv_float(mem_use, 0),
        "memory_request_headroom_mib": csv_float(mem_alloc - mem_req, 0),
        "memory_usage_headroom_mib": csv_float(mem_alloc - mem_use, 0),
        "memory_requested_pct": csv_float(mem_req / mem_alloc * 100 if mem_alloc else 0, 2),
        "memory_usage_pct": csv_float(mem_use / mem_alloc * 100 if mem_alloc else 0, 2),
        "pods_allocatable": csv_float(total("pods_allocatable"), 0),
        "pods_running": csv_float(total("pods_running"), 0),
        "pods_headroom": csv_float(total("pods_headroom"), 0),
    }


def profile_cluster_headroom(rows: list[dict[str, str]]) -> dict[tuple[str, str], dict[str, Any]]:
    if not rows:
        return {}
    latest_epoch = max(float(row.get("epoch_seconds") or 0) for row in rows)
    latest_rows = [row for row in rows if float(row.get("epoch_seconds") or 0) == latest_epoch]
    grouped: dict[tuple[str, str], list[dict[str, str]]] = defaultdict(list)
    for row in latest_rows:
        grouped[(row.get("namespace", ""), row.get("deployment", ""))].append(row)
    result: dict[tuple[str, str], dict[str, Any]] = {}
    for key, values in grouped.items():
        cluster_total = next((row for row in values if row.get("node") == "__cluster_total__"), None)
        node_values = [row for row in values if row.get("node") != "__cluster_total__"]
        limiting = Counter(row.get("limiting_resource", "") for row in node_values if row.get("limiting_resource"))
        if cluster_total:
            additional_pods = int(float(cluster_total.get("additional_pods_by_requests") or 0))
        else:
            additional_pods = sum(
                int(float(row.get("additional_pods_by_requests") or 0)) for row in node_values
            )
        result[key] = {
            "additional_pods_by_requests_cluster": additional_pods,
            "headroom_limiting_resource": limiting.most_common(1)[0][0] if limiting else "",
        }
    return result


def build_backend_health_rows(k8s_dir: Path) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    profile_rows = read_csv(k8s_dir / "deployment_profiles.csv")
    pod_usage_rows = read_csv(k8s_dir / "pod_usage.csv")
    pod_network_rows = read_csv(k8s_dir / "pod_network.csv")
    node_rows = read_csv(k8s_dir / "node_headroom.csv")
    profile_headroom_rows = read_csv(k8s_dir / "profile_headroom.csv")

    latest_profiles = latest_by_key(profile_rows, ("namespace", "deployment"))
    deployment_keys = sorted(latest_profiles.keys())
    usage = aggregate_service_usage(pod_usage_rows, deployment_keys)
    network = aggregate_service_network(pod_network_rows, deployment_keys)
    profile_headroom = profile_cluster_headroom(profile_headroom_rows)

    raw_dir = latest_raw_dir(k8s_dir)
    pods_json = read_json(raw_dir / "pods.json") if raw_dir else {}
    hpa_json = read_json(raw_dir / "hpa.json") if raw_dir else {}
    deployments_json = read_json(raw_dir / "deployments.json") if raw_dir else {}
    pod_health = pod_health_from_json(pods_json, deployment_keys)
    hpa_data = hpa_by_deployment(hpa_json)
    deployment_status = deployment_status_by_key(deployments_json)

    health_rows: list[dict[str, Any]] = []
    capacity_rows: list[dict[str, Any]] = []
    for key in deployment_keys:
        namespace, deployment = key
        profile = latest_profiles[key]
        service = TARGET_DEPLOYMENTS.get(key, deployment)
        usage_data = usage.get(key, {})
        network_data = network.get(key, {})
        pod_data = pod_health.get(key, {})
        hpa = hpa_data.get(key, {})
        status = deployment_status.get(key, {})
        headroom = profile_headroom.get(key, {})
        replicas = float(profile.get("replicas") or 0)
        ready_replicas = float(profile.get("ready_replicas") or 0)
        cpu_request_per_pod = float(profile.get("cpu_request_m") or 0)
        mem_request_per_pod = float(profile.get("memory_request_mib") or 0)
        total_cpu_request = cpu_request_per_pod * replicas
        total_mem_request = mem_request_per_pod * replicas
        peak_cpu_pct = usage_data.get("peak_cpu_m", 0) / total_cpu_request * 100 if total_cpu_request else 0
        peak_mem_pct = usage_data.get("peak_memory_mib", 0) / total_mem_request * 100 if total_mem_request else 0

        reasons: list[str] = []
        severity = 0
        if ready_replicas < replicas:
            severity = max(severity, 2)
            reasons.append("deployment has unready replicas")
        if int(pod_data.get("not_ready_pods", 0)) > 0:
            severity = max(severity, 2)
            reasons.append("latest pod snapshot has not-ready pods")
        if int(pod_data.get("not_running_pods", 0)) > 0:
            severity = max(severity, 2)
            reasons.append("latest pod snapshot has non-running pods")
        if peak_cpu_pct >= 100:
            severity = max(severity, 2)
            reasons.append("peak CPU usage exceeded pod CPU requests")
        elif peak_cpu_pct >= 80:
            severity = max(severity, 1)
            reasons.append("peak CPU usage was high vs requests")
        if peak_mem_pct >= 100:
            severity = max(severity, 2)
            reasons.append("peak memory usage exceeded pod memory requests")
        elif peak_mem_pct >= 80:
            severity = max(severity, 1)
            reasons.append("peak memory usage was high vs requests")
        if int(pod_data.get("restart_total", 0)) > 0:
            severity = max(severity, 1)
            reasons.append("pod restarts visible in latest snapshot")
        if hpa.get("hpa_min") == hpa.get("hpa_max") and hpa.get("hpa_min") not in ("", None):
            severity = max(severity, 1)
            reasons.append("HPA min equals max, scaling is fixed")
        if int(headroom.get("additional_pods_by_requests_cluster", 0) or 0) <= 0:
            severity = max(severity, 1)
            reasons.append("no extra request-based pod headroom estimated")

        health = "OK"
        if severity == 1:
            health = "WARN"
        elif severity >= 2:
            health = "CRITICAL"
        if not reasons:
            reasons.append("no readiness, restart, or request-pressure issue detected")

        common = {
            "service": service,
            "namespace": namespace,
            "deployment": deployment,
            "current_pods": csv_int(replicas),
            "ready_replicas": csv_int(ready_replicas),
            "hpa_min": hpa.get("hpa_min", ""),
            "hpa_max": hpa.get("hpa_max", ""),
            "hpa_current": hpa.get("hpa_current", ""),
            "hpa_desired": hpa.get("hpa_desired", ""),
            "hpa_current_metrics": hpa.get("hpa_current_metrics", ""),
            "app_containers": status.get("app_containers", ""),
            "app_cpu_request_m": csv_float(status.get("app_cpu_request_m", 0), 0),
            "app_cpu_limit_m": csv_float(status.get("app_cpu_limit_m", 0), 0),
            "app_memory_request_mib": csv_float(status.get("app_memory_request_mib", 0), 0),
            "app_memory_limit_mib": csv_float(status.get("app_memory_limit_mib", 0), 0),
            "pod_cpu_request_m": csv_float(cpu_request_per_pod, 0),
            "pod_cpu_limit_m": profile.get("cpu_limit_m", ""),
            "pod_memory_request_mib": csv_float(mem_request_per_pod, 0),
            "pod_memory_limit_mib": profile.get("memory_limit_mib", ""),
        }
        capacity_rows.append(common)
        health_rows.append(
            {
                **common,
                "health": health,
                "health_reasons": "; ".join(reasons),
                "latest_pods_seen": pod_data.get("pods_seen", 0),
                "running_pods": pod_data.get("running_pods", 0),
                "not_running_pods": pod_data.get("not_running_pods", 0),
                "ready_pods": pod_data.get("ready_pods", 0),
                "not_ready_pods": pod_data.get("not_ready_pods", 0),
                "restart_total": pod_data.get("restart_total", 0),
                "restarted_pods": pod_data.get("restarted_pods", 0),
                "avg_cpu_total_m": csv_float(usage_data.get("avg_cpu_m", 0), 2),
                "peak_cpu_total_m": csv_float(usage_data.get("peak_cpu_m", 0), 2),
                "peak_cpu_request_pct": csv_float(peak_cpu_pct, 2),
                "avg_memory_total_mib": csv_float(usage_data.get("avg_memory_mib", 0), 2),
                "peak_memory_total_mib": csv_float(usage_data.get("peak_memory_mib", 0), 2),
                "peak_memory_request_pct": csv_float(peak_mem_pct, 2),
                "avg_rx_kib_s": csv_float(network_data.get("avg_rx_kib_s", 0), 2),
                "peak_rx_kib_s": csv_float(network_data.get("peak_rx_kib_s", 0), 2),
                "avg_tx_kib_s": csv_float(network_data.get("avg_tx_kib_s", 0), 2),
                "peak_tx_kib_s": csv_float(network_data.get("peak_tx_kib_s", 0), 2),
                "additional_pods_by_requests_cluster": headroom.get("additional_pods_by_requests_cluster", ""),
                "headroom_limiting_resource": headroom.get("headroom_limiting_resource", ""),
                "deployment_available": status.get("deployment_available", ""),
                "deployment_unavailable": status.get("deployment_unavailable", 0),
                "deployment_conditions": status.get("deployment_conditions", ""),
            }
        )

    ec2_summary = cluster_headroom_summary(node_rows)
    ec2_rows = [ec2_summary] if ec2_summary else []
    return health_rows, capacity_rows + ec2_rows


def parse_dstat_file(path: Path) -> dict[str, Any]:
    cpu_values: list[float] = []
    mem_pct_values: list[float] = []
    mem_used_bytes_values: list[float] = []
    recv_values: list[float] = []
    send_values: list[float] = []
    for raw_line in path.read_text(errors="replace").splitlines():
        if "|" not in raw_line or not re.match(r"^\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\|", raw_line):
            continue
        parts = [part.strip() for part in raw_line.split("|")]
        if len(parts) < 5:
            continue
        cpu_parts = parts[1].split()
        mem_parts = parts[2].split()
        net_parts = parts[3].split()
        if len(cpu_parts) < 3 or len(mem_parts) < 4 or len(net_parts) < 2:
            continue
        try:
            idle = float(cpu_parts[2])
            used = parse_size_to_bytes(mem_parts[0])
            free = parse_size_to_bytes(mem_parts[1])
            buff = parse_size_to_bytes(mem_parts[2])
            cache = parse_size_to_bytes(mem_parts[3])
            recv = parse_size_to_bytes(net_parts[0])
            send = parse_size_to_bytes(net_parts[1])
        except ValueError:
            continue
        total_mem = used + free + buff + cache
        cpu_values.append(max(0.0, 100.0 - idle))
        mem_used_bytes_values.append(used)
        mem_pct_values.append(used / total_mem * 100 if total_mem else 0)
        recv_values.append(recv / 1024)
        send_values.append(send / 1024)
    return {
        "samples": len(cpu_values),
        "avg_cpu_pct": statistics.fmean(cpu_values) if cpu_values else 0,
        "peak_cpu_pct": max(cpu_values) if cpu_values else 0,
        "avg_memory_pct": statistics.fmean(mem_pct_values) if mem_pct_values else 0,
        "peak_memory_pct": max(mem_pct_values) if mem_pct_values else 0,
        "peak_memory_used_mib": max(mem_used_bytes_values) / 1024 / 1024 if mem_used_bytes_values else 0,
        "avg_recv_kib_s": statistics.fmean(recv_values) if recv_values else 0,
        "peak_recv_kib_s": max(recv_values) if recv_values else 0,
        "avg_send_kib_s": statistics.fmean(send_values) if send_values else 0,
        "peak_send_kib_s": max(send_values) if send_values else 0,
    }


def build_load_generator_rows(run_dir: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in sorted((run_dir / "instance-metrics").glob("dstat_*.log")):
        match = re.search(r"_([^_/]+)\.log$", path.name)
        machine = match.group(1) if match else path.stem
        metrics = parse_dstat_file(path)
        rows.append(
            {
                "load_generator": machine,
                "samples": metrics["samples"],
                "avg_cpu_pct": csv_float(metrics["avg_cpu_pct"], 2),
                "peak_cpu_pct": csv_float(metrics["peak_cpu_pct"], 2),
                "avg_memory_pct": csv_float(metrics["avg_memory_pct"], 2),
                "peak_memory_pct": csv_float(metrics["peak_memory_pct"], 2),
                "peak_memory_used_mib": csv_float(metrics["peak_memory_used_mib"], 2),
                "avg_recv_kib_s": csv_float(metrics["avg_recv_kib_s"], 2),
                "peak_recv_kib_s": csv_float(metrics["peak_recv_kib_s"], 2),
                "avg_send_kib_s": csv_float(metrics["avg_send_kib_s"], 2),
                "peak_send_kib_s": csv_float(metrics["peak_send_kib_s"], 2),
            }
        )
    return rows


def write_sectioned_sheet(path: Path, sections: list[tuple[str, list[dict[str, Any]], list[str]]]) -> None:
    with path.open("w", newline="") as handle:
        writer = csv.writer(handle)
        for index, (title, rows, fieldnames) in enumerate(sections):
            if index:
                writer.writerow([])
            writer.writerow([title])
            writer.writerow(fieldnames)
            for row in rows:
                writer.writerow([row.get(field, "") for field in fieldnames])


def main() -> int:
    args = parse_args()
    run_dir = Path(args.run_dir).resolve()
    if not run_dir.exists():
        raise SystemExit(f"Run directory not found: {run_dir}")
    output_dir = Path(args.output_dir).resolve() if args.output_dir else run_dir / "summary-csv"
    output_dir.mkdir(parents=True, exist_ok=True)

    k8s_dir = run_dir / "k8s-cluster-metrics"
    api_flow_rows, api_machine_rows = build_api_rows(run_dir)
    backend_health_rows, capacity_and_ec2_rows = build_backend_health_rows(k8s_dir) if k8s_dir.exists() else ([], [])
    load_generator_rows = build_load_generator_rows(run_dir)

    api_flow_fields = [
        "flow_name",
        "flow_id",
        "machines",
        "target_rps_total",
        "avg_actual_rps_total",
        "peak_actual_rps_total_sum",
        "last_actual_rps_total",
        "total_requests_sent",
        "successful_requests",
        "failed_requests",
        "error_rate_pct",
        "top_error_types",
        "top_error_endpoints",
        "latency_note",
    ]
    api_machine_fields = [
        "flow_name",
        "flow_id",
        "machine",
        "target_rps_total",
        "target_rps_per_machine",
        "avg_actual_rps",
        "peak_actual_rps",
        "last_actual_rps",
        "total_requests_sent",
        "successful_requests",
        "failed_requests",
        "error_rate_pct",
        "exit_code",
        "start_time_ist",
        "end_time_ist",
        "top_error_types",
        "top_error_endpoints",
        "latency_note",
    ]
    backend_health_fields = [
        "service",
        "health",
        "health_reasons",
        "namespace",
        "deployment",
        "current_pods",
        "ready_replicas",
        "latest_pods_seen",
        "running_pods",
        "not_running_pods",
        "ready_pods",
        "not_ready_pods",
        "restart_total",
        "restarted_pods",
        "hpa_min",
        "hpa_max",
        "hpa_current",
        "hpa_desired",
        "hpa_current_metrics",
        "app_containers",
        "app_cpu_request_m",
        "app_cpu_limit_m",
        "app_memory_request_mib",
        "app_memory_limit_mib",
        "pod_cpu_request_m",
        "pod_cpu_limit_m",
        "pod_memory_request_mib",
        "pod_memory_limit_mib",
        "avg_cpu_total_m",
        "peak_cpu_total_m",
        "peak_cpu_request_pct",
        "avg_memory_total_mib",
        "peak_memory_total_mib",
        "peak_memory_request_pct",
        "avg_rx_kib_s",
        "peak_rx_kib_s",
        "avg_tx_kib_s",
        "peak_tx_kib_s",
        "additional_pods_by_requests_cluster",
        "headroom_limiting_resource",
        "deployment_available",
        "deployment_unavailable",
        "deployment_conditions",
    ]
    capacity_fields = [
        "service",
        "namespace",
        "deployment",
        "current_pods",
        "ready_replicas",
        "hpa_min",
        "hpa_max",
        "app_containers",
        "app_cpu_request_m",
        "app_cpu_limit_m",
        "app_memory_request_mib",
        "app_memory_limit_mib",
        "pod_cpu_request_m",
        "pod_cpu_limit_m",
        "pod_memory_request_mib",
        "pod_memory_limit_mib",
    ]
    ec2_fields = [
        "node_count",
        "instance_types",
        "zones",
        "cpu_allocatable_m",
        "cpu_requested_m",
        "cpu_usage_m",
        "cpu_request_headroom_m",
        "cpu_usage_headroom_m",
        "cpu_requested_pct",
        "cpu_usage_pct",
        "memory_allocatable_mib",
        "memory_requested_mib",
        "memory_usage_mib",
        "memory_request_headroom_mib",
        "memory_usage_headroom_mib",
        "memory_requested_pct",
        "memory_usage_pct",
        "pods_allocatable",
        "pods_running",
        "pods_headroom",
    ]
    load_generator_fields = [
        "load_generator",
        "samples",
        "avg_cpu_pct",
        "peak_cpu_pct",
        "avg_memory_pct",
        "peak_memory_pct",
        "peak_memory_used_mib",
        "avg_recv_kib_s",
        "peak_recv_kib_s",
        "avg_send_kib_s",
        "peak_send_kib_s",
    ]
    notes_rows = [
        {
            "note": "Latency percentiles are intentionally blank because P90/P95/P99 are not captured in the current load-test logs.",
        },
        {
            "note": "API observed RPS and error rate are flow-level/bundle-level values. Per-endpoint success counts are not available for bundled flows.",
        },
        {
            "note": "Top error type and endpoint counts are log-line counts and may double-count one failed request when the runner prints both application and step-level errors.",
        },
        {
            "note": "Pod request/limit columns include app-only and total-pod values. Total-pod includes sidecars such as fluentbit.",
        },
        {
            "note": "Backend health is derived from Kubernetes readiness, restarts, HPA status, pod CPU/memory/network usage, and request-based headroom.",
        },
    ]
    notes_fields = ["note"]

    service_capacity_rows = [
        row for row in capacity_and_ec2_rows if row.get("service")
    ]
    ec2_rows = [
        row for row in capacity_and_ec2_rows if row.get("node_count")
    ]

    write_csv(output_dir / "api_flow_summary.csv", api_flow_rows, api_flow_fields)
    write_csv(output_dir / "api_flow_by_machine.csv", api_machine_rows, api_machine_fields)
    write_csv(output_dir / "backend_service_health.csv", backend_health_rows, backend_health_fields)
    write_csv(output_dir / "service_capacity.csv", service_capacity_rows, capacity_fields)
    write_csv(output_dir / "ec2_headroom_summary.csv", ec2_rows, ec2_fields)
    write_csv(output_dir / "load_generator_summary.csv", load_generator_rows, load_generator_fields)
    write_csv(output_dir / "report_notes.csv", notes_rows, notes_fields)
    write_sectioned_sheet(
        output_dir / "report_sheet.csv",
        [
            ("API Flow Summary", api_flow_rows, api_flow_fields),
            ("Backend Service Health", backend_health_rows, backend_health_fields),
            ("Service Capacity", service_capacity_rows, capacity_fields),
            ("EC2 Headroom Summary", ec2_rows, ec2_fields),
            ("Load Generator Summary", load_generator_rows, load_generator_fields),
            ("Report Notes", notes_rows, notes_fields),
        ],
    )

    print(f"Wrote CSV report files to {output_dir}")
    print(f"Main sheet: {output_dir / 'report_sheet.csv'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
