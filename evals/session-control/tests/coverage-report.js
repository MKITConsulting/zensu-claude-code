#!/usr/bin/env node
'use strict';

function parseCoverageRows(report) {
  if (typeof report !== 'string') {
    throw new TypeError('coverage report must be a string');
  }
  const rows = new Map();
  const hierarchy = [];
  for (const rawLine of report.split(/\r?\n/)) {
    const line = rawLine.replace(/^\s*(?:ℹ|#) ?/, '');
    const match = line.match(/^(\s*)([^|]+?)\s*\|\s*([^|]*)\|/);
    if (!match) continue;
    const indentation = match[1].length;
    const name = match[2].trim();
    const lineCoverage = match[3].trim();
    hierarchy.length = indentation;
    hierarchy[indentation] = name;
    if (!/^[0-9]+(?:\.[0-9]+)?$/.test(lineCoverage)) continue;
    const fullPath = hierarchy.slice(0, indentation + 1).join('/');
    if (!rows.has(fullPath)) rows.set(fullPath, []);
    rows.get(fullPath).push(Number(lineCoverage));
  }
  return rows;
}

module.exports = {
  parseCoverageRows,
};
