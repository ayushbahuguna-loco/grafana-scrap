# Grafana Metrics Extraction Tool

Node.js tool that reads operations from a CSV file, fetches P95/P99 latency metrics from Grafana/Prometheus, and writes the results back to a new CSV file.

## Project Structure

```text
config/config.js
input/metrics.csv
output/results.csv
output/summary.json
logs/missing_operations.txt
src/grafanaClient.js
src/csvReader.js
src/csvWriter.js
src/metricsCalculator.js
src/main.js
```

## Setup

```bash
npm install
cp .env.example .env
```

Place the source CSV at:

```text
input/metrics.csv
```

At minimum, add one operation per row under the `Operation` column.

Update `.env` with the Grafana datasource UID, session cookie, time range, and any required headers.

## Configuration

All runtime configuration is centralized in `config/config.js` and can be overridden with environment variables.

Key settings:

| Variable | Description |
| --- | --- |
| `GRAFANA_URL` | Grafana query endpoint. Defaults to `https://insight.getloconow.com/api/ds/query`. |
| `DATASOURCE_UID` | Prometheus datasource UID from Grafana. Required. |
| `DASHBOARD_UID` | Optional dashboard UID context. |
| `GRAFANA_SESSION` | Raw `grafana_session` cookie value. |
| `GRAFANA_COOKIE` | Full cookie header value. Overrides `GRAFANA_SESSION` when set. |
| `GRAFANA_ORG_ID` | Grafana org id for `X-Grafana-Org-Id`. |
| `GRAFANA_HEADERS_JSON` | Extra headers as JSON, for example `{"Authorization":"Bearer token"}`. |
| `CLUSTER` | Prometheus `cluster` label. Defaults to `load-testing-eks`. |
| `NAMESPACE` | Prometheus `namespace` label. Defaults to `ivory`. |
| `NAMESPACES` | Optional comma-separated namespace list. Overrides single-namespace matching when set, for example `ivory,authorization,leaderboard,chat,quests,loco-store`. |
| `LOOKBACK_MINUTES` | Optional rolling time range. Set `10` to query from now minus 10 minutes to now. Overrides `LOOKBACK_HOURS`, `FROM_TIMESTAMP`, and `TO_TIMESTAMP`. |
| `LOOKBACK_HOURS` | Optional rolling time range. Set `48` to query from now minus 48 hours to now. Overrides `FROM_TIMESTAMP` and `TO_TIMESTAMP` when `LOOKBACK_MINUTES` is empty. |
| `FROM_TIMESTAMP` | Grafana query start time, for example `now-1h` or epoch millis. |
| `TO_TIMESTAMP` | Grafana query end time, for example `now` or epoch millis. |
| `VALUE_DIVISOR` | Divides raw Prometheus latency values before writing CSV. Use `1` to keep milliseconds. |
| `HEADER_ROW` | Header row number. Defaults to `1`. |
| `CONCURRENCY` | Number of operations to query in parallel. Defaults to `3`. |

Column names can also be overridden:

```bash
OPERATION_COLUMN=Operation
P95_MEAN_COLUMN=Jordon P95 Mean
P95_MAX_COLUMN=Jordon P95 Max
P99_MEAN_COLUMN=Jordon P99 Mean
P99_MAX_COLUMN=Jordon P99 Max
```

## CSV Template

The expected CSV headings are:

```csv
Feature Name,Flow Number,Operation,API,Jordon P95 Mean,Jordon P95 Max,Jordon P99 Mean,Jordon P99 Max
```

The tool preserves all existing CSV columns and row order. It updates only:

```text
Jordon P95 Mean
Jordon P95 Max
Jordon P99 Mean
Jordon P99 Max
```

CSV files do not store spreadsheet formatting, so cell styling cannot be preserved in CSV output.

## Run

```bash
npm start
```

The tool writes:

```text
output/results.csv
output/summary.json
logs/missing_operations.txt
```

## Query Template

The operation name is read dynamically from CSV and inserted into:

```promql
histogram_quantile(
  0.95,
  sum(
    rate(
      {
        __name__=~".*requests_bucket",
        cluster="load-testing-eks",
        namespace="ivory",
        operation="<OPERATION>"
      }[1m]
    )
  ) by (le)
)
```

P99 uses the same query with `0.99`.

## Error Handling

If an operation fails, returns no frames, or has empty metric values, the tool logs a warning, skips that operation, and continues processing the remaining operations. Failed operations are written to `logs/missing_operations.txt` and included in `output/summary.json`.
