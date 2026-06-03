const fs = require('fs/promises');
const path = require('path');

async function ensureDirectoryForFile(filePath) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
}

function escapeCsvField(value) {
  const text = value === null || value === undefined ? '' : String(value);

  if (/[",\r\n]/.test(text)) {
    return `"${text.replace(/"/g, '""')}"`;
  }

  return text;
}

function serializeCsv(rows) {
  return `${rows.map((row) => row.map(escapeCsvField).join(',')).join('\n')}\n`;
}

function setCsvCell(row, columnIndex, value) {
  while (row.length <= columnIndex) {
    row.push('');
  }

  row[columnIndex] = value;
}

function writeMetricsToRow(row, columns, metrics) {
  // Only the configured metric columns are touched; all other CSV cells stay as-is.
  setCsvCell(row, columns.p95Mean, metrics.p95Mean);
  setCsvCell(row, columns.p95Max, metrics.p95Max);
  setCsvCell(row, columns.p99Mean, metrics.p99Mean);
  setCsvCell(row, columns.p99Max, metrics.p99Max);
}

function updateCsvWithMetrics(csvContext, metricsByOperation) {
  let updatedRows = 0;
  const updatedOperations = [];

  for (const [operation, rowIndexes] of csvContext.rowsByOperation.entries()) {
    const metrics = metricsByOperation.get(operation);

    if (!metrics) {
      continue;
    }

    for (const rowIndex of rowIndexes) {
      writeMetricsToRow(csvContext.rows[rowIndex], csvContext.columns, metrics);
      updatedRows += 1;
    }

    updatedOperations.push(operation);
  }

  return {
    updatedRows,
    updatedOperations
  };
}

async function writeCsv(rows, outputFile) {
  await ensureDirectoryForFile(outputFile);
  await fs.writeFile(outputFile, serializeCsv(rows), 'utf8');
}

module.exports = {
  serializeCsv,
  updateCsvWithMetrics,
  writeCsv
};
