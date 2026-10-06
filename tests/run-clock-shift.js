#!/usr/bin/env node
'use strict';

const childProcess = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..');
const PRELOAD = path.join(__dirname, 'lib', 'clock-shift.cjs');
const REPORTER = path.join(__dirname, 'lib', 'clock-shift-reporter.cjs');
const DEFAULT_ALLOWLIST = path.join(__dirname, 'profiles', 'clock-shift-allowlist.v1.json');
const SHIFT_VARIABLE = 'ZENSU_TEST_CLOCK_SHIFT_DAYS';
const DEPENDENCIES = Object.freeze(['file-mtime', 'git-date', 'lease-staleness']);
const ALLOWLIST_KEYS = Object.freeze(['entries', 'schemaVersion', 'shiftDays']);
const ENTRY_KEYS = Object.freeze(['dependency', 'file', 'reason', 'test']);
const ENTRY_FILE = /^(?:[A-Za-z0-9_-][A-Za-z0-9._-]*\/)*[A-Za-z0-9_-][A-Za-z0-9._-]*\.test\.js$/;
const MIN_REASON = 20;
const MAX_TEST_NAME = 300;

class ClockShiftError extends Error {}

function keyOf(file, test) {
  return JSON.stringify([file, test]);
}

function sameKeys(value, expected) {
  return JSON.stringify(Object.keys(value).sort()) === JSON.stringify(expected);
}

function validateAllowlist(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || !sameKeys(value, ALLOWLIST_KEYS)) {
    throw new ClockShiftError(`the allowlist must be an object with exactly the keys ${ALLOWLIST_KEYS.join(', ')}`);
  }
  if (value.schemaVersion !== 1) throw new ClockShiftError('the allowlist schemaVersion must be 1');
  if (!Number.isInteger(value.shiftDays) || value.shiftDays < 1) {
    throw new ClockShiftError('the allowlist shiftDays must be a positive whole number of days');
  }
  if (!Array.isArray(value.entries)) throw new ClockShiftError('the allowlist entries must be an array');
  const seen = new Set();
  value.entries.forEach((entry, index) => {
    const where = `allowlist entry ${index}`;
    if (!entry || typeof entry !== 'object' || Array.isArray(entry) || !sameKeys(entry, ENTRY_KEYS)) {
      throw new ClockShiftError(`${where} must have exactly the keys ${ENTRY_KEYS.join(', ')}`);
    }
    if (typeof entry.file !== 'string' || !ENTRY_FILE.test(entry.file)) {
      throw new ClockShiftError(`${where} must name a relative *.test.js path without dot segments`);
    }
    if (typeof entry.test !== 'string' || entry.test.trim() === '' || entry.test.length > MAX_TEST_NAME) {
      throw new ClockShiftError(`${where} must name a top-level test of at most ${MAX_TEST_NAME} characters`);
    }
    if (!DEPENDENCIES.includes(entry.dependency)) {
      throw new ClockShiftError(`${where} dependency must be one of ${DEPENDENCIES.join(', ')}`);
    }
    if (typeof entry.reason !== 'string' || entry.reason.trim().length < MIN_REASON) {
      throw new ClockShiftError(`${where} must give a reason of at least ${MIN_REASON} characters`);
    }
    const key = keyOf(entry.file, entry.test);
    if (seen.has(key)) throw new ClockShiftError(`${where} repeats ${entry.file} > ${entry.test}`);
    seen.add(key);
  });
  return value;
}

function loadAllowlist(file) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (error) {
    throw new ClockShiftError(`cannot read the allowlist ${file}: ${error.message}`);
  }
  let value;
  try {
    value = JSON.parse(text);
  } catch (error) {
    throw new ClockShiftError(`the allowlist ${file} is not valid JSON: ${error.message}`);
  }
  return validateAllowlist(value);
}

function canonical(file) {
  try {
    return fs.realpathSync(file);
  } catch {
    return path.resolve(file);
  }
}

function relativeFile(root, file) {
  const relative = path.relative(root, file);
  if (relative === '' || relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new ClockShiftError(`${file} is not inside ${root}`);
  }
  return relative.split(path.sep).join('/');
}

