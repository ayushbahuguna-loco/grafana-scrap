const fs = require('fs/promises');

function parseCsv(content) {
  const rows = [];
  let row = [];
  let field = '';
  let inQuotes = false;

  for (let index = 0; index < content.length; index += 1) {
    const char = content[index];
    const nextChar = content[index + 1];

    if (inQuotes) {
      if (char === '"' && nextChar === '"') {
        field += '"';
        index += 1;
      } else if (char === '"') {
        inQuotes = false;
      } else {
        field += char;
      }

      continue;
    }

    if (char === '"') {
      inQuotes = true;
    } else if (char === ',') {
      row.push(field);
      field = '';
    } else if (char === '\n') {
      row.push(field);
      rows.push(row);
      row = [];
      field = '';
    } else if (char !== '\r') {
      field += char;
    }
  }

  if (inQuotes) {
    throw new Error('Invalid CSV: found an unclosed quoted field.');
  }

  if (field !== '' || row.length > 0) {
    row.push(field);
    rows.push(row);
  }

  return rows;
}

function normalizeHeader(value) {
  return String(value).replace(/\s+/g, ' ').trim().toLowerCase();
}

function buildHeaderMap(headerRow) {
  const headerMap = new Map();

  headerRow.forEach((header, columnIndex) => {
    const text = String(header || '').trim();

    if (text) {
      headerMap.set(normalizeHeader(text), columnIndex);
    }
  });

  return headerMap;
}

function resolveColumn(headerMap, columnName) {
  const columnIndex = headerMap.get(normalizeHeader(columnName));

  if (columnIndex === undefined) {
    throw new Error(`Required column "${columnName}" was not found in the CSV header row.`);
  }

  return columnIndex;
}

async function readCsv(inputFile, config) {
  const content = (await fs.readFile(inputFile, 'utf8')).replace(/^\uFEFF/, '');
  const rows = parseCsv(content);
  const headerIndex = config.headerRow - 1;
  const headerRow = rows[headerIndex];

  if (!headerRow) {
    throw new Error(`CSV header row ${config.headerRow} was not found.`);
  }

  const headerMap = buildHeaderMap(headerRow);
  const operationColumn = resolveColumn(headerMap, config.operationColumn);
  const metricColumns = {
    p95Mean: resolveColumn(headerMap, config.metricColumns.p95Mean),
    p95Max: resolveColumn(headerMap, config.metricColumns.p95Max),
    p99Mean: resolveColumn(headerMap, config.metricColumns.p99Mean),
    p99Max: resolveColumn(headerMap, config.metricColumns.p99Max)
  };
  const rowsByOperation = new Map();

  // Operations are read from CSV only; no operation names are hardcoded.
  for (let rowIndex = headerIndex + 1; rowIndex < rows.length; rowIndex += 1) {
    const row = rows[rowIndex];
    const operation = String(row[operationColumn] || '').trim();

    if (!operation) {
      continue;
    }

    if (!rowsByOperation.has(operation)) {
      rowsByOperation.set(operation, []);
    }

    rowsByOperation.get(operation).push(rowIndex);
  }

  return {
    rows,
    rowsByOperation,
    operations: Array.from(rowsByOperation.keys()),
    columns: {
      operation: operationColumn,
      ...metricColumns
    }
  };
}

module.exports = {
  parseCsv,
  readCsv
};
