#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$REPO_ROOT/scripts/run-test-v6.sh"
K8S_COLLECTOR="$REPO_ROOT/scripts/k8s-cluster-metrics.sh"
REPORT_GENERATOR="$REPO_ROOT/scripts/generate-load-test-report-csv.py"
DEFAULT_RUN_ID="feed_v5_orchestration_test_default"
CONFIGURED_RUN_ID="feed_v5_orchestration_test_configured"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf \
        "$TMP_DIR" \
        "$REPO_ROOT/results/$DEFAULT_RUN_ID" \
        "$REPO_ROOT/results/$CONFIGURED_RUN_ID"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_file_contains() {
    local file="$1"
    local needle="$2"
    grep -Fq -- "$needle" "$file" || fail "expected $file to contain: $needle"
}

assert_file_not_contains() {
    local file="$1"
    local needle="$2"
    if grep -Fq -- "$needle" "$file"; then
        fail "expected $file not to contain: $needle"
    fi
}

dry_output="$(
    ENV_FILE=/dev/null \
    "$RUNNER" \
        --dry-run \
        --no-k8s \
        --no-dstat \
        --no-csv \
        --machines load-test-turkey-01 \
        --feed-v5-webhome \
        --flow-duration 180s
)"

assert_contains "$dry_output" "flow=feed_v5_webhome flow_id=91 api_count=1"
assert_contains "$dry_output" "FeedBaseURL=https://dev-api.loco.com/fd/"
assert_contains "$dry_output" "FeedMinResponseBytes=6144"
assert_contains "$dry_output" "FeedCacheKeyConfigured=false"

if ENV_FILE=/dev/null FEED_MIN_RESPONSE_BYTES=invalid \
    "$RUNNER" --dry-run --no-metrics --no-csv --machines load-test-turkey-01 --feed-v5-webhome \
    >"$TMP_DIR/invalid-minimum.log" 2>&1
then
    fail "invalid FEED_MIN_RESPONSE_BYTES unexpectedly succeeded"
fi
assert_file_contains "$TMP_DIR/invalid-minimum.log" "FEED_MIN_RESPONSE_BYTES must be a positive integer"

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/sshpass" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    -p) shift 2 ;;
    -e) shift ;;
esac
exec "$@"
FAKE

cat >"$FAKE_BIN/ssh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
{
    echo "--- ssh call ---"
    printf '%s\n' "$@"
} >>"$SSH_CAPTURE_FILE"
args=("$@")
remote_command="${args[${#args[@]}-1]}"
if [[ "$remote_command" == *"./scripts/run-direct.sh"* ]]; then
    bash -n -c "$remote_command"
fi
FAKE

cat >"$FAKE_BIN/scp" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
source_arg="${args[${#args[@]}-2]}"
target_arg="${args[${#args[@]}-1]}"
mkdir -p "$target_arg"
touch "$target_arg/$(basename "${source_arg#*:}")"
FAKE

chmod +x "$FAKE_BIN/sshpass" "$FAKE_BIN/ssh" "$FAKE_BIN/scp"

run_captured() {
    local run_id="$1"
    local capture_file="$2"
    local feed_base_url="$3"
    local feed_minimum="$4"
    local feed_cache_key="$5"

    : >"$capture_file"
    PATH="$FAKE_BIN:$PATH" \
    ENV_FILE=/dev/null \
    TURKEY_01_ROOT_PASSWORD=test-password \
    SSH_CAPTURE_FILE="$capture_file" \
    RUN_ID="$run_id" \
    FEED_BASE_URL="$feed_base_url" \
    FEED_MIN_RESPONSE_BYTES="$feed_minimum" \
    FEED_CACHE_KEY="$feed_cache_key" \
    "$RUNNER" \
        --no-k8s \
        --no-dstat \
        --no-csv \
        --machines load-test-turkey-01 \
        --feed-v5-webhome \
        --flow-duration 1s \
        >"$TMP_DIR/$run_id.log"
}

DEFAULT_CAPTURE="$TMP_DIR/default-remote-command.log"
run_captured \
    "$DEFAULT_RUN_ID" \
    "$DEFAULT_CAPTURE" \
    "https://dev-api.loco.com/fd/" \
    "6144" \
    ""

assert_file_contains "$DEFAULT_CAPTURE" "FLOW_ID=91"
assert_file_contains "$DEFAULT_CAPTURE" "FEED_BASE_URL=https://dev-api.loco.com/fd/"
assert_file_contains "$DEFAULT_CAPTURE" "FEED_MIN_RESPONSE_BYTES=6144"
assert_file_contains "$DEFAULT_CAPTURE" "env -u FEED_CACHE_KEY"
assert_file_not_contains "$DEFAULT_CAPTURE" "FEED_CACHE_KEY="

for variable in \
    MODE RUN_ID STREAM_UID STREAMER_UID FLOW_ID TARGET_RPS RPS_WORKERS DURATION \
    LOAD_GENERATORS LOAD_GENERATOR_INDEX RPS_DRAIN_TIMEOUT
do
    assert_file_contains "$DEFAULT_CAPTURE" "$variable="
done

CONFIGURED_CAPTURE="$TMP_DIR/configured-remote-command.log"
run_captured \
    "$CONFIGURED_RUN_ID" \
    "$CONFIGURED_CAPTURE" \
    "https://qa-api.loco.com/fd/" \
    "7000" \
    "explicit cache&key"

assert_file_contains "$CONFIGURED_CAPTURE" "FLOW_ID=91"
assert_file_contains "$CONFIGURED_CAPTURE" "FEED_BASE_URL=https://qa-api.loco.com/fd/"
assert_file_contains "$CONFIGURED_CAPTURE" "FEED_MIN_RESPONSE_BYTES=7000"
assert_file_contains "$CONFIGURED_CAPTURE" 'FEED_CACHE_KEY=explicit\ cache\&key'
assert_file_not_contains "$CONFIGURED_CAPTURE" "-u FEED_CACHE_KEY"
assert_file_not_contains "$CONFIGURED_CAPTURE" "authorization="

assert_file_contains "$K8S_COLLECTOR" 'feed-service/feed-api-deployment'
assert_file_contains "$REPORT_GENERATOR" '("feed-service", "feed-api-deployment"): "Feed API"'

PYTHONPYCACHEPREFIX="$TMP_DIR/pycache" python3 - "$REPORT_GENERATOR" <<'PY'
import importlib.util
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("load_test_report", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

rows = module.hpa_by_deployment({
    "items": [{
        "metadata": {"name": "feed-hpa", "namespace": "feed-service"},
        "spec": {
            "minReplicas": 1,
            "maxReplicas": 1,
            "scaleTargetRef": {"name": "feed-api-deployment"},
        },
        "status": {"currentMetrics": None, "currentReplicas": 1, "desiredReplicas": 1},
    }]
})
assert rows[("feed-service", "feed-api-deployment")]["hpa_current_metrics"] == ""
PY

echo "PASS: Feed v5 orchestration and Kubernetes metrics configuration are registered safely"
