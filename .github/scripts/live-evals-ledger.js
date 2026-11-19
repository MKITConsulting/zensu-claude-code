'use strict';

const fs = require('node:fs');
const path = require('node:path');
const usage = require('../../scripts/eval-usage-ledger.js');

const CREDENTIALS = ['CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_API_KEY'];
const MIN_SECRET_LENGTH = 8;
const ASSERT_FAILURE = 1;
const NOFOLLOW = Number.isInteger(fs.constants.O_NOFOLLOW) ? fs.constants.O_NOFOLLOW : 0;
const NONBLOCK = Number.isInteger(fs.constants.O_NONBLOCK) ? fs.constants.O_NONBLOCK : 0;

function fail(message) {
  process.stderr.write(`live-evals-ledger: ${message}\n`);
  process.exit(2);
}

function oneLine(text) {
  return String(text).replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 200);
}

function readLedger(file, offset = 0) {
  if (!file || !path.isAbsolute(file)) fail('the ledger path must be absolute');
  let buffer = Buffer.alloc(0);
  try {
    buffer = fs.readFileSync(file);
  } catch (error) {
    if (error.code !== 'ENOENT') fail(`cannot read the ledger: ${error.code || error.message}`);
  }
  const records = [];
  for (const line of buffer.subarray(Math.min(offset, buffer.length)).toString('utf8').split('\n')) {
    if (!line.trim()) continue;
    try {
      const record = JSON.parse(line);
      if (record && record.schema === usage.SCHEMA && usage.SUITE_NAME.test(String(record.suite))) records.push(record);
    } catch (_) {
      continue;
    }
  }
  return records;
}

function failedCall(record) {
  return record.exit !== 0 || record.result !== true || record.is_error === true;
}

function classifyRows(rows) {
  const counts = { passed: 0, asserts_failed: 0, limit_rows: 0, errors: 0 };
  for (const row of rows) {
    if (!row || typeof row !== 'object') {
      counts.errors += 1;
      continue;
    }
    if (row.success === true) {
      counts.passed += 1;
      continue;
    }
    const output = row.response && typeof row.response.output === 'string' ? row.response.output : '';
    const error = typeof row.error === 'string' ? row.error : '';
    const asserted = row.failureReason === ASSERT_FAILURE;
    if (usage.LIMIT_TEXT.test(asserted ? output : error)) counts.limit_rows += 1;
    else if (asserted) counts.asserts_failed += 1;
    else counts.errors += 1;
  }
  return counts;
}

function blank() {
  return { calls: 0, failed: 0, limitHits: 0, turns: 0, input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0 };
}

function add(sum, record) {
  sum.calls += 1;
  if (failedCall(record)) sum.failed += 1;
  if (record.limit_hit === true) sum.limitHits += 1;
  sum.turns += usage.count(record.num_turns);
  sum.input += usage.count(record.input_tokens);
  sum.output += usage.count(record.output_tokens);
  sum.cacheRead += usage.count(record.cache_read_input_tokens);
  sum.cacheWrite += usage.count(record.cache_creation_input_tokens);
  sum.cost += usage.count(record.cost_usd);
}

function row(name, sum) {
  const n = (value) => Math.round(value).toLocaleString('en-US');
  return `| ${name} | ${sum.calls} | ${sum.failed} | ${sum.limitHits} | ${n(sum.turns)} | ${n(sum.input)} | `
    + `${n(sum.output)} | ${n(sum.cacheRead)} | ${n(sum.cacheWrite)} | $${sum.cost.toFixed(4)} |`;
}

