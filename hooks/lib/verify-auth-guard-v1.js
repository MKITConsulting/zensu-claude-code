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
const AUTH = authState.AUTH_DIR_NAME;
const STATE_STEM = authState.STATE_FILE_NAME.replace(/\.json$/, '');
const PLAIN_NAME = /^[a-z0-9._ -]+$/;
const SIMPLE_GLOB = /^[a-z0-9._ *?[\]-]+$/;
const SHIFTING = /[{}()$`]/;
const WORD_END = /[)`'",;&|<>}]+$/;
const WORD_BREAKS = ';&|<>';
const POSIX_BLANKS = ' \t\n';
const ZSH_RANGE = /<\d*-\d*>/y;
const CLI_WORDS = Object.freeze([...cliVersion.BINARY_NAMES, cliVersion.PACKAGE_NAME]);
const SESSION_MARKER = authState.AUTH_SESSION_PREFIX.slice(0, -'auth-'.length);
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

function couldBeAuth(segment) {
  const name = segment.replace(/[. ]+$/, '');
  if (name === '') return false;
  if (PLAIN_NAME.test(name)) return name === AUTH;
  if (!SIMPLE_GLOB.test(name.replace(/\[[!^]/g, '['))) return true;
  const prefix = /^[a-z0-9._ -]*/.exec(name)[0];
  const suffix = /[a-z0-9._ -]*$/.exec(name)[0];
  return AUTH.startsWith(prefix) && AUTH.endsWith(suffix) && prefix.length + suffix.length <= AUTH.length;
}

function shifts(segment) {
  return SHIFTING.test(segment) || /^[. ]+$/.test(segment) || (segment.startsWith('.') && !PLAIN_NAME.test(segment));
}

function reachesAuth(segments) {
  const resolved = [];
  for (let index = 0; index < segments.length; index += 1) {
    const segment = segments[index];
    if (segment === '..') {
      if (resolved.length === 0) return false;
      resolved.pop();
      continue;
    }
    const deep = segment.includes('**');
    if (!deep && !shifts(segment)) {
      resolved.push(segment);
      continue;
    }
    if (resolved.length === 0 ? deep : couldBeAuth(resolved.length === 1 ? segment : resolved[1])) return true;
    const later = segments.slice(index + 1);
    return (shifts(segment) || later.some((next) => next === '..' || shifts(next))) && later.some(couldBeAuth);
  }
  return resolved.length >= 2 && couldBeAuth(resolved[1]);
}

function reachesFrom(word) {
  for (let at = word.indexOf(MARKER); at !== -1; at = word.indexOf(MARKER, at + 1)) {
    const end = word.indexOf('/', at + MARKER.length);
    if (end === -1) return false;
    const segments = word.slice(end + 1).replace(WORD_END, '').split('/').filter((segment) => segment !== '' && segment !== '.');
    const shifted = SHIFTING.test(word.slice(word.lastIndexOf('/', at) + 1, end));
    if (shifted ? segments.some(couldBeAuth) : reachesAuth(segments)) return true;
  }
  return false;
}

function namesAuthPath(text) {
  return typeof text === 'string' && text !== '' && reachesFrom(text.toLowerCase().replace(/\\/g, '/'));
}

function zshRange(text, index) {
  ZSH_RANGE.lastIndex = index;
  const match = ZSH_RANGE.exec(text);
  return match ? match[0] : '';
}

function shellWords(text, tool) {
  const blank = tool === 'PowerShell' ? (char) => /\s/.test(char) : (char) => POSIX_BLANKS.includes(char);
  const words = [];
  let word = '';
  let open = false;
  let quote = '';
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    const next = text[index + 1];
    if (quote === "'") {
      if (char === "'") quote = '';
      else word += char;
      continue;
    }
    if (quote === '"') {
      if (char === '"') quote = '';
      else if (char === '\\' && next !== undefined && '"\\$`\n'.includes(next)) {
        if (next !== '\n') word += next;
        index += 1;
      } else word += char;
      continue;
    }
    if (char === '\\') {
      if (next !== undefined && next !== '\n') word += next;
      index += 1;
      open = true;
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
      open = true;
      continue;
    }
    const range = char === '<' ? zshRange(text, index) : '';
    if (range !== '') {
      word += range;
      index += range.length - 1;
      open = true;
    } else if (blank(char) || WORD_BREAKS.includes(char)) {
      if (open) words.push(word);
      word = '';
      open = false;
    } else {
      word += char;
      open = true;
    }
  }
  if (open) words.push(word);
  return words;
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
  const variants = new Set();
  for (const spelling of shellSpellings(command, tool)) {
    const lowered = spelling.toLowerCase();
    if (lowered.includes(MARKER) && lowered.includes(STATE_STEM)) return true;
    if (marked(spelling)) variants.add(spelling).add(spelling.replace(/\\/g, '/'));
  }
  return [...variants].some((variant) => shellWords(variant, tool).some(namesAuthPath));
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
};
