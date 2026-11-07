'use strict';
const fs = require('node:fs');
const path = require('node:path');
const authState = require('./verify-auth-state-v1.js');

const GUARD_TOOLS = authState.AUTH_GUARD_TOOLS;
const GUARD_MATCHER = GUARD_TOOLS.join('|');
const SHELL_TOOLS = Object.freeze(['Bash', 'PowerShell']);
const PATH_FIELDS = Object.freeze({
  Read: Object.freeze(['file_path']),
  Edit: Object.freeze(['file_path']),
  Write: Object.freeze(['file_path']),
  MultiEdit: Object.freeze(['file_path']),
  NotebookEdit: Object.freeze(['notebook_path']),
  Grep: Object.freeze(['path']),
  Glob: Object.freeze(['path']),
});
const PATTERN_FIELDS = Object.freeze({ Grep: 'glob', Glob: 'pattern' });
const SEARCH_TOOLS = Object.freeze(['Grep', 'Glob']);
const MARKER = authState.RUNS_DIR_NAME;
const STATE_STEM = authState.STATE_FILE_NAME.replace(/\.json$/, '');
const MAX_BRACE_ALTERNATIVES = 64;
const REASONS = Object.freeze({
  PATH: 'path-inside-run-auth-directory',
  COMMAND: 'command-names-run-auth-directory',
  UNREADABLE: 'unreadable-payload-names-runs',
  CLEAN: 'clean',
  OTHER_TOOL: 'not-a-guarded-tool',
  UNMARKED: 'unreadable-payload-without-runs',
});

function decodedEscapes(text) {
  return text.replace(/\\u([0-9a-fA-F]{4})/g, (_match, hex) => String.fromCharCode(parseInt(hex, 16)));
}