const RANK = Object.freeze({ fail: 3, pass: 2, skip: 1, todo: 1 });

function collectOutcomes(lines, root, files) {
  const byPath = new Map(files.map((file) => [canonical(file), relativeFile(root, file)]));
  const results = new Map();
  const seenFiles = new Set();
  for (const line of lines) {
    if (line.trim() === '') continue;
    const event = JSON.parse(line);
    const reported = typeof event.file === 'string' ? canonical(path.resolve(root, event.file)) : null;
    const file = reported === null ? null : byPath.get(reported);
    if (file === undefined || file === null) {
      throw new ClockShiftError(`node --test reported a result for a file outside this run: ${event.file}`);
    }
    seenFiles.add(file);
    const fileLevel = canonical(path.resolve(root, event.name)) === reported;
    const test = fileLevel ? null : event.name;
    if (fileLevel && event.outcome !== 'fail') continue;
    const key = keyOf(file, test);
    const previous = results.get(key);
    if (!previous || RANK[event.outcome] > RANK[previous.outcome]) {
      results.set(key, { file, test, outcome: event.outcome, message: event.message || null });
    }
  }
  return { results, seenFiles };
}

function judge(allowlist, collected, runFiles, partial) {
  const entries = new Map(allowlist.entries.map((entry) => [keyOf(entry.file, entry.test), entry]));
  const allowed = [];
  const unexpected = [];
  const stale = [];
  const unexercised = [];
  for (const result of collected.results.values()) {
    if (result.outcome !== 'fail') continue;
    const entry = result.test === null ? undefined : entries.get(keyOf(result.file, result.test));
    if (entry) allowed.push({ file: result.file, test: result.test, dependency: entry.dependency });
    else unexpected.push({ file: result.file, test: result.test, message: result.message });
  }
  for (const file of runFiles) {
    if (!collected.seenFiles.has(file)) unexpected.push({ file, test: null, message: 'the file reported no test result' });
  }
  const inRun = new Set(runFiles);
  for (const entry of allowlist.entries) {
    if (!inRun.has(entry.file)) {
      if (!partial) stale.push({ file: entry.file, test: entry.test, why: 'its file is not one of the unit files this run covers' });
      continue;
    }
    const result = collected.results.get(keyOf(entry.file, entry.test));
    if (!result) stale.push({ file: entry.file, test: entry.test, why: 'no top-level test of this name ran' });
    else if (result.outcome === 'pass') stale.push({ file: entry.file, test: entry.test, why: 'it passes under the shifted clock' });
    else if (result.outcome !== 'fail') unexercised.push({ file: entry.file, test: entry.test, outcome: result.outcome });
  }
  return { allowed, unexpected, stale, unexercised };
}

function childEnvironment(environment, shiftDays) {
  const inherited = typeof environment.NODE_OPTIONS === 'string' && environment.NODE_OPTIONS.trim() !== ''
    ? `${environment.NODE_OPTIONS} `
    : '';
  const child = {
    ...environment,
    NODE_OPTIONS: `${inherited}--require ${JSON.stringify(PRELOAD)}`,
    [SHIFT_VARIABLE]: String(shiftDays),
  };
  delete child.NODE_TEST_CONTEXT;
  return child;
}

function parseArgs(argv) {
  const options = { allowlist: DEFAULT_ALLOWLIST, root: ROOT, summary: null, files: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--allowlist' || argument === '--root' || argument === '--summary') {
      const value = argv[index + 1];
      if (value === undefined || value === '') throw new ClockShiftError(`${argument} needs a value`);
      options[argument.slice(2)] = path.resolve(value);
      index += 1;
    } else if (argument.startsWith('-')) {
      throw new ClockShiftError(`unknown option ${argument}; usage: run-clock-shift.js [--allowlist <file>] [--root <dir>] [--summary <file>] [<unit file>...]`);
    } else {
      options.files.push(path.resolve(argument));
    }
  }
  return options;
}

function defaultFiles(root) {
  const directory = path.join(root, 'tests', 'structure');
  return fs.readdirSync(directory).filter((name) => name.endsWith('.test.js')).sort().map((name) => path.join(directory, name));
}

