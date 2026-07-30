#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const SOURCE_PATH = path.join(__dirname, 'test-deferred-review-claim.sh');
const PREFLIGHT_START = 'PID_WIRING_OK=';
const FOOTER_START = 'echo "----"';

class CaseSelectionError extends Error {}

function uniqueCheckId(block, label) {
  const matches = [...block.matchAll(/check "([A-Za-z0-9-]+)/g)].map((match) => match[1]);
  const ids = [...new Set(matches)];
  if (ids.length !== 1) {
    throw new CaseSelectionError(
      `${label} must contain exactly one unique check id, found: ${ids.join(', ') || 'none'}`,
    );
  }
  return ids[0];
}

function discoverCases(source) {
  if (typeof source !== 'string' || source.length === 0) {
    throw new CaseSelectionError('deferred-review source must be non-empty text');
  }
  const lines = source.split('\n');
  const preflightIndex = lines.findIndex((line) => line.startsWith(PREFLIGHT_START));
  const footerIndex = lines.findIndex((line) => line === FOOTER_START);
  const setupIndices = [];
  for (let index = 0; index < lines.length; index += 1) {
    if (/^setup_case [A-Za-z0-9_]+(?: |$)/.test(lines[index])) setupIndices.push(index);
  }
  if (preflightIndex < 1 || footerIndex < 0 || setupIndices.length === 0) {
    throw new CaseSelectionError('deferred-review source boundaries are incomplete');
  }
  if (preflightIndex >= setupIndices[0] || footerIndex <= setupIndices.at(-1)) {
    throw new CaseSelectionError('deferred-review source boundaries are out of order');
  }

  const starts = [preflightIndex, ...setupIndices];
  const cases = starts.map((start, index) => {
    const end = index + 1 < starts.length ? starts[index + 1] : footerIndex;
    const block = lines.slice(start, end).join('\n');
    return Object.freeze({
      id: uniqueCheckId(block, index === 0 ? 'preflight block' : `case block at line ${start + 1}`),
      start,
      end,
      block,
    });
  });
  const ids = cases.map(({ id }) => id);
  if (new Set(ids).size !== ids.length) {
    throw new CaseSelectionError('deferred-review source contains duplicate case ids');
  }
  return Object.freeze(cases);
}

function parseRequestedCases(csv, available) {
  if (typeof csv !== 'string' || csv.length === 0) {
    throw new CaseSelectionError('case selection must not be empty');
  }
  const selected = csv.split(',');
  if (selected.some((id) => !id || id.trim() !== id)) {
    throw new CaseSelectionError('case selection must be a comma-separated list without spaces');
  }
  if (new Set(selected).size !== selected.length) {
    throw new CaseSelectionError('duplicate case id in selection');
  }
  for (const id of selected) {
    if (!available.has(id)) throw new CaseSelectionError(`unknown case id: ${id}`);
  }
  return selected;
}

function buildSelectedScript(source, selectedIds) {
  const cases = discoverCases(source);
  const available = new Set(cases.map(({ id }) => id));
  if (!Array.isArray(selectedIds) || selectedIds.length === 0) {
    throw new CaseSelectionError('selected case list must not be empty');
  }
  if (new Set(selectedIds).size !== selectedIds.length) {
    throw new CaseSelectionError('duplicate case id in selection');
  }
  for (const id of selectedIds) {
    if (!available.has(id)) throw new CaseSelectionError(`unknown case id: ${id}`);
  }
  const lines = source.split('\n');
  const preflightIndex = cases[0].start;
  const footerIndex = lines.findIndex((line) => line === FOOTER_START);
  const selected = new Set(selectedIds);
  const blocks = cases.filter(({ id }) => selected.has(id)).map(({ block }) => block);
  return [
    lines.slice(0, preflightIndex).join('\n'),
    ...blocks,
    lines.slice(footerIndex).join('\n'),
  ].join('\n');
}

function exitCodeFor(result) {
  if (Number.isInteger(result.status)) return result.status;
  const signals = { SIGHUP: 129, SIGINT: 130, SIGTERM: 143 };
  return signals[result.signal] || 1;
}

function runScript(scriptPath) {
  const result = spawnSync('bash', [scriptPath], {
    cwd: path.resolve(__dirname, '..', '..'),
    env: process.env,
    stdio: 'inherit',
    windowsHide: true,
  });
  if (result.error) throw result.error;
  return exitCodeFor(result);
}

function main({
  argv = process.argv.slice(2),
  sourcePath = SOURCE_PATH,
  stdout = process.stdout,
  runScriptFn = runScript,
} = {}) {
  const source = fs.readFileSync(sourcePath, 'utf8');
  const cases = discoverCases(source);
  const available = new Set(cases.map(({ id }) => id));
  const [mode, value, ...extra] = argv;
  if (mode === '--list-cases' && value === undefined && extra.length === 0) {
    stdout.write(`${cases.map(({ id }) => id).join('\n')}\n`);
    return 0;
  }
  if (mode === '--all' && value === undefined && extra.length === 0) {
    return runScriptFn(sourcePath);
  }
  if (mode !== '--cases' || typeof value !== 'string' || extra.length > 0) {
    throw new CaseSelectionError(
      'usage: test-deferred-review-claim.sh --list-cases|--all|--cases <id,id,...>',
    );
  }
  const selected = parseRequestedCases(value, available);
  const generated = buildSelectedScript(source, selected);
  const temporary = path.join(
    path.dirname(sourcePath),
    `.deferred-review-claim-${process.pid}-${crypto.randomBytes(6).toString('hex')}.sh`,
  );
  fs.writeFileSync(temporary, generated, { mode: 0o700, flag: 'wx' });
  try {
    return runScriptFn(temporary);
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

if (require.main === module) {
  try {
    process.exitCode = main();
  } catch (error) {
    if (!(error instanceof CaseSelectionError)) throw error;
    process.stderr.write(`deferred-review case selection error: ${error.message}\n`);
    process.exitCode = 2;
  }
}

module.exports = {
  CaseSelectionError,
  buildSelectedScript,
  discoverCases,
  exitCodeFor,
  main,
  parseRequestedCases,
  runScript,
};
