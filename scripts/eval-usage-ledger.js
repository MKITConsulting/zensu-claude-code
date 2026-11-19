'use strict';

const fs = require('node:fs');
const path = require('node:path');

const SCHEMA = 'zensu-eval-usage-v1';
const LIMIT_TEXT = /\bhit your\b[^\n]{0,60}\blimit\b|\busage limit\b/i;
const SUITE_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

function fail(message) {
  process.stderr.write(`eval-usage-ledger: ${message}\n`);
  process.exit(2);
}

function readEvents(file) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (error) {
    fail(`cannot read ${path.basename(file)}: ${error.code || error.message}`);
  }
  const events = [];
  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed.startsWith('{')) continue;
    try {
      const value = JSON.parse(trimmed);
      if (value && typeof value === 'object' && !Array.isArray(value)) events.push(value);
    } catch (_) {
      continue;
    }
  }
  return events;
}

function textOf(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content
    .map((block) => (block && block.type === 'text' && typeof block.text === 'string' ? block.text : ''))
    .join(' ');
}

function count(value) {
  return Number.isFinite(value) && value >= 0 ? value : 0;
}

function digest(events) {
  let result = null;
  const synthetic = [];
  const models = new Set();
  for (const event of events) {
    if (event.type === 'result') result = event;
    if (event.type === 'assistant' && event.message && typeof event.message === 'object') {
      const model = event.message.model;
      if (model === '<synthetic>') synthetic.push(textOf(event.message.content));
      else if (typeof model === 'string' && model) models.add(model);
    }
  }
  if (result && result.modelUsage && typeof result.modelUsage === 'object') {
    for (const model of Object.keys(result.modelUsage)) models.add(model);
  }
  const resultText = result && typeof result.result === 'string' ? result.result : '';
  const isError = Boolean(result && result.is_error === true);
  const limitText = synthetic.find((text) => LIMIT_TEXT.test(text))
    || (isError && LIMIT_TEXT.test(resultText) ? resultText : '');
  const usage = result && result.usage && typeof result.usage === 'object' ? result.usage : {};
  return {
    hasResult: Boolean(result),
    isError,
    limitHit: Boolean(limitText),
    reason: limitText || resultText || synthetic.join(' '),
    costUsd: count(result && result.total_cost_usd),
    durationMs: count(result && result.duration_ms),
    turns: count(result && result.num_turns),
    inputTokens: count(usage.input_tokens),
    outputTokens: count(usage.output_tokens),
    cacheReadTokens: count(usage.cache_read_input_tokens),
    cacheWriteTokens: count(usage.cache_creation_input_tokens),
    models: [...models].sort(),
  };
}

function openLedger(file) {
  if (!file || !path.isAbsolute(file)) fail('the ledger path must be absolute');
  const flags = fs.constants.O_WRONLY | fs.constants.O_APPEND | fs.constants.O_CREAT
    | (Number.isInteger(fs.constants.O_NOFOLLOW) ? fs.constants.O_NOFOLLOW : 0);
  try {
    const fd = fs.openSync(file, flags, 0o600);
    if (!fs.fstatSync(fd).isFile()) {
      fs.closeSync(fd);
      fail('the ledger path must name a regular file');
    }
    return fd;
  } catch (error) {
    fail(`cannot open the ledger: ${error.code || error.message}`);
  }
  return -1;
}

function append([stream, ledger, suite, exitCode]) {
  if (!stream || !ledger) fail('usage: append <stream-json file> <ledger file> <suite> <exit code>');
  if (!SUITE_NAME.test(suite || '')) fail('the suite name must be a short token');
  const exit = /^-?[0-9]{1,3}$/.test(String(exitCode)) ? Number(exitCode) : -1;
  const d = digest(readEvents(stream));
  const record = {
    schema: SCHEMA,
    suite,
    exit,
    result: d.hasResult,
    is_error: d.isError,
    limit_hit: d.limitHit,
    cost_usd: d.costUsd,
    duration_ms: d.durationMs,
    num_turns: d.turns,
    input_tokens: d.inputTokens,
    output_tokens: d.outputTokens,
    cache_read_input_tokens: d.cacheReadTokens,
    cache_creation_input_tokens: d.cacheWriteTokens,
    models: d.models,
  };
  const fd = openLedger(ledger);
  try {
    fs.writeSync(fd, `${JSON.stringify(record)}\n`);
  } finally {
    fs.closeSync(fd);
  }
}

if (require.main === module) {
  const [command, ...args] = process.argv.slice(2);
  if (command !== 'append') fail('usage: eval-usage-ledger.js append <stream-json file> <ledger file> <suite> <exit code>');
  append(args);
}

module.exports = { SCHEMA, LIMIT_TEXT, SUITE_NAME, count, readEvents, digest };
