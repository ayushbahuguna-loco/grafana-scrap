const axios = require('axios');

function escapePrometheusLabelValue(value) {
  return String(value)
    .replace(/\\/g, '\\\\')
    .replace(/\n/g, '\\n')
    .replace(/"/g, '\\"');
}

function escapeRegexValue(value) {
  return String(value).replace(/[\\^$.*+?()[\]{}|]/g, '\\$&');
}

function buildNamespaceMatcher(config) {
  const namespaces = Array.isArray(config.namespaces) && config.namespaces.length > 0
    ? config.namespaces
    : [config.namespace];

  if (namespaces.length === 1) {
    return `namespace="${escapePrometheusLabelValue(namespaces[0])}"`;
  }

  const namespaceRegex = namespaces.map(escapeRegexValue).join('|');
  return `namespace=~"^(${namespaceRegex})$"`;
}

function buildLatencyQuery(quantile, operation, config) {
  const operationName = escapePrometheusLabelValue(operation);
  const namespaceMatcher = buildNamespaceMatcher(config);
  const clusterMatcher = config.cluster
    ? `\n        cluster="${escapePrometheusLabelValue(config.cluster)}",`
    : '';
  const divisor = Number(config.valueDivisor);
  const divisorSuffix = Number.isFinite(divisor) && divisor !== 1 ? ` / ${divisor}` : '';

  return `histogram_quantile(
  ${quantile},
  sum(
    rate(
      {
        __name__=~".*requests_bucket",${clusterMatcher}
        ${namespaceMatcher},
        operation="${operationName}"
      }[${config.rateWindow}]
    )
  ) by (le)
)${divisorSuffix}`;
}

function buildGrafanaQuery(refId, expr, config) {
  return {
    refId,
    datasource: {
      type: 'prometheus',
      uid: config.datasourceUid
    },
    editorMode: 'code',
    expr,
    exemplar: false,
    instant: false,
    intervalMs: config.intervalMs,
    legendFormat: '',
    maxDataPoints: config.maxDataPoints,
    range: true,
    queryType: 'timeSeriesQuery'
  };
}

function buildGrafanaPayload(operation, config) {
  const payload = {
    from: String(config.fromTimestamp),
    to: String(config.toTimestamp),
    queries: [
      buildGrafanaQuery('P95', buildLatencyQuery(0.95, operation, config), config),
      buildGrafanaQuery('P99', buildLatencyQuery(0.99, operation, config), config)
    ]
  };

  // Grafana accepts dashboardUID as optional request context for /api/ds/query.
  if (config.dashboardUid) {
    payload.dashboardUID = config.dashboardUid;
  }

  return payload;
}

function buildHeaders(config) {
  return {
    Accept: 'application/json',
    'Content-Type': 'application/json',
    'X-Grafana-Org-Id': config.orgId,
    ...(config.grafanaCookie ? { Cookie: config.grafanaCookie } : {}),
    ...config.additionalHeaders
  };
}

function extractValues(responseData, refId) {
  const values = responseData?.results?.[refId]?.frames?.[0]?.data?.values?.[1];

  if (!Array.isArray(values)) {
    return [];
  }

  return values;
}

class GrafanaClient {
  constructor(config) {
    this.config = config;
    this.httpClient = axios.create({
      timeout: config.requestTimeoutMs,
      headers: buildHeaders(config)
    });
  }

  async fetchOperationMetrics(operation) {
    const payload = buildGrafanaPayload(operation, this.config);

    try {
      const response = await this.httpClient.post(this.config.grafanaUrl, payload);

      return {
        operation,
        p95Values: extractValues(response.data, 'P95'),
        p99Values: extractValues(response.data, 'P99')
      };
    } catch (error) {
      const status = error.response?.status;
      const statusText = error.response?.statusText;
      const responseMessage = error.response?.data?.message || error.response?.data?.error;
      const detail = status
        ? `HTTP ${status}${statusText ? ` ${statusText}` : ''}${responseMessage ? `: ${responseMessage}` : ''}`
        : error.message;

      throw new Error(`Grafana request failed for ${operation}: ${detail}`);
    }
  }
}

module.exports = {
  GrafanaClient,
  buildGrafanaPayload,
  buildLatencyQuery,
  buildNamespaceMatcher,
  extractValues
};
