function roundToTwoDecimals(value) {
  return Math.round((value + Number.EPSILON) * 100) / 100;
}

function normalizeValues(values) {
  if (!Array.isArray(values)) {
    return [];
  }

  // Grafana/Prometheus can return null gaps; those should not count as zero latency.
  return values
    .filter((value) => value !== null && value !== undefined && value !== '')
    .map(Number)
    .filter(Number.isFinite);
}

function calculateSeriesStats(values) {
  const numericValues = normalizeValues(values);

  if (numericValues.length === 0) {
    return null;
  }

  const sum = numericValues.reduce((total, value) => total + value, 0);
  const mean = sum / numericValues.length;
  const max = Math.max(...numericValues);

  return {
    mean: roundToTwoDecimals(mean),
    max: roundToTwoDecimals(max)
  };
}

function calculateMetrics({ p95Values, p99Values }) {
  const p95 = calculateSeriesStats(p95Values);
  const p99 = calculateSeriesStats(p99Values);

  if (!p95 || !p99) {
    return null;
  }

  return {
    p95Mean: p95.mean,
    p95Max: p95.max,
    p99Mean: p99.mean,
    p99Max: p99.max
  };
}

module.exports = {
  calculateMetrics,
  calculateSeriesStats,
  roundToTwoDecimals
};