function label(item) {
  return item.test === null ? `${item.file} (file)` : `${item.file} > ${item.test}`;
}

function render(verdict, context) {
  const lines = [`clock-shift: shifted Date by ${context.shiftDays} days for ${context.files} unit files on node ${process.version}; allowlist ${context.allowlist} (${context.entries} entries)`];
  for (const item of verdict.allowed) lines.push(`clock-shift: ALLOWED ${label(item)} [${item.dependency}]`);
  for (const item of verdict.unexercised) lines.push(`clock-shift: UNEXERCISED ${label(item)} (${item.outcome})`);
  for (const item of verdict.unexpected) lines.push(`clock-shift: FAILED ${label(item)}${item.message ? ` — ${item.message}` : ''}`);
  for (const item of verdict.stale) lines.push(`clock-shift: STALE ${label(item)} — ${item.why}; remove or correct its allowlist entry`);
  if (verdict.unexpected.length === 0 && verdict.stale.length === 0) {
    lines.push(`clock-shift: PASS — no failure outside the allowlist and no stale entry (${verdict.allowed.length} allowed)`);
  } else {
    lines.push(`clock-shift: FAIL — ${verdict.unexpected.length} failure(s) outside the allowlist, ${verdict.stale.length} stale allowlist entr${verdict.stale.length === 1 ? 'y' : 'ies'}`);
  }
  return `${lines.join('\n')}\n`;
}

function run(options) {
  const allowlist = loadAllowlist(options.allowlist);
  const root = canonical(options.root);
  const partial = options.files.length > 0;
  const files = (partial ? options.files : defaultFiles(root)).map(canonical);
  if (files.length === 0) throw new ClockShiftError('no unit files to run');
  const runFiles = files.map((file) => relativeFile(root, file));
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-clock-shift-'));
  try {
    const events = path.join(scratch, 'events.jsonl');
    const child = childProcess.spawnSync(process.execPath, [
      '--test',
      `--test-reporter=${REPORTER}`,
      `--test-reporter-destination=${events}`,
      '--test-reporter=spec',
      '--test-reporter-destination=stdout',
      ...files,
    ], { cwd: root, env: childEnvironment(process.env, allowlist.shiftDays), stdio: ['ignore', 'inherit', 'inherit'] });
    if (child.error) throw new ClockShiftError(`node --test could not start: ${child.error.message}`);
    if (!fs.existsSync(events)) throw new ClockShiftError(`node --test exited ${child.status} without writing its results`);
    const collected = collectOutcomes(fs.readFileSync(events, 'utf8').split('\n'), root, files);
    const failed = [...collected.results.values()].some((result) => result.outcome === 'fail');
    if (child.status !== 0 && !failed) {
      throw new ClockShiftError(`node --test exited ${child.status ?? child.signal} without reporting a failed test`);
    }
    const verdict = judge(allowlist, collected, runFiles, partial);
    const context = {
      shiftDays: allowlist.shiftDays,
      files: files.length,
      allowlist: relativeOrAbsolute(options.allowlist),
      entries: allowlist.entries.length,
    };
    process.stdout.write(render(verdict, context));
    if (options.summary) {
      fs.writeFileSync(options.summary, `${JSON.stringify({ schemaVersion: 1, ...context, node: process.version, ...verdict }, null, 2)}\n`);
    }
    return verdict.unexpected.length === 0 && verdict.stale.length === 0 ? 0 : 1;
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

function relativeOrAbsolute(file) {
  const relative = path.relative(ROOT, file);
  return relative.startsWith('..') || path.isAbsolute(relative) ? file : relative.split(path.sep).join('/');
}

function main(argv = process.argv.slice(2)) {
  try {
    return run(parseArgs(argv));
  } catch (error) {
    process.stderr.write(`clock-shift: ${error instanceof ClockShiftError ? error.message : error.stack || error}\n`);
    return 2;
  }
}

if (require.main === module) {
  process.exitCode = main();
}

module.exports = {
  ClockShiftError,
  DEPENDENCIES,
  PRELOAD,
  SHIFT_VARIABLE,
  childEnvironment,
  collectOutcomes,
  judge,
  loadAllowlist,
  main,
  parseArgs,
  validateAllowlist,
};