function summaryLines(records) {
  if (!records.length) return ['No eval calls were recorded.'];
  const suites = new Map();
  const total = blank();
  for (const record of records) {
    if (!suites.has(record.suite)) suites.set(record.suite, blank());
    add(suites.get(record.suite), record);
    add(total, record);
  }
  const lines = [
    '| Suite | Calls | Failed calls | Usage-limit hits | Turns | Input tokens | Output tokens | Cache read | Cache write | Est. USD |',
    '|---|---|---|---|---|---|---|---|---|---|',
  ];
  for (const [name, sum] of suites) lines.push(row(name, sum));
  lines.push(row('**Total**', total));
  const models = [...new Set(records.flatMap((record) => (Array.isArray(record.models) ? record.models : [])))]
    .filter((model) => /^[A-Za-z0-9._:\[\]-]{1,80}$/.test(model))
    .sort();
  lines.push('');
  lines.push(`Models seen: ${models.length ? models.map((model) => `\`${model}\``).join(', ') : 'none'}.`);
  lines.push('Est. USD is the `total_cost_usd` Claude Code reports, computed at API list prices.');
  return lines;
}

function probe([stream]) {
  if (!stream) fail('usage: probe <stream-json file>');
  const d = usage.digest(usage.readEvents(stream));
  let verdict = 'error';
  if (d.limitHit) verdict = 'limit';
  else if (d.hasResult && !d.isError) verdict = 'ready';
  const reason = d.reason || (d.hasResult ? '' : 'the probe printed no result event');
  process.stdout.write(`verdict=${verdict}\nreason=${oneLine(reason)}\n`);
}

function tally([ledger, suite, offset]) {
  if (!usage.SUITE_NAME.test(suite || '')) fail('usage: tally <ledger file> <suite> [byte offset]');
  if (offset !== undefined && !/^[0-9]{1,15}$/.test(offset)) fail('the byte offset must be a whole number');
  const records = readLedger(ledger, Number(offset || 0)).filter((record) => record.suite === suite);
  const limitHits = records.filter((record) => record.limit_hit === true).length;
  process.stdout.write(`calls=${records.length}\nlimit_hits=${limitHits}\n`);
}

function summarize([ledger]) {
  process.stdout.write(`${summaryLines(readLedger(ledger)).join('\n')}\n`);
}

function results([file]) {
  if (!file || !path.isAbsolute(file)) fail('usage: results <absolute promptfoo results file>');
  let rows = null;
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (parsed && parsed.results && Array.isArray(parsed.results.results)) rows = parsed.results.results;
  } catch (_) {
    rows = null;
  }
  const counts = classifyRows(rows || []);
  process.stdout.write(`results=${rows ? 'read' : 'missing'}\n`
    + Object.entries(counts).map(([key, value]) => `${key}=${value}`).join('\n') + '\n');
}

function readRegular(file) {
  const fd = fs.openSync(file, fs.constants.O_RDONLY | NOFOLLOW | NONBLOCK);
  try {
    if (!fs.fstatSync(fd).isFile()) return null;
    return fs.readFileSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

function stage([src, dest]) {
  if (!src || !dest || !path.isAbsolute(src) || !path.isAbsolute(dest)) {
    fail('usage: stage <absolute results directory> <absolute upload directory>');
  }
  const from = path.resolve(src);
  const to = path.resolve(dest);
  const inside = (parent, child) => {
    const relative = path.relative(parent, child);
    return relative === '' || !(relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative));
  };
  if (inside(from, to) || inside(to, from)) fail('the upload directory must lie outside the results directory');
  const secrets = CREDENTIALS
    .map((name) => process.env[name])
    .filter((value) => typeof value === 'string' && value.length >= MIN_SECRET_LENGTH);
  try {
    fs.mkdirSync(to, { mode: 0o700 });
  } catch (error) {
    fail(`cannot create the upload directory: ${error.code || error.message}`);
  }
  const removed = [];
  const refused = [];
  const walk = (source, target) => {
    let entries;
    try {
      entries = fs.readdirSync(source, { withFileTypes: true });
    } catch (error) {
      if (error.code === 'ENOENT' && source === from) return;
      refused.push(`${path.relative(from, source) || '.'} (${error.code || 'unreadable'})`);
      return;
    }
    for (const entry of entries) {
      const sourceEntry = path.join(source, entry.name);
      const targetEntry = path.join(target, entry.name);
      const name = path.relative(from, sourceEntry);
      if (entry.isSymbolicLink()) {
        removed.push(`${name} (symbolic link)`);
      } else if (entry.isDirectory()) {
        try {
          fs.mkdirSync(targetEntry, { mode: 0o700 });
          walk(sourceEntry, targetEntry);
        } catch (error) {
          refused.push(`${name} (${error.code || 'unwritable'})`);
        }
      } else if (!entry.isFile()) {
        removed.push(`${name} (not a regular file)`);
      } else {
        try {
          const body = readRegular(sourceEntry);
          if (body === null) removed.push(`${name} (not a regular file)`);
          else if (secrets.some((secret) => body.includes(secret))) removed.push(`${name} (held a credential value)`);
          else fs.writeFileSync(targetEntry, body, { mode: 0o600, flag: 'wx' });
        } catch (error) {
          refused.push(`${name} (${error.code || 'unreadable'})`);
        }
      }
    }
  };
  walk(from, to);
  const report = [
    ...removed.map((name) => `removed=${name}`),
    ...refused.map((name) => `refused=${name}`),
  ];
  if (!refused.length) report.push('staged=complete');
  process.stdout.write(`${report.join('\n')}\n`);
  if (refused.length) process.exitCode = 2;
  else process.exitCode = removed.length ? 1 : 0;
}

const COMMANDS = { probe, tally, summarize, results, stage };

if (require.main === module) {
  const [command, ...args] = process.argv.slice(2);
  if (!Object.prototype.hasOwnProperty.call(COMMANDS, command)) {
    fail('usage: live-evals-ledger.js probe|tally|summarize|results|stage ...');
  }
  COMMANDS[command](args);
}

module.exports = { readLedger, classifyRows, summaryLines };