function marked(raw) {
  if (typeof raw !== 'string' || raw === '') return false;
  return [raw, decodedEscapes(raw)].some((text) => {
    const lowered = text.toLowerCase();
    return lowered.includes(MARKER) || lowered.replace(/[`'"\\]/g, '').includes(MARKER);
  });
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');
}

function expandBraces(segment) {
  const open = segment.indexOf('{');
  if (open === -1) return [segment];
  const close = segment.indexOf('}', open + 1);
  if (close === -1) return [segment];
  const head = segment.slice(0, open);
  const tail = segment.slice(close + 1);
  const results = [];
  for (const alternative of segment.slice(open + 1, close).split(',')) {
    for (const rest of expandBraces(`${alternative}${tail}`)) {
      results.push(`${head}${rest}`);
      if (results.length > MAX_BRACE_ALTERNATIVES) return null;
    }
  }
  return results;
}

function globRegExp(glob) {
  let source = '';
  for (let index = 0; index < glob.length; index += 1) {
    const char = glob[index];
    if (char === '*') source += '.*';
    else if (char === '?') source += '.';
    else if (char === '[') {
      const end = glob.indexOf(']', index + 2);
      if (end === -1) {
        source += '\\[';
        continue;
      }
      let body = glob.slice(index + 1, end);
      if (body.startsWith('!')) body = `^${body.slice(1)}`;
      source += `[${body.replace(/\\/g, '\\\\')}]`;
      index = end;
    } else {
      source += escapeRegExp(char);
    }
  }
  return new RegExp(`^${source}$`);
}

function segmentMatches(segment, name) {
  if (!/[*?[{]/.test(segment)) return segment === name;
  const alternatives = expandBraces(segment);
  if (alternatives === null) return true;
  try {
    return alternatives.some((alternative) => globRegExp(alternative).test(name));
  } catch (_error) {
    return true;
  }
}

function reachesAuth(segments) {
  const resolved = [];
  for (const segment of segments) {
    if (segment === '..') {
      if (resolved.length === 0) return false;
      resolved.pop();
      continue;
    }
    resolved.push(segment);
  }
  if (resolved.slice(0, 2).some((segment) => segment.includes('**'))) return true;
  return resolved.length >= 2 && segmentMatches(resolved[1], authState.AUTH_DIR_NAME);
}

function namesAuthPath(text) {
  if (typeof text !== 'string' || text === '') return false;
  const lowered = text.toLowerCase().replace(/\\/g, '/');
  let from = 0;
  for (;;) {
    const at = lowered.indexOf(MARKER, from);
    if (at === -1) return false;
    from = at + MARKER.length;
    const rest = lowered.slice(from);
    if (!rest.startsWith('/')) continue;
    const word = rest.match(/^[^\s;&|<>()'"`]*/)[0];
    if (reachesAuth(word.split('/').filter((segment) => segment !== '' && segment !== '.'))) return true;
  }
}

function shellSpellings(command, tool) {
  const raw = String(command);
  const joined = raw.replace(/\\\r?\n/g, '');
  const unquoted = joined.replace(/['"`]/g, '');
  const spellings = [raw, joined, unquoted, unquoted.replace(/\\/g, ''), unquoted.replace(/\\/g, '/')];
  if (tool === 'PowerShell') {
    const ticked = raw.replace(/`/g, '');
    spellings.push(ticked, ticked.replace(/['"+\s]/g, ''));
    try {
      spellings.push(String(require('./powershell-command-v1.js').spellings(raw)));
    } catch (_error) {
      spellings.push(raw.replace(/[`'"+\s]/g, ''));
    }
  }
  return spellings;
}

function commandNamesAuth(command, tool) {
  for (const spelling of shellSpellings(command, tool)) {
    if (namesAuthPath(spelling)) return true;
    const lowered = spelling.toLowerCase();
    if (lowered.includes(MARKER) && lowered.includes(STATE_STEM)) return true;
  }
  return false;
}

function baseOf(payload, fallback) {
  const cwd = payload && typeof payload.cwd === 'string' ? payload.cwd : '';
  if (cwd !== '' && path.isAbsolute(cwd)) return cwd;
  if (typeof fallback === 'string' && fallback !== '' && path.isAbsolute(fallback)) return fallback;
  return process.cwd();
}

function resolvedSpellings(value, base) {
  const absolute = path.isAbsolute(value) ? value : path.join(base, value);
  const spellings = [value, absolute, path.resolve(absolute)];
  try {
    spellings.push(fs.realpathSync.native(absolute));
  } catch (_error) {
    return spellings;
  }
  return spellings;
}

function pathTarget(value, base) {
  return resolvedSpellings(value, base).find((spelling) => namesAuthPath(spelling)) || '';
}

function decide(options = {}) {
  const payload = options.payload;
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    return marked(options.raw) ? { deny: true, reason: REASONS.UNREADABLE } : { deny: false, reason: REASONS.UNMARKED };
  }
  const tool = payload.tool_name;
  if (!GUARD_TOOLS.includes(tool)) return { deny: false, reason: REASONS.OTHER_TOOL };
  const input = payload.tool_input && typeof payload.tool_input === 'object' && !Array.isArray(payload.tool_input) ? payload.tool_input : {};
  if (SHELL_TOOLS.includes(tool)) {
    const command = typeof input.command === 'string' ? input.command : '';
    return commandNamesAuth(command, tool) ? { deny: true, reason: REASONS.COMMAND } : { deny: false, reason: REASONS.CLEAN };
  }
  const base = baseOf(payload, options.cwd);
  let searchRoot = base;
  for (const field of PATH_FIELDS[tool]) {
    const value = input[field];
    if (typeof value !== 'string' || value === '') continue;
    const target = pathTarget(value, base);
    if (target) return { deny: true, reason: REASONS.PATH, target };
    searchRoot = path.isAbsolute(value) ? value : path.join(base, value);
  }
  if (SEARCH_TOOLS.includes(tool)) {
    const rootTarget = pathTarget(searchRoot, base);
    if (rootTarget) return { deny: true, reason: REASONS.PATH, target: rootTarget };
    const given = input[PATTERN_FIELDS[tool]];
    const pattern = typeof given === 'string' && given !== '' ? given : tool === 'Grep' ? '**' : '';
    if (pattern !== '') {
      const anyDepth = pattern.includes('/') ? pattern : `**/${pattern}`;
      const joined = path.isAbsolute(pattern) ? pattern : `${searchRoot}/${anyDepth}`;
      if (namesAuthPath(pattern) || namesAuthPath(joined)) return { deny: true, reason: REASONS.PATH, target: joined };
    }
  }
  return { deny: false, reason: REASONS.CLEAN };
}

function displayTarget(target) {
  return typeof target === 'string' && target !== '' ? target.replace(/[\u0000-\u001f\u007f]/g, '?') : '';
}

function denyReason(verdict) {
  const where = verdict && verdict.reason === REASONS.PATH && verdict.target
    ? `(${displayTarget(verdict.target)})`
    : verdict && verdict.reason === REASONS.COMMAND
      ? '(the command names a path inside a run auth directory)'
      : '(the payload could not be read and names a verify-feature run)';
  return `Zensu verify-auth guard: this call reaches the signed-in browser state of a /zensu:verify-feature run ${where}. `
    + `The ${authState.AUTH_DIR_NAME}/ directory of .zensu/${MARKER}/<run> holds a test-account session that no tool reads, writes or searches: `
    + 'the run-config helper writes it, the browser consent gate validates it, its recorder deletes it after the browser opens, '
    + 'and Phase 4 deletes the run directory. Do not retry through another tool, path spelling or command; '
    + 'to search or commit text that merely names such a path, use the Grep tool or a commit message file.';
}

function denyOutput(verdict) {
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: denyReason(verdict),
    },
  };
}

module.exports = {
  GUARD_MATCHER,
  GUARD_TOOLS,
  MARKER,
  PATH_FIELDS,
  PATTERN_FIELDS,
  REASONS,
  commandNamesAuth,
  decide,
  denyOutput,
  denyReason,
  marked,
  namesAuthPath,
  segmentMatches,
};
