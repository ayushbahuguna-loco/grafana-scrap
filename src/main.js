const fs = require('fs/promises');
const path = require('path');
const { config, validateConfig } = require('../config/config');
const { readCsv } = require('./csvReader');
const { updateCsvWithMetrics, writeCsv } = require('./csvWriter');
const { GrafanaClient } = require('./grafanaClient');
const { calculateMetrics } = require('./metricsCalculator');

async function ensureRuntimeDirectories(value) {
  await Promise.all([
    fs.mkdir(path.dirname(value.outputFile), { recursive: true }),
    fs.mkdir(path.dirname(value.summaryFile), { recursive: true }),
    fs.mkdir(path.dirname(value.missingOperationsFile), { recursive: true })
  ]);
}

async function writeTextFile(filePath, content) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, content, 'utf8');
}

async function processOperation(operation, grafanaClient) {
  const grafanaMetrics = await grafanaClient.fetchOperationMetrics(operation);
  const calculatedMetrics = calculateMetrics(grafanaMetrics);

  if (!calculatedMetrics) {
    throw new Error(`No usable P95/P99 datapoints returned for ${operation}`);
  }

  return calculatedMetrics;
}

async function runWithConcurrency(items, concurrency, worker) {
  const results = new Array(items.length);
  let nextIndex = 0;

  async function runWorker() {
    while (nextIndex < items.length) {
      const currentIndex = nextIndex;
      nextIndex += 1;

      results[currentIndex] = await worker(items[currentIndex], currentIndex);
    }
  }

  const workerCount = Math.max(1, Math.min(concurrency, items.length));
  await Promise.all(Array.from({ length: workerCount }, runWorker));

  return results;
}

async function main() {
  validateConfig(config);
  await ensureRuntimeDirectories(config);

  const csvContext = await readCsv(config.inputFile, config);
  const grafanaClient = new GrafanaClient(config);
  const metricsByOperation = new Map();
  const missingOperations = [];

  console.log(`Found ${csvContext.operations.length} distinct operations in CSV.`);
  console.log(`Using namespaces: ${config.namespaces.join(', ')}.`);
  if (config.lookbackMinutes > 0) {
    console.log(`Using rolling Grafana range: last ${config.lookbackMinutes} minutes.`);
  } else if (config.lookbackHours > 0) {
    console.log(`Using rolling Grafana range: last ${config.lookbackHours} hours.`);
  } else {
    console.log(`Using Grafana range: ${config.fromTimestamp} to ${config.toTimestamp}.`);
  }

  // Query Grafana once per distinct operation, then apply successful results to all matching rows.
  const operationResults = await runWithConcurrency(
    csvContext.operations,
    config.concurrency,
    async (operation) => {
      try {
        const metrics = await processOperation(operation, grafanaClient);
        return { operation, metrics };
      } catch (error) {
        return { operation, error };
      }
    }
  );

  for (const result of operationResults) {
    if (result.error) {
      missingOperations.push(result.operation);
      console.warn(result.error.message);
    } else {
      metricsByOperation.set(result.operation, result.metrics);
      console.log(`Updated metrics ready for ${result.operation}`);
    }
  }

  // The output CSV is a copy of the input CSV with only metric cells changed.
  const writeResult = updateCsvWithMetrics(csvContext, metricsByOperation);
  await writeCsv(csvContext.rows, config.outputFile);

  const summary = {
    processed: csvContext.operations.length,
    updated: metricsByOperation.size,
    missing: missingOperations.length,
    missingOperations
  };

  await writeTextFile(
    config.missingOperationsFile,
    missingOperations.length > 0 ? `${missingOperations.join('\n')}\n` : ''
  );
  await writeTextFile(config.summaryFile, `${JSON.stringify(summary, null, 2)}\n`);

  console.log(`Wrote ${config.outputFile}`);
  console.log(`Wrote ${config.summaryFile}`);
  console.log(`Wrote ${config.missingOperationsFile}`);
  console.log(`Updated ${writeResult.updatedRows} CSV rows.`);
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
