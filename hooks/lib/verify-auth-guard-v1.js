'use strict';
const fs = require('node:fs');
const path = require('node:path');
const authState = require('./verify-auth-state-v1.js');
const cliVersion = require('./playwright-cli-version-v1.js');

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
const BRACKET_CLASS_CLOSERS = Object.freeze({ ':': ':]', '=': '=]', '.': '.]' });
const CLI_WORDS = Object.freeze([...cliVersion.BINARY_NAMES, cliVersion.PACKAGE_NAME]);
const SESSION_MARKER = authState.AUTH_SESSION_PREFIX.slice(0, -'auth-'.length);
const TOKEN_RE = /[^\s;&|<>()'"`]+/g;
const REASONS = Object.freeze({
  PATH: 'path-inside-run-auth-directory',
  COMMAND: 'command-names-run-auth-directory',
  SESSION: 'browser-call-names-run-without-verify-session',
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

function matchingBrace(text, open) {
  let depth = 0;
  for (let index = open; index < text.length; index += 1) {
    if (text[index] === '{') depth += 1;
    else if (text[index] === '}') {
      depth -= 1;
      if (depth === 0) return index;
    }
  }
  return -1;
}

function splitAlternatives(body) {
  const alternatives = [];
  let depth = 0;
  let start = 0;
  for (let index = 0; index < body.length; index += 1) {
    if (body[index] === '{') depth += 1;
    else if (body[index] === '}') depth -= 1;
    else if (body[index] === ',' && depth === 0) {
      alternatives.push(body.slice(start, index));
      start = index + 1;
    }
  }
  alternatives.push(body.slice(start));
  return alternatives;
}

function expandBraces(segment) {
  const open = segment.indexOf('{');
  if (open === -1) return [segment];
  const close = matchingBrace(segment, open);
  if (close === -1) return [segment];
  const head = segment.slice(0, open);
  const tail = segment.slice(close + 1);
  const results = [];
  for (const alternative of splitAlternatives(segment.slice(open + 1, close))) {
    const rests = expandBraces(`${alternative}${tail}`);
    if (rests === null) return null;
    for (const rest of rests) {
      results.push(`${head}${rest}`);
      if (results.length > MAX_BRACE_ALTERNATIVES) return null;
    }
  }
  return results;
}

function bracketEnd(glob, open) {
  let index = open + 1;
  if (glob[index] === '!' || glob[index] === '^') index += 1;
  if (glob[index] === ']') index += 1;
  while (index < glob.length) {
    const closer = glob[index] === '[' ? BRACKET_CLASS_CLOSERS[glob[index + 1]] : undefined;
    const close = closer ? glob.indexOf(closer, index + 2) : -1;
    if (close !== -1) {
      index = close + 2;
      continue;
    }
    if (glob[index] === ']') return index;
    index += 1;
  }
  return -1;
}

function globRegExp(glob) {
  let source = '';
  for (let index = 0; index < glob.length; index += 1) {
    const char = glob[index];
    if (char === '*') source += '.*';
    else if (char === '?') source += '.';
    else if (char === '[') {
      const end = bracketEnd(glob, index);
      if (end === -1) {
        source += '\\[';
        continue;
      }
      source += '.';
      index = end;
    } else {
      source += escapeRegExp(char);
    }
  }
  return new RegExp(`^${source}$`);
}

function segmentMatches(segment, name) {
  if (!/[*?[{]/.test(segment)) return segment === name;
  try {
    const alternatives = expandBraces(segment);
    if (alternatives === null) return true;
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

function reachesFrom(word) {
  let from = 0;
  for (;;) {
    const at = word.indexOf(MARKER, from);
    if (at === -1) return false;
    from = at + MARKER.length;
    const rest = word.slice(from);
    if (!rest.startsWith('/')) continue;
    if (reachesAuth(rest.split('/').filter((segment) => segment !== '' && segment !== '.'))) return true;
  }
}

function namesAuthPath(text) {
  if (typeof text !== 'string' || text === '') return false;
  const lowered = text.toLowerCase().replace(/\\/g, '/');
  for (const token of lowered.match(TOKEN_RE) || []) {
    if (!token.includes(MARKER)) continue;
    const words = token.includes('{') ? expandBraces(token) : [token];
    if (words === null || words.some(reachesFrom)) return true;
  }
  return false;
}

function namesCliWord(text) {
  return (text.match(/[^\s;&|<>()]+/g) || []).some((token) => CLI_WORDS.some((word) => token === word
    || token.endsWith(`/${word}`) || token.startsWith(`${word}@`)));
}

function runCallWithoutSession(command, tool) {
  const spellings = shellSpellings(command, tool).map((spelling) => spelling.toLowerCase().replace(/[`'"\\]/g, ''));
  return spellings.some(namesCliWord)
    && spellings.some((spelling) => spelling.includes(MARKER))
    && !spellings.some((spelling) => spelling.includes(SESSION_MARKER));
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
    if (commandNamesAuth(command, tool)) return { deny: true, reason: REASONS.COMMAND };
    if (runCallWithoutSession(command, tool)) return { deny: true, reason: REASONS.SESSION };
    return { deny: false, reason: REASONS.CLEAN };
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
    const usable = typeof given === 'string' && given !== '' && !(tool === 'Grep' && given.startsWith('!'));
    const searched = usable ? given : tool === 'Grep' ? '**' : '';
    const patterns = searched === '' ? [] : [...new Set([searched, searched.replace(/\\(.)/g, '$1')])];
    for (const pattern of patterns) {
      const anyDepth = pattern.includes('/') ? pattern : `**/${pattern}`;
      const joined = path.isAbsolute(pattern) ? [pattern] : resolvedSpellings(searchRoot, base).map((root) => `${root}/${anyDepth}`);
      const target = joined.find((candidate) => namesAuthPath(candidate));
      if (namesAuthPath(pattern) || target) return { deny: true, reason: REASONS.PATH, target: target || joined[0] };
    }
  }
  return { deny: false, reason: REASONS.CLEAN };
}

function displayTarget(target) {
  return typeof target === 'string' && target !== '' ? target.replace(/[\u0000-\u001f\u007f]/g, '?') : '';
}

function denyReason(verdict) {
  if (verdict && verdict.reason === REASONS.SESSION) {
    return 'Zensu verify-auth guard: this browser CLI call names a /zensu:verify-feature run directory but no zensu-verify session. '
      + 'A run config there may restore a signed-in test-account state, so it opens only on the session the run-config helper printed with it, '
      + 'where the browser consent gate judges every call. Name that session with -s=<session> exactly as the helper printed it; '
      + 'do not retry under another session name, program or path spelling.';
  }
  const where = verdict && verdict.reason === REASONS.PATH && verdict.target
    ? `(${displayTarget(verdict.target)})`
    : verdict && verdict.reason === REASONS.COMMAND
      ? '(the command names a path inside a run auth directory)'
      : '(the payload could not be read and names a verify-feature run)';
  return `Zensu verify-auth guard: this call reaches the signed-in browser state of a /zensu:verify-feature run ${where}. `
    + `The ${authState.AUTH_DIR_NAME}/ directory of .zensu/${MARKER}/<run> holds a test-account session that no tool reads, writes or searches: `
    + 'the run-config helper writes it, the browser consent gate validates it, its recorder deletes it after the browser opens, '
    + 'and Phase 4 discards what is left with the run-config helper\'s --discard-state. Do not retry through another tool, path spelling or command; '
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
  CLI_WORDS,
  GUARD_MATCHER,
  GUARD_TOOLS,
  MARKER,
  PATH_FIELDS,
  PATTERN_FIELDS,
  REASONS,
  SESSION_MARKER,
  commandNamesAuth,
  decide,
  denyOutput,
  denyReason,
  marked,
  namesAuthPath,
  segmentMatches,
};
