const dotenv = require('dotenv');

dotenv.config();

function numberFromEnv(name, fallback) {
  const rawValue = process.env[name];

  if (rawValue === undefined || rawValue === '') {
    return fallback;
  }

  const parsed = Number(rawValue);

  if (!Number.isFinite(parsed)) {
    throw new Error(`${name} must be a valid number.`);
  }

  return parsed;
}

function jsonObjectFromEnv(name, fallback = {}) {
  const rawValue = process.env[name];

  if (!rawValue) {
    return fallback;
  }

  try {
    const parsed = JSON.parse(rawValue);

    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error('value is not a JSON object');
    }

    return parsed;
  } catch (error) {
    throw new Error(`${name} must be a valid JSON object. ${error.message}`);
  }
}

function buildTimeRange() {
  const lookbackMinutes = numberFromEnv('LOOKBACK_MINUTES', 0);
  const lookbackHours = numberFromEnv('LOOKBACK_HOURS', 0);

  if (lookbackMinutes > 0) {
    const to = Date.now();
    const from = to - lookbackMinutes * 60 * 1000;

    return {
      fromTimestamp: String(from),
      toTimestamp: String(to),
      lookbackMinutes,
      lookbackHours: 0
    };
  }

  if (lookbackHours > 0) {
    const to = Date.now();
    const from = to - lookbackHours * 60 * 60 * 1000;

    return {
      fromTimestamp: String(from),
      toTimestamp: String(to),
      lookbackMinutes: 0,
      lookbackHours
    };
  }

  return {
    fromTimestamp: process.env.FROM_TIMESTAMP || 'now-1h',
    toTimestamp: process.env.TO_TIMESTAMP || 'now',
    lookbackMinutes: 0,
    lookbackHours: 0
  };
}

function listFromEnv(name, fallback) {
  const rawValue = process.env[name];

  if (!rawValue) {
    return fallback;
  }

  return rawValue
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean);
}

function getCookieValue(cookieHeader, cookieName) {
  return String(cookieHeader || '')
    .split(';')
    .map((part) => part.trim())
    .find((part) => part.startsWith(`${cookieName}=`))
    ?.split('=')
    .slice(1)
    .join('=');
}

const grafanaSession = process.env.GRAFANA_SESSION || '';
// Use GRAFANA_COOKIE for a full Cookie header, or GRAFANA_SESSION for only the session value.
const grafanaCookie =
  process.env.GRAFANA_COOKIE || (grafanaSession ? `grafana_session=${grafanaSession}` : '');
const timeRange = buildTimeRange();

// Keep all runtime knobs in one place; .env is used so secrets do not live in source.
const config = {
  grafanaUrl: process.env.GRAFANA_URL || 'https://insight.getloconow.com/api/ds/query',
  datasourceUid: process.env.DATASOURCE_UID || '',
  dashboardUid: process.env.DASHBOARD_UID || '',
  grafanaSession,
  grafanaCookie,
  orgId: process.env.GRAFANA_ORG_ID || '1',
  additionalHeaders: jsonObjectFromEnv('GRAFANA_HEADERS_JSON', {}),

  cluster: process.env.CLUSTER === undefined ? 'load-testing-eks' : process.env.CLUSTER,
  namespace: process.env.NAMESPACE || 'ivory',
  namespaces: listFromEnv('NAMESPACES', [process.env.NAMESPACE || 'ivory']),
  fromTimestamp: timeRange.fromTimestamp,
  toTimestamp: timeRange.toTimestamp,
  lookbackMinutes: timeRange.lookbackMinutes,
  lookbackHours: timeRange.lookbackHours,
  rateWindow: process.env.RATE_WINDOW || '1m',
  valueDivisor: numberFromEnv('VALUE_DIVISOR', 1),

  inputFile: process.env.INPUT_FILE || 'input/metrics.csv',
  outputFile: process.env.OUTPUT_FILE || 'output/results.csv',
  summaryFile: process.env.SUMMARY_FILE || 'output/summary.json',
  missingOperationsFile: process.env.MISSING_OPERATIONS_FILE || 'logs/missing_operations.txt',
  headerRow: numberFromEnv('HEADER_ROW', 1),

  requestTimeoutMs: numberFromEnv('REQUEST_TIMEOUT_MS', 30000),
  maxDataPoints: numberFromEnv('MAX_DATA_POINTS', 1000),
  intervalMs: numberFromEnv('INTERVAL_MS', 1000),
  concurrency: numberFromEnv('CONCURRENCY', 3),

  operationColumn: process.env.OPERATION_COLUMN || 'Operation',
  metricColumns: {
    p95Mean: process.env.P95_MEAN_COLUMN || 'Jordon P95 Mean',
    p95Max: process.env.P95_MAX_COLUMN || 'Jordon P95 Max',
    p99Mean: process.env.P99_MEAN_COLUMN || 'Jordon P99 Mean',
    p99Max: process.env.P99_MAX_COLUMN || 'Jordon P99 Max'
  }
};

function validateConfig(value) {
  const missing = [];

  if (!value.grafanaUrl) missing.push('GRAFANA_URL');
  if (!value.datasourceUid) missing.push('DATASOURCE_UID');
  if (!value.fromTimestamp) missing.push('FROM_TIMESTAMP');
  if (!value.toTimestamp) missing.push('TO_TIMESTAMP');

  const hasCookieAuth = Boolean(value.grafanaCookie);
  const hasHeaderAuth =
    Object.keys(value.additionalHeaders).some((headerName) =>
      ['authorization', 'x-api-key'].includes(headerName.toLowerCase())
    );
  const sessionExpiry = Number(getCookieValue(value.grafanaCookie, 'grafana_session_expiry'));

  if (!hasCookieAuth && !hasHeaderAuth) {
    missing.push('GRAFANA_SESSION or GRAFANA_COOKIE or auth inside GRAFANA_HEADERS_JSON');
  }

  if (Number.isFinite(sessionExpiry) && Date.now() / 1000 >= sessionExpiry) {
    throw new Error(
      'GRAFANA_COOKIE contains an expired grafana_session_expiry. Copy a fresh Cookie header from an active Grafana request.'
    );
  }

  if (missing.length > 0) {
    throw new Error(`Missing required configuration: ${missing.join(', ')}`);
  }
}

module.exports = {
  config,
  validateConfig
};
