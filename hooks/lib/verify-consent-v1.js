'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const net = require('node:net');
const floor = require('./verify-navigation-floor-v1.js');
const principals = require('./claude-principal-v1.js');
const { msysDrivePrefix } = require('./claude-path-v1.js');
const hookRegistration = require('./hook-registration-v1.js');
const cliVersion = require('./playwright-cli-version-v1.js');

const CONSENT_MATCHER = 'Bash';
const CONSENT_HOOK_FILE = 'pre-browser-navigation-consent.sh';
const CONSENT_RECORDER_FILE = 'post-browser-navigation-consent.sh';
const { REGISTRATION } = hookRegistration;
const PLAYWRIGHT_CLI_SOURCE_VERSION = '0.1.21';
const CLI_BASENAMES = cliVersion.BINARY_NAMES;
const CLI_PACKAGE = cliVersion.PACKAGE_NAME;
const SESSION_PREFIX = 'zensu-verify-';
const SESSION_RE = /^zensu-verify-[a-z0-9][a-z0-9-]{0,39}$/;
const SESSION_ENV = 'PLAYWRIGHT_CLI_SESSION';
const CLI_MARKERS = Object.freeze([...new Set([
  ...CLI_BASENAMES.map((name) => name.replace(/\.(cmd|exe|ps1)$/i, '').toLowerCase()),
  CLI_PACKAGE.toLowerCase(),
])]);
const CLI_MARKER_RE = new RegExp(CLI_MARKERS.map((marker) => marker.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&')).join('|'));
const AMBIENT_TEXT_RE = /(^|[^A-Za-z0-9_])(PLAYWRIGHT_MCP_|PWTEST_)/;
const REDEFINITION_RE = /(^|[\s;&|({])(function\s+)?playwright-cli\s*\(\s*\)|(^|[\s;&|({])function\s+playwright-cli(\s|$|\{)/i;
const RUN_CONFIG_NAME = 'playwright-cli.json';
const RUN_OUTPUT_DIR_NAME = 'browser';
const MAX_RUN_ORIGINS = 8;
const MAX_RUN_CONFIG_BYTES = 16384;
const MAX_GLOBAL_CONFIG_BYTES = 65536;
const MAX_COMMAND_BYTES = 262144;
const MAX_NEST = 4;

const CLI_BOOLEAN_OPTIONS = Object.freeze([
  'headed', 'mobile', 'persistent', 'submit', 'boxes', 'clear', 'full-page', 'hires', 'httpOnly', 'secure',
  'static', 'global', 'with-deps', 'dry-run', 'list', 'force', 'only-shell', 'no-shell', 'cursor', 'annotate',
  'kill', 'hide', 'all', 'g', 'help', 'json', 'raw', 'version',
]);

const CLI_STRING_OPTIONS = Object.freeze(['_']);
const HARMLESS_FLAGS = Object.freeze(['json', 'raw', 'help', 'h', 'version', 'v']);

const ALLOWED_COMMANDS = Object.freeze({
  open: Object.freeze(['config', 'headed', 'browser', 'device', 'mobile', 'idle-timeout']),
  close: Object.freeze([]),
  goto: Object.freeze([]),
  'go-back': Object.freeze([]),
  'go-forward': Object.freeze([]),
  reload: Object.freeze([]),
  'tab-list': Object.freeze([]),
  'tab-new': Object.freeze([]),
  'tab-close': Object.freeze([]),
  'tab-select': Object.freeze([]),
  snapshot: Object.freeze(['depth', 'boxes']),
  find: Object.freeze(['regex']),
  screenshot: Object.freeze(['type', 'full-page', 'hires']),
  console: Object.freeze(['clear']),
  requests: Object.freeze(['static', 'filter', 'clear']),
  click: Object.freeze(['modifiers']),
  dblclick: Object.freeze(['modifiers']),
  fill: Object.freeze(['submit']),
  type: Object.freeze(['submit']),
  press: Object.freeze([]),
  keydown: Object.freeze([]),
  keyup: Object.freeze([]),
  hover: Object.freeze([]),
  drag: Object.freeze([]),
  select: Object.freeze([]),
  check: Object.freeze([]),
  uncheck: Object.freeze([]),
  'dialog-accept': Object.freeze([]),
  'dialog-dismiss': Object.freeze([]),
  resize: Object.freeze([]),
  mousemove: Object.freeze([]),
  mousedown: Object.freeze([]),
  mouseup: Object.freeze([]),
  mousewheel: Object.freeze([]),
  'set-color-scheme': Object.freeze([]),
  'set-reduced-motion': Object.freeze([]),
  'set-forced-colors': Object.freeze([]),
  'set-contrast': Object.freeze([]),
  'set-media': Object.freeze([]),
  'clear-color-scheme': Object.freeze([]),
  'clear-reduced-motion': Object.freeze([]),
  'clear-forced-colors': Object.freeze([]),
  'clear-contrast': Object.freeze([]),
  'clear-media': Object.freeze([]),
  list: Object.freeze(['all']),
});

const NAVIGATION_COMMANDS = Object.freeze(['open', 'goto', 'tab-new']);
const CHROMIUM_BROWSERS = Object.freeze([
  'chrome', 'chrome-beta', 'chrome-canary', 'chrome-dev',
  'msedge', 'msedge-beta', 'msedge-canary', 'msedge-dev', 'chromium',
]);

const GLOBAL_CONFIG_HARMLESS = Object.freeze({
  browser: { browserName: true, launchOptions: { channel: true, headless: true } },
  timeouts: '*',
  testIdAttribute: true,
  console: '*',
  snapshot: '*',
  outputMode: true,
  imageResponses: true,
  codegen: true,
  network: { blockedOrigins: true },
});

const ENV_BUILTINS = Object.freeze(['export', 'declare', 'typeset', 'readonly', 'local', 'set', 'unset', 'source', '.']);
const SHELLS = Object.freeze(['sh', 'bash', 'zsh', 'dash', 'ksh']);
const RESERVED = Object.freeze(['{', '}', '!', 'if', 'then', 'else', 'elif', 'do', 'while', 'until']);

const MEMORY_VERSION = 1;
const MEMORY_NAME_PREFIX = 'verify-consent-';
const MEMORY_NAME_RE = new RegExp(`^${MEMORY_NAME_PREFIX}scv1_[a-f0-9]{64}\\.json$`);
const MAX_MEMORY_BYTES = 65536;
const MAX_RECORDS = 512;
const DECIDED_BY = Object.freeze(['asked', 'remembered', 'policy-mode']);
const STATE_SEGMENTS = Object.freeze(['.zensu', 'state']);

const REASONS = Object.freeze({
  PAYLOAD_UNREADABLE: 'hook-payload-unreadable',
  COMMAND_TOO_LARGE: 'command too large to judge',
  NOT_MAIN_THREAD: 'zensu-verify browser sessions are main-thread only',
  SESSION_MALFORMED: 'the zensu-verify session name is malformed or given more than once',
  SESSION_UNRESOLVED: 'the command names a zensu-verify session that its playwright-cli call does not resolve to; pass the session exactly as /zensu:verify-feature prints it (-s=<name>), and keep a zensu-verify name out of every other argument',
  SESSION_UNEXPANDED: 'a playwright-cli call beside a zensu-verify session must name its session literally',
  ARGUMENT_UNEXPANDED: 'a zensu-verify session call must carry literal arguments only',
  INDIRECT: 'a zensu-verify playwright-cli call must run as a plain command, not through another program; to search or commit text that merely names playwright-cli and a zensu-verify session, use the Grep tool or a message file',
  NOT_PLAIN: 'a command that names playwright-cli and a zensu-verify session, or names playwright-cli while PLAYWRIGHT_CLI_SESSION names one, must be exactly one plain playwright-cli call whose redirections name literal paths; run every other command separately, and search or commit such text through the Grep tool or a message file',
  UNJUDGED_BODY: 'a zensu-verify playwright-cli call sits inside a heredoc or nested shell the gate cannot judge',
  ENV_ASSIGNMENT: 'a zensu-verify session call must not carry environment assignments or wrappers that change its environment',
  WRAPPER: 'a zensu-verify session call must not run under a wrapper such as timeout, nohup, time, nice, exec, command or builtin',
  LAUNCHER: 'a zensu-verify session call must run the installed playwright-cli binary, not a package launcher that may fetch or select another version',
  CLI_NOT_BARE: 'a zensu-verify session call must name the CLI by its bare name, playwright-cli, so PATH resolves the installed binary /zensu:doctor measured; a path, another letter case or the package name is refused',
  ENV_BUILTIN: 'a command carrying a zensu-verify session call must not change the shell environment',
  AMBIENT_TEXT: 'a command carrying a zensu-verify session call must not name PLAYWRIGHT_MCP_* or PWTEST_* variables',
  REDEFINED: 'a command carrying a zensu-verify session call must not define a playwright-cli function',
  COMMAND_DENIED: 'is not available in a /zensu:verify-feature browser session; do not retry it under another session name or through another program',
  FLAG_DENIED: 'is not available in a /zensu:verify-feature browser session; do not retry it under another session name or through another program',
  CONFIG_REQUIRED: 'open on a zensu-verify session needs --config=<absolute path> naming the run config written by scripts/verify-browser-config.js',
  OPEN_OUTSIDE_CONFIG: 'the open target is outside the run config allowedOrigins',
  BROWSER_NOT_CHROMIUM: 'the run config pins hosts with Chromium switches, so --browser must name a chrome, msedge or chromium channel',
  GLOBAL_BROWSER_NOT_CHROMIUM: 'the global playwright-cli config selects a browser other than chromium, which ignores the run config resolver pins',
  POLICY_INVALID: 'the navigation policy in the launch environment is invalid',
  NOT_POLICY_TARGET: 'origin is not a target of the navigation policy',
  NOT_POLICY_ROUTE: 'route is not approved for evidence by the navigation policy',
  REMOTE_NEEDS_POLICY: `remote-target-needs-parent-environment-policy: ${floor.CONSENT_REMOTE_REASON}`,
  NEW_ORIGIN: 'new-origin-needs-consent',
  MEMORY_UNREADABLE: 'consent-memory-unreadable',
  MEMORY_PATH_REFUSED: 'consent-memory-path-refused',
});
const SHAPE_REASONS = Object.freeze([
  'NOT_PLAIN', 'ARGUMENT_UNEXPANDED', 'SESSION_UNRESOLVED', 'SESSION_UNEXPANDED', 'CLI_NOT_BARE', 'WRAPPER', 'LAUNCHER', 'ENV_ASSIGNMENT',
]);
const FINAL_REASONS = Object.freeze([
  'PAYLOAD_UNREADABLE', 'COMMAND_TOO_LARGE', 'NOT_MAIN_THREAD', 'SESSION_MALFORMED', 'INDIRECT', 'UNJUDGED_BODY', 'ENV_BUILTIN',
  'AMBIENT_TEXT', 'REDEFINED', 'COMMAND_DENIED', 'FLAG_DENIED', 'CONFIG_REQUIRED', 'OPEN_OUTSIDE_CONFIG', 'BROWSER_NOT_CHROMIUM',
  'GLOBAL_BROWSER_NOT_CHROMIUM', 'POLICY_INVALID', 'NOT_POLICY_TARGET', 'NOT_POLICY_ROUTE', 'REMOTE_NEEDS_POLICY', 'NEW_ORIGIN',
  'MEMORY_UNREADABLE', 'MEMORY_PATH_REFUSED',
]);
const SHAPE_MARKER = '(shape denial: re-issue this call once as one plain playwright-cli call with single-quoted literal arguments; a second denial is final)';
const SHAPE_TEXTS = new Set(SHAPE_REASONS.map((key) => REASONS[key]));

function strippedText(text) {
  return String(text).replace(/\\\r?\n/g, '').replace(/['"\\]/g, '');
}

function normalizedText(text) {
  return strippedText(text).toLowerCase();
}

function envSessionMarked(env) {
  const value = env && typeof env[SESSION_ENV] === 'string' ? env[SESSION_ENV] : '';
  return value.toLowerCase().includes(SESSION_PREFIX);
}

function commandMarkers(command, env) {
  const normalized = normalizedText(command);
  return {
    cli: CLI_MARKER_RE.test(normalized),
    named: normalized.includes(SESSION_PREFIX),
    session: normalized.includes(SESSION_PREFIX) || envSessionMarked(env),
  };
}

function payloadFromRaw(raw, accumulationFailed) {
  if (accumulationFailed) return null;
  if (typeof raw !== 'string' || raw.trim() === '') return null;
  try {
    return JSON.parse(raw);
  } catch (_error) {
    return null;
  }
}

function findBacktick(text, start) {
  let index = start;
  while (index < text.length) {
    if (text[index] === '\\') { index += 2; continue; }
    if (text[index] === '`') return index;
    index += 1;
  }
  return -1;
}

function skipDouble(text, start) {
  let index = start;
  while (index < text.length) {
    const char = text[index];
    if (char === '\\') { index += 2; continue; }
    if (char === '"') return index;
    index += 1;
  }
  return -1;
}

function findParen(text, start) {
  let depth = 1;
  let index = start;
  while (index < text.length) {
    const char = text[index];
    if (char === '\\') { index += 2; continue; }
    if (char === "'") {
      const end = text.indexOf("'", index + 1);
      if (end === -1) return -1;
      index = end + 1;
      continue;
    }
    if (char === '"') {
      const end = skipDouble(text, index + 1);
      if (end === -1) return -1;
      index = end + 1;
      continue;
    }
    if (char === '`') {
      const end = findBacktick(text, index + 1);
      if (end === -1) return -1;
      index = end + 1;
      continue;
    }
    if (char === '(') depth += 1;
    if (char === ')') {
      depth -= 1;
      if (depth === 0) return index;
    }
    index += 1;
  }
  return -1;
}

function findBrace(text, start) {
  let depth = 1;
  let index = start;
  while (index < text.length) {
    const char = text[index];
    if (char === '\\') { index += 2; continue; }
    if (char === '{') depth += 1;
    if (char === '}') {
      depth -= 1;
      if (depth === 0) return index;
    }
    index += 1;
  }
  return -1;
}

function shellPattern(bare) {
  if (/[*?[]/.test(bare) || /^[~=]/.test(bare)) return true;
  return /\{[^{}]*(,|\.\.)[^{}]*\}/.test(bare);
}

function lexShell(text) {
  const source = String(text);
  const segments = [];
  const nested = [];
  const heredocs = [];
  const herestrings = [];
  let fault = '';
  let operators = 0;
  let words = [];
  let word = null;
  let pendingHeredocs = [];
  let expectHeredoc = null;
  let redirectNext = false;
  let redirected = false;
  let redirectUnexpanded = false;
  let index = 0;

  const startWord = () => {
    if (!word) word = { value: '', raw: '', unexpanded: false, quoted: false, bare: '' };
  };
  const endWord = () => {
    if (!word) return;
    if (!word.unexpanded && shellPattern(word.bare)) word.unexpanded = true;
    if (expectHeredoc) {
      pendingHeredocs.push({ delimiter: word.value, strip: expectHeredoc.strip });
      expectHeredoc = null;
    } else if (redirectNext) {
      if (redirectNext === 'herestring') herestrings.push(word);
      redirectNext = false;
      redirected = true;
      if (word.unexpanded) redirectUnexpanded = true;
    } else {
      words.push(word);
    }
    word = null;
  };
  const endSegment = () => {
    endWord();
    if (words.length > 0 || redirected) segments.push(words);
    words = [];
    redirected = false;
  };
  const consumeHeredocs = (position) => {
    let cursor = position;
    for (const pending of pendingHeredocs) {
      let body = '';
      let closed = false;
      while (cursor < source.length) {
        const newline = source.indexOf('\n', cursor);
        const line = source.slice(cursor, newline === -1 ? source.length : newline);
        cursor = newline === -1 ? source.length : newline + 1;
        const compared = pending.strip ? line.replace(/^\t+/, '') : line;
        if (compared === pending.delimiter) { closed = true; break; }
        body += `${line}\n`;
      }
      heredocs.push(body);
      if (!closed) fault = fault || 'unterminated-heredoc';
    }
    pendingHeredocs = [];
    return cursor;
  };
  const readDollar = (position, target) => {
    const next = source[position + 1];
    const wasUnexpanded = target.unexpanded;
    target.unexpanded = true;
    if (next === '(') {
      const end = findParen(source, position + 2);
      if (end === -1) { fault = fault || 'unterminated-substitution'; target.raw += source.slice(position); return source.length; }
      nested.push(source.slice(position + 2, end));
      target.raw += source.slice(position, end + 1);
      return end + 1;
    }
    if (next === '{') {
      const end = findBrace(source, position + 2);
      if (end === -1) { fault = fault || 'unterminated-expansion'; target.raw += source.slice(position); return source.length; }
      nested.push(source.slice(position + 2, end));
      target.raw += source.slice(position, end + 1);
      return end + 1;
    }
    if (next === "'") {
      let cursor = position + 2;
      while (cursor < source.length && source[cursor] !== "'") cursor += source[cursor] === '\\' ? 2 : 1;
      if (cursor >= source.length) { fault = fault || 'unterminated-quote'; target.raw += source.slice(position); return source.length; }
      target.raw += source.slice(position, cursor + 1);
      return cursor + 1;
    }
    if (next === '"') {
      target.raw += '$';
      return readDouble(position + 1, target);
    }
    const name = source.slice(position + 1).match(/^([A-Za-z_][A-Za-z0-9_]*|[@*#?$!0-9-])/);
    if (name) {
      target.raw += `$${name[1]}`;
      return position + 1 + name[1].length;
    }
    if (next === undefined || /\s/.test(next)) target.unexpanded = wasUnexpanded;
    target.value += '$';
    target.raw += '$';
    return position + 1;
  };
  const readDouble = (position, target) => {
    target.quoted = true;
    let cursor = position + 1;
    while (cursor < source.length && source[cursor] !== '"') {
      const inner = source[cursor];
      if (inner === '\\' && cursor + 1 < source.length && '$`"\\\n'.includes(source[cursor + 1])) {
        if (source[cursor + 1] !== '\n') target.value += source[cursor + 1];
        cursor += 2;
        continue;
      }
      if (inner === '$' && (source[cursor + 1] === '"' || source[cursor + 1] === "'")) {
        if (source[cursor + 1] === "'") target.unexpanded = true;
        target.value += '$';
        cursor += 1;
        continue;
      }
      if (inner === '$') {
        const before = target.raw.length;
        cursor = readDollar(cursor, target);
        target.raw = target.raw.slice(0, before);
        continue;
      }
      if (inner === '`') {
        target.unexpanded = true;
        const end = findBacktick(source, cursor + 1);
        if (end === -1) { fault = fault || 'unterminated-substitution'; cursor = source.length; break; }
        nested.push(source.slice(cursor + 1, end));
        cursor = end + 1;
        continue;
      }
      target.value += inner;
      cursor += 1;
    }
    if (cursor >= source.length) fault = fault || 'unterminated-quote';
    target.raw += source.slice(position, cursor + 1);
    return cursor + 1;
  };

  while (index < source.length) {
    const char = source[index];
    if (char === '\\') {
      if (source[index + 1] === '\n') { index += 2; continue; }
      startWord();
      if (index + 1 < source.length) {
        word.value += source[index + 1];
        word.raw += source.slice(index, index + 2);
        word.bare += '\u0001';
      }
      index += 2;
      continue;
    }
    if (char === "'") {
      startWord();
      word.quoted = true;
      word.bare += '\u0001';
      const end = source.indexOf("'", index + 1);
      if (end === -1) {
        fault = fault || 'unterminated-quote';
        word.value += source.slice(index + 1);
        word.raw += source.slice(index);
        index = source.length;
        continue;
      }
      word.value += source.slice(index + 1, end);
      word.raw += source.slice(index, end + 1);
      index = end + 1;
      continue;
    }
    if (char === '"') {
      startWord();
      word.bare += '\u0001';
      index = readDouble(index, word);
      continue;
    }
    if (char === '$') {
      startWord();
      index = readDollar(index, word);
      word.bare += '\u0001';
      continue;
    }
    if (char === '`') {
      startWord();
      word.unexpanded = true;
      word.bare += '\u0001';
      const end = findBacktick(source, index + 1);
      if (end === -1) { fault = fault || 'unterminated-substitution'; word.raw += source.slice(index); index = source.length; continue; }
      nested.push(source.slice(index + 1, end));
      word.raw += source.slice(index, end + 1);
      index = end + 1;
      continue;
    }
    if ((char === '<' || char === '>') && source[index + 1] === '(') {
      startWord();
      word.unexpanded = true;
      word.bare += '\u0001';
      const end = findParen(source, index + 2);
      if (end === -1) { fault = fault || 'unterminated-substitution'; word.raw += source.slice(index); index = source.length; continue; }
      nested.push(source.slice(index + 2, end));
      word.raw += source.slice(index, end + 1);
      index = end + 1;
      continue;
    }
    if (char === ' ' || char === '\t') { endWord(); index += 1; continue; }
    if (char === '\n') {
      endSegment();
      index = pendingHeredocs.length > 0 ? consumeHeredocs(index + 1) : index + 1;
      continue;
    }
    if (char === '#' && !word) {
      const newline = source.indexOf('\n', index);
      index = newline === -1 ? source.length : newline;
      continue;
    }
    if (char === ';') { endSegment(); operators += 1; index += source[index + 1] === ';' ? 2 : 1; continue; }
    if (char === '&') {
      if (source[index + 1] === '&') { endSegment(); operators += 1; index += 2; continue; }
      if (source[index + 1] === '>') {
        endWord();
        redirectNext = true;
        index += source[index + 2] === '>' ? 3 : 2;
        continue;
      }
      endSegment();
      operators += 1;
      index += 1;
      continue;
    }
    if (char === '|') {
      endSegment();
      operators += 1;
      index += source[index + 1] === '|' || source[index + 1] === '&' ? 2 : 1;
      continue;
    }
    if (char === '(' || char === ')') { endSegment(); operators += 1; index += 1; continue; }
    if (char === '<' || char === '>') {
      if (word && !word.quoted && !word.unexpanded && /^\d+$/.test(word.raw)) word = null;
      else endWord();
      if (char === '<' && source[index + 1] === '<') {
        if (source[index + 2] === '<') { redirectNext = 'herestring'; index += 3; continue; }
        const strip = source[index + 2] === '-';
        expectHeredoc = { strip };
        index += strip ? 3 : 2;
        continue;
      }
      let cursor = index + 1;
      if (source[cursor] === '>' || source[cursor] === '|' || source[cursor] === '&') cursor += 1;
      redirectNext = true;
      index = cursor;
      continue;
    }
    startWord();
    word.value += char;
    word.raw += char;
    word.bare += char;
    index += 1;
  }
  endSegment();
  if (pendingHeredocs.length > 0) {
    consumeHeredocs(source.length);
  }
  return { segments, nested, heredocs, herestrings, fault, operators, redirectUnexpanded };
}

function parseCliArgs(argv) {
  const booleans = new Set(CLI_BOOLEAN_OPTIONS);
  const strings = new Set(CLI_STRING_OPTIONS);
  const bare = (key) => (strings.has(key) ? '' : true);
  const parsed = { _: [] };
  const sessionArguments = new Set();
  let current = -1;
  const setArg = (key, value) => {
    if (key === 's' || key === 'session') sessionArguments.add(current);
    if (parsed[key] === undefined || booleans.has(key) || typeof parsed[key] === 'boolean') parsed[key] = value;
    else if (Array.isArray(parsed[key])) parsed[key].push(value);
    else parsed[key] = [parsed[key], value];
  };
  let args = argv.slice();
  let notFlags = [];
  const doubleDash = args.indexOf('--');
  if (doubleDash !== -1) {
    notFlags = args.slice(doubleDash + 1);
    args = args.slice(0, doubleDash);
  }
  for (let index = 0; index < args.length; index += 1) {
    current = index;
    const arg = args[index];
    if (/^--.+=/.test(arg)) {
      const match = arg.match(/^--([^=]+)=([\s\S]*)$/);
      if (booleans.has(match[1])) return { fault: `boolean option --${match[1]} carries a value` };
      setArg(match[1], match[2]);
    } else if (/^--no-.+/.test(arg)) {
      setArg(arg.match(/^--no-(.+)/)[1], false);
    } else if (/^--.+/.test(arg)) {
      const key = arg.match(/^--(.+)/)[1];
      const next = args[index + 1];
      if (next !== undefined && !/^(-|--)[^-]/.test(next) && !booleans.has(key)) {
        setArg(key, next);
        index += 1;
      } else if (/^(true|false)$/.test(next)) {
        setArg(key, next === 'true');
        index += 1;
      } else {
        setArg(key, bare(key));
      }
    } else if (/^-[A-Za-z]/.test(arg)) {
      const letters = arg.slice(1, -1).split('');
      let broken = false;
      for (let position = 0; position < letters.length; position += 1) {
        const next = arg.slice(position + 2);
        if (next === '-') { setArg(letters[position], next); continue; }
        if (/[A-Za-z]/.test(letters[position]) && next[0] === '=') {
          setArg(letters[position], next.slice(1));
          broken = true;
          break;
        }
        if (/[A-Za-z]/.test(letters[position]) && /-?\d+(\.\d*)?(e-?\d+)?$/.test(next)) {
          setArg(letters[position], next);
          broken = true;
          break;
        }
        if (letters[position + 1] && letters[position + 1].match(/\W/)) {
          setArg(letters[position], arg.slice(position + 2));
          broken = true;
          break;
        }
        setArg(letters[position], bare(letters[position]));
      }
      const key = arg.slice(-1)[0];
      if (!broken && key !== '-') {
        if (args[index + 1] && !/^(-|--)[^-]/.test(args[index + 1]) && !booleans.has(key)) {
          setArg(key, args[index + 1]);
          index += 1;
        } else if (args[index + 1] && /^(true|false)$/.test(args[index + 1])) {
          setArg(key, args[index + 1] === 'true');
          index += 1;
        } else {
          setArg(key, bare(key));
        }
      }
    } else {
      parsed._.push(arg);
    }
  }
  for (const item of notFlags) parsed._.push(item);
  if (parsed.s) {
    parsed.session = parsed.s;
    delete parsed.s;
  }
  if (parsed.g) {
    parsed.global = true;
    delete parsed.g;
  }
  return { args: parsed, sessionFlags: sessionArguments.size };
}

function valueAssignmentOf(word) {
  const match = word.value.match(/^([A-Za-z_][A-Za-z0-9_]*)=/);
  return match ? { name: match[1], value: word.value.slice(match[0].length), unexpanded: word.unexpanded } : null;
}

function assignmentOf(word) {
  if (!word) return null;
  const match = word.raw.match(/^([A-Za-z_][A-Za-z0-9_]*)(\+?)=/);
  if (!match) return null;
  return { name: match[1], value: word.value.slice(match[0].length), unexpanded: word.unexpanded || match[2] === '+' };
}

function cliBasename(value) {
  const normalized = String(value).replace(/\\/g, '/');
  return normalized.slice(normalized.lastIndexOf('/') + 1);
}

function isCliWord(word) {
  if (!word || word.unexpanded) return false;
  const value = word.value.toLowerCase();
  const base = cliBasename(value);
  return CLI_BASENAMES.includes(base) || value === CLI_PACKAGE || value.startsWith(`${CLI_PACKAGE}@`);
}

function launcherCliIndex(words, start) {
  const command = cliBasename(words[start].value).toLowerCase();
  let index = start + 1;
  if (command === 'pnpm' || command === 'yarn' || command === 'npm') {
    const verb = words[index] && words[index].value.toLowerCase();
    if (!['dlx', 'exec', 'x'].includes(verb)) return -1;
    index += 1;
  } else if (!['npx', 'bunx', 'pnpx'].includes(command)) {
    return -1;
  }
  while (index < words.length) {
    const value = words[index].value;
    if (value === '--') { index += 1; continue; }
    if (value === '-p' || value === '--package') { index += 2; continue; }
    if (value.startsWith('-')) { index += 1; continue; }
    break;
  }
  return index < words.length && isCliWord(words[index]) ? index : -1;
}

function commandPosition(words) {
  const assignments = [];
  const wrappers = [];
  let index = 0;
  while (index < words.length && RESERVED.includes(words[index].value) && !words[index].quoted) index += 1;
  while (index < words.length) {
    const assignment = assignmentOf(words[index]);
    if (!assignment) break;
    assignments.push(assignment);
    index += 1;
  }
  while (index < words.length) {
    const value = cliBasename(words[index].value);
    if (value === 'command' || value === 'builtin') {
      const flag = words[index + 1] && words[index + 1].value;
      if (flag === '-v' || flag === '-V') return { assignments, wrappers, index: -1, lookup: true };
      wrappers.push(value);
      index += 1;
      while (index < words.length && words[index].value.startsWith('-')) index += 1;
      continue;
    }
    if (value === 'exec' || value === 'nohup' || value === 'time') {
      wrappers.push(value);
      index += 1;
      while (index < words.length && words[index].value.startsWith('-')) {
        if (words[index].value === '-a') index += 1;
        index += 1;
      }
      continue;
    }
    if (value === 'nice') {
      wrappers.push(value);
      index += 1;
      while (index < words.length && words[index].value.startsWith('-')) {
        if (words[index].value === '-n') index += 1;
        index += 1;
      }
      continue;
    }
    if (value === 'timeout' || value === 'gtimeout') {
      wrappers.push(value);
      index += 1;
      while (index < words.length && words[index].value.startsWith('-')) {
        if (['-s', '-k', '--signal', '--kill-after'].includes(words[index].value)) index += 1;
        index += 1;
      }
      index += 1;
      continue;
    }
    if (value === 'env' || value === 'sudo' || value === 'doas') {
      wrappers.push(value);
      index += 1;
      while (index < words.length && (words[index].value.startsWith('-') || valueAssignmentOf(words[index]))) {
        const option = words[index].value;
        if (value === 'env' && valueAssignmentOf(words[index])) assignments.push(valueAssignmentOf(words[index]));
        if (['-u', '-C', '-S', '--unset', '--chdir', '--split-string', '-g', '-h', '-p', '-U'].includes(option)) index += 1;
        index += 1;
      }
      continue;
    }
    break;
  }
  return { assignments, wrappers, index, lookup: false };
}

function unexpandedSentinel(word, position) {
  return `${word.value}\u0000unexpanded${position}\u0000`;
}

function hasSentinel(value) {
  if (typeof value === 'string') return value.includes('\u0000');
  if (Array.isArray(value)) return value.some(hasSentinel);
  return false;
}

function sessionOf(args, assigned, env) {
  const value = args.session;
  if (typeof value === 'string' && value !== '') return { value, source: 'argument' };
  if (Array.isArray(value)) return { value, source: 'argument' };
  if (value === true) return { value: 'true', source: 'argument' };
  if (assigned) return { value: assigned.value, source: 'assignment', unexpanded: assigned.unexpanded };
  if (env && typeof env[SESSION_ENV] === 'string' && env[SESSION_ENV] !== '') return { value: env[SESSION_ENV], source: 'environment' };
  return { value: 'default', source: 'default' };
}

function isGatedSession(value) {
  const gated = (item) => typeof item === 'string' && item.toLowerCase().includes(SESSION_PREFIX);
  return Array.isArray(value) ? value.some(gated) : gated(value);
}

function namesCli(text) {
  return CLI_MARKER_RE.test(normalizedText(text));
}

const NO_SCOPE = Object.freeze({ assignments: Object.freeze([]), wrappers: Object.freeze([]) });

function scanSegments(lexed, context, depth, found, inherited) {
  for (const words of lexed.segments) {
    const position = commandPosition(words);
    if (position.lookup) continue;
    const assignments = inherited.assignments.concat(position.assignments);
    const wrappers = inherited.wrappers.concat(position.wrappers);
    for (const assignment of position.assignments) {
      if (assignment.name === SESSION_ENV) context.sessionAssignments.push(assignment);
    }
    const segmentAssigned = assignments.filter((item) => item.name === SESSION_ENV).pop();
    const consumed = new Set();
    if (position.index >= 0 && position.index < words.length) {
      const head = words[position.index];
      const headName = cliBasename(head.value);
      if (ENV_BUILTINS.includes(headName) && !head.quoted) {
        found.envBuiltin = true;
        for (const word of words.slice(position.index + 1)) {
          const assignment = assignmentOf(word);
          if (assignment && assignment.name === SESSION_ENV) {
            context.commandSession = assignment;
            context.sessionAssignments.push(assignment);
          }
        }
      }
      const cliAt = isCliWord(head) ? position.index : launcherCliIndex(words, position.index);
      const scope = { assignments, wrappers };
      if (SHELLS.includes(headName)) {
        const flagAt = words.findIndex((word, offset) => offset > position.index && /^-[A-Za-z]*c[A-Za-z]*$/.test(word.value));
        if (flagAt !== -1 && words[flagAt + 1]) {
          const body = words[flagAt + 1];
          consumed.add(flagAt + 1);
          if (body.unexpanded || depth >= MAX_NEST) {
            if (namesCli(body.raw) && context.marks.session) found.unjudged = true;
          } else {
            scanCommand(body.value, context, depth + 1, found, scope);
          }
        }
      }
      if (headName === 'eval') {
        const body = words.slice(position.index + 1);
        body.forEach((_word, offset) => consumed.add(position.index + 1 + offset));
        if (body.some((word) => word.unexpanded) || depth >= MAX_NEST) {
          if (body.some((word) => namesCli(word.raw)) && context.marks.session) found.unjudged = true;
        } else {
          scanCommand(body.map((word) => word.value).join(' '), context, depth + 1, found, scope);
        }
      }
      if (cliAt !== -1) {
        found.invocations.push({
          words: words.slice(cliAt + 1),
          assignments,
          wrappers,
          launcher: cliAt !== position.index,
          bare: cliVersion.binaryNames(context.platform).includes(words[cliAt].value),
          segmentSession: segmentAssigned || null,
          depth,
        });
        continue;
      }
    }
    if (position.index >= words.length) {
      for (const assignment of position.assignments) if (assignment.name === SESSION_ENV) context.commandSession = assignment;
    }
    const indirect = words.some((word, offset) => offset !== position.index && !consumed.has(offset)
      && (isCliWord(word) || namesCli(word.value)));
    if (indirect && context.marks.session) found.indirect = true;
  }
}

function scanCommand(text, context, depth, found, inherited = NO_SCOPE) {
  const lexed = lexShell(text);
  if (depth === 0) context.top = lexed;
  if (lexed.fault && namesCli(text) && context.marks.session) found.unjudged = true;
  scanSegments(lexed, context, depth, found, inherited);
  for (const body of lexed.nested) {
    if (depth < MAX_NEST) scanCommand(body, context, depth + 1, found);
    else if (namesCli(body) && context.marks.session) found.unjudged = true;
  }
  for (const body of lexed.heredocs) {
    if (namesCli(body) && context.marks.session) found.unjudged = true;
  }
  for (const word of lexed.herestrings) {
    if (namesCli(word.raw) && context.marks.session) found.unjudged = true;
  }
}

function plainShape(top, invocations) {
  if (!top || top.fault || top.operators !== 0 || top.segments.length !== 1 || top.redirectUnexpanded) return false;
  if (top.nested.length + top.heredocs.length + top.herestrings.length > 0) return false;
  return invocations.length === 1 && invocations[0].depth === 0;
}

function analyzeCommand(command, env, platform = process.platform) {
  const text = String(command);
  const marks = commandMarkers(text, env);
  const found = { invocations: [], indirect: false, unjudged: false, envBuiltin: false };
  const context = { text, marks, platform, commandSession: null, sessionAssignments: [], top: null };
  scanCommand(text, context, 0, found);
  const conflict = marks.session && context.sessionAssignments.length > 1;
  const calls = [];
  for (const invocation of found.invocations) {
    const argv = invocation.words.map((word, position) => (word.unexpanded ? unexpandedSentinel(word, position) : word.value));
    const parsed = parseCliArgs(argv);
    if (parsed.fault) {
      calls.push({ invocation, gated: marks.session, fault: parsed.fault });
      continue;
    }
    if (conflict || (marks.session && parsed.sessionFlags > 1)) {
      calls.push({ invocation, gated: true, fault: REASONS.SESSION_MALFORMED });
      continue;
    }
    const assigned = invocation.segmentSession || context.commandSession;
    if (marks.session && assigned && assigned.unexpanded) {
      calls.push({ invocation, gated: true, fault: REASONS.SESSION_UNEXPANDED });
      continue;
    }
    const session = sessionOf(parsed.args, assigned, env);
    const unexpandedSession = hasSentinel(session.value) || (session.source === 'assignment' && session.unexpanded);
    if (unexpandedSession) {
      calls.push({ invocation, gated: marks.session, fault: REASONS.SESSION_UNEXPANDED });
      continue;
    }
    if (isGatedSession(session.value)) calls.push({ invocation, gated: true, session, args: parsed.args });
    else if (marks.session && argv.some(hasSentinel)) calls.push({ invocation, gated: true, fault: REASONS.ARGUMENT_UNEXPANDED });
  }
  return {
    text,
    calls,
    indirect: found.indirect,
    unjudged: found.unjudged,
    envBuiltin: found.envBuiltin,
    plain: plainShape(context.top, found.invocations),
  };
}

function isIsoInstant(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value)) return false;
  try { return new Date(value).toISOString() === value; }
  catch (_error) { return false; }
}

function validRecord(record) {
  return record && typeof record === 'object'
    && typeof record.origin === 'string' && record.origin.length > 0
    && typeof record.route === 'string' && record.route.startsWith('/')
    && DECIDED_BY.includes(record.decidedBy)
    && isIsoInstant(record.at);
}

function emptyMemory() {
  return { version: MEMORY_VERSION, records: [] };
}

function stateDirFor(projectRoot) {
  return path.join(projectRoot, ...STATE_SEGMENTS);
}

function stateComponentsSafe(rootReal) {
  let seen = rootReal;
  for (const segment of STATE_SEGMENTS) {
    seen = path.join(seen, segment);
    let info;
    try { info = fs.lstatSync(seen); }
    catch (_error) { return false; }
    if (!info.isDirectory()) return false;
  }
  return true;
}

function memoryPathAllowed(memoryPath, projectRoot) {
  const reason = REASONS.MEMORY_PATH_REFUSED;
  if (typeof memoryPath !== 'string' || !path.isAbsolute(memoryPath)) return { ok: false, reason };
  if (typeof projectRoot !== 'string' || !path.isAbsolute(projectRoot)) return { ok: false, reason };
  if (!MEMORY_NAME_RE.test(path.basename(memoryPath))) return { ok: false, reason };
  let rootReal;
  try { rootReal = fs.realpathSync.native(projectRoot); }
  catch (_error) { return { ok: false, reason }; }
  const stateDir = stateDirFor(rootReal);
  if (path.dirname(memoryPath) !== stateDir) return { ok: false, reason };
  if (!stateComponentsSafe(rootReal)) return { ok: false, reason };
  let leaf = null;
  try { leaf = fs.lstatSync(memoryPath); }
  catch (error) {
    if (!error || error.code !== 'ENOENT') return { ok: false, reason };
  }
  if (leaf && (!leaf.isFile() || leaf.nlink !== 1)) return { ok: false, reason };
  return { ok: true, stateDir };
}

function readMemory(memoryPath) {
  if (typeof memoryPath !== 'string' || !memoryPath) return { ok: true, records: [], absent: true };
  let info;
  try { info = fs.lstatSync(memoryPath); }
  catch (error) {
    if (error && error.code === 'ENOENT') return { ok: true, records: [], absent: true };
    return { ok: false, reason: REASONS.MEMORY_UNREADABLE, records: [] };
  }
  if (!info.isFile() || info.nlink !== 1 || info.size > MAX_MEMORY_BYTES) {
    return { ok: false, reason: REASONS.MEMORY_UNREADABLE, records: [] };
  }
  let parsed;
  try { parsed = JSON.parse(fs.readFileSync(memoryPath, 'utf8')); }
  catch (_error) { return { ok: false, reason: REASONS.MEMORY_UNREADABLE, records: [] }; }
  if (!parsed || typeof parsed !== 'object' || parsed.version !== MEMORY_VERSION || !Array.isArray(parsed.records)
      || parsed.records.length > MAX_RECORDS || !parsed.records.every(validRecord)) {
    return { ok: false, reason: REASONS.MEMORY_UNREADABLE, records: [] };
  }
  return { ok: true, records: parsed.records, absent: false };
}

function readConsentMemory(memoryPath, projectRoot) {
  if (typeof memoryPath !== 'string' || memoryPath === '') return { ok: true, records: [], absent: true };
  const allowed = memoryPathAllowed(memoryPath, projectRoot);
  if (!allowed.ok) return { ok: false, reason: allowed.reason, records: [] };
  return readMemory(memoryPath);
}

function appendRecord(memoryPath, record, options = {}) {
  if (!validRecord(record)) return { ok: false, reason: 'record-invalid' };
  const allowed = memoryPathAllowed(memoryPath, options.projectRoot);
  if (!allowed.ok) return allowed;
  const current = readMemory(memoryPath);
  if (!current.ok) return { ok: false, reason: current.reason || REASONS.MEMORY_UNREADABLE };
  const records = current.records.slice();
  if (records.some((entry) => entry.origin === record.origin && entry.route === record.route)) {
    return { ok: true, records, duplicate: true };
  }
  if (records.length >= MAX_RECORDS) return { ok: false, reason: 'memory-full' };
  records.push({ origin: record.origin, route: record.route, decidedBy: record.decidedBy, at: record.at });
  const body = `${JSON.stringify({ version: MEMORY_VERSION, records })}\n`;
  if (Buffer.byteLength(body) > MAX_MEMORY_BYTES) return { ok: false, reason: 'memory-would-exceed-read-cap' };
  const temp = path.join(allowed.stateDir, `.${path.basename(memoryPath)}.${process.pid}.${crypto.randomBytes(6).toString('hex')}.tmp`);
  try {
    const fd = fs.openSync(temp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
    try {
      fs.writeSync(fd, body);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(temp, memoryPath);
  } catch (error) {
    try { fs.unlinkSync(temp); } catch (_ignore) { /* nothing to remove */ }
    return { ok: false, reason: `memory-write-failed:${error && error.code ? error.code : 'unknown'}` };
  }
  return { ok: true, records, duplicate: false };
}

function normalizeRoutes(declaredRoutes) {
  if (!Array.isArray(declaredRoutes)) return [];
  const routes = [];
  for (const route of declaredRoutes) {
    const normalized = floor.normalizeRoute(route);
    if (normalized !== null && !routes.includes(normalized)) routes.push(normalized);
  }
  return routes;
}

const MAX_RECIPE_BYTES = 262144;
const RECIPE_NAMES = Object.freeze(['runtime.yaml', 'autopilot.yaml']);

function resolveRecipeFile(projectRoot) {
  if (typeof projectRoot !== 'string' || !projectRoot) return '';
  const zensuDir = path.join(projectRoot, '.zensu');
  let dirInfo;
  try { dirInfo = fs.lstatSync(zensuDir); }
  catch (_error) { return ''; }
  if (!dirInfo.isDirectory()) return '';
  for (const name of RECIPE_NAMES) {
    const candidate = path.join(zensuDir, name);
    let info;
    try { info = fs.lstatSync(candidate); }
    catch (_error) { continue; }
    if (info.isFile()) return candidate;
  }
  return '';
}

function declaredRoutesFromRecipe(text) {
  const lines = String(text).split(/\r?\n/);
  const validateAt = lines.findIndex((line) => /^validate:\s*$/.test(line));
  if (validateAt === -1) return [];
  let start = -1;
  for (let index = validateAt + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (!line.trim()) continue;
    const indent = (line.match(/^\s*/) || [''])[0].length;
    if (indent <= 0) break;
    if (/^\s*evidenceSafety:\s*$/.test(line)) { start = index; break; }
  }
  if (start === -1) return [];
  const blockIndent = (lines[start].match(/^\s*/) || [''])[0].length;
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (!line.trim()) continue;
    const indent = (line.match(/^\s*/) || [''])[0].length;
    if (indent <= blockIndent) break;
    const flow = line.match(/^\s*routes:\s*\[(.*)\]\s*$/);
    if (flow) {
      return normalizeRoutes(flow[1].split(',').map((item) => item.trim().replace(/^["']|["']$/g, '')).filter(Boolean));
    }
    if (/^\s*routes:\s*$/.test(line)) {
      const routes = [];
      for (let inner = index + 1; inner < lines.length; inner += 1) {
        const item = lines[inner].match(/^\s*-\s*(.+?)\s*$/);
        if (!item) break;
        routes.push(item[1].replace(/^["']|["']$/g, ''));
      }
      return normalizeRoutes(routes);
    }
  }
  return [];
}

function readRecipeRoutes(recipeFile) {
  if (typeof recipeFile !== 'string' || !recipeFile) return [];
  let info;
  try { info = fs.lstatSync(recipeFile); }
  catch (_error) { return []; }
  if (!info.isFile() || info.size > MAX_RECIPE_BYTES) return [];
  try {
    return declaredRoutesFromRecipe(fs.readFileSync(recipeFile, 'utf8'));
  } catch (_error) {
    return [];
  }
}

const MAX_PROMPT_ROUTE = 120;
const MAX_PROMPT_ROUTES = 12;
const MAX_PROMPT_ROUTES_TEXT = 320;

function promptRoute(route) {
  const clean = (typeof route === 'string' ? route : '').replace(/[\u0000-\u001f\u007f]/g, '');
  return clean.length > MAX_PROMPT_ROUTE ? `${clean.slice(0, MAX_PROMPT_ROUTE)}…` : clean;
}

function promptRoutes(routes) {
  const shown = [];
  let width = 0;
  for (const route of routes.slice(0, MAX_PROMPT_ROUTES)) {
    const rendered = promptRoute(route);
    const cost = shown.length === 0 ? rendered.length : rendered.length + 2;
    if (shown.length > 0 && width + cost > MAX_PROMPT_ROUTES_TEXT) break;
    shown.push(rendered);
    width += cost;
  }
  const dropped = routes.length - shown.length;
  const list = shown.join(', ');
  return dropped > 0 ? `${list} (and ${dropped} more)` : list;
}

function promptText({ origins, session, declaredRoutes }) {
  const routes = normalizeRoutes(declaredRoutes);
  const plural = origins.length > 1;
  const lines = [];
  lines.push(`The playwright-cli browser session ${session} is about to reach ${origins.join(', ')} (local loopback).`);
  lines.push(`Answering Yes approves ${plural ? 'these origins' : 'this origin'} for the rest of this Claude Code session: the model may then open, read and interact with (click, type, submit forms on) any page on ${plural ? 'them' : 'it'}, screenshots included, without asking again. Consent is per origin, never per route.`);
  if (routes.length > 0) lines.push(`The run declares these routes as synthetic-safe: ${promptRoutes(routes)}.`);
  lines.push(`Answer No to keep the browser away from ${plural ? 'them' : 'it'}; the run then reports PARTIAL.`);
  return lines.join(' ');
}

function sameKeys(value, expected) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  return JSON.stringify(Object.keys(value).sort()) === JSON.stringify(expected.slice().sort());
}

function runConfigShape(config, configPath) {
  const fail = (fault) => ({ ok: false, fault });
  if (!sameKeys(config, ['browser', 'network', 'outputDir'])) return fail('the run config carries keys beyond browser, network and outputDir');
  const { browser, network } = config;
  if (!sameKeys(browser, ['isolated', 'launchOptions', 'contextOptions'])) return fail('the run config browser block carries unexpected keys');
  if (browser.isolated !== true) return fail('the run config must keep the browser isolated');
  if (!sameKeys(browser.launchOptions, ['args'])) return fail('the run config launchOptions carry unexpected keys');
  if (!sameKeys(browser.contextOptions, ['serviceWorkers']) || browser.contextOptions.serviceWorkers !== 'block') {
    return fail('the run config must block service workers and set nothing else on the context');
  }
  if (!sameKeys(network, ['allowedOrigins'])) return fail('the run config network block carries unexpected keys');
  const origins = network.allowedOrigins;
  if (!Array.isArray(origins) || origins.length < 1 || origins.length > MAX_RUN_ORIGINS) {
    return fail(`the run config must allow between 1 and ${MAX_RUN_ORIGINS} origins`);
  }
  for (const origin of origins) {
    if (typeof origin !== 'string') return fail('the run config names a non-string origin');
    let parsed;
    try { parsed = new URL(origin); }
    catch (_error) { return fail('the run config names an invalid origin'); }
    if (parsed.origin !== origin) return fail('the run config names an origin that is not in canonical form');
  }
  if (new Set(origins).size !== origins.length) return fail('the run config names an origin twice');
  const args = browser.launchOptions.args;
  if (!Array.isArray(args) || args.length < 1 || args.length > 2 || args[0] !== '--no-proxy-server') {
    return fail('the run config launch arguments must be --no-proxy-server and at most one resolver pin list');
  }
  const pins = new Map();
  if (args.length === 2) {
    const match = typeof args[1] === 'string' ? args[1].match(/^--host-resolver-rules=(.+)$/) : null;
    if (!match) return fail('the run config carries a launch argument other than a resolver pin list');
    for (const rule of match[1].split(',')) {
      const pin = rule.match(/^MAP (\S+) (\S+)$/);
      if (!pin) return fail('the run config carries a resolver rule other than MAP <host> <address>');
      const host = pin[1].toLowerCase();
      const address = pin[2].replace(/^\[|\]$/g, '');
      if (net.isIP(host) || pins.has(host)) return fail('the run config pins an address literal or pins a host twice');
      if (!floor.isPublicAddress(address)) return fail('the run config pins a host to an address that is not globally routable');
      pins.set(host, address);
    }
  }
  for (const host of pins.keys()) {
    if (!origins.some((origin) => floor.normalizeHostname(new URL(origin).hostname) === host)) {
      return fail('the run config pins a host that is not among its allowed origins');
    }
  }
  if (typeof config.outputDir !== 'string' || !path.isAbsolute(config.outputDir)) return fail('the run config outputDir must be absolute');
  let configDir;
  try { configDir = fs.realpathSync.native(path.dirname(configPath)); }
  catch (_error) { return fail('the run config directory cannot be resolved'); }
  if (config.outputDir !== path.join(configDir, RUN_OUTPUT_DIR_NAME)) {
    return fail(`the run config outputDir must be the ${RUN_OUTPUT_DIR_NAME} directory beside the config file`);
  }
  return { ok: true, origins: origins.slice(), pins };
}

function readRunConfig(rawPath) {
  if (typeof rawPath !== 'string' || rawPath === '') return { ok: false, fault: REASONS.CONFIG_REQUIRED };
  const configPath = msysDrivePrefix(rawPath);
  if (!path.isAbsolute(configPath)) return { ok: false, fault: REASONS.CONFIG_REQUIRED };
  let info;
  try { info = fs.lstatSync(configPath); }
  catch (_error) { return { ok: false, fault: 'the --config file does not exist' }; }
  if (!info.isFile() || info.size > MAX_RUN_CONFIG_BYTES) return { ok: false, fault: 'the --config file is not a plain file within the size bound' };
  let parsed;
  try { parsed = JSON.parse(fs.readFileSync(configPath, 'utf8')); }
  catch (_error) { return { ok: false, fault: 'the --config file is not valid JSON' }; }
  const shape = runConfigShape(parsed, configPath);
  if (!shape.ok) return shape;
  return Object.assign({ configPath }, shape);
}

function harmlessKeyPath(value, allowed, prefix) {
  if (allowed === '*' || allowed === true) return '';
  if (!value || typeof value !== 'object' || Array.isArray(value)) return prefix || '(root)';
  for (const key of Object.keys(value)) {
    if (!Object.prototype.hasOwnProperty.call(allowed, key)) return prefix ? `${prefix}.${key}` : key;
    const nested = harmlessKeyPath(value[key], allowed[key], prefix ? `${prefix}.${key}` : key);
    if (nested) return nested;
  }
  return '';
}

function globalConfigFile(env) {
  const base = env && typeof env.PWTEST_CLI_GLOBAL_CONFIG === 'string' && env.PWTEST_CLI_GLOBAL_CONFIG !== ''
    ? env.PWTEST_CLI_GLOBAL_CONFIG
    : os.homedir();
  return path.join(base, '.playwright', 'cli.config.json');
}

function globalConfigFault(env) {
  const file = globalConfigFile(env);
  let info;
  try { info = fs.lstatSync(file); }
  catch (error) {
    if (error && error.code === 'ENOENT') return '';
    return 'the global playwright-cli config could not be inspected';
  }
  if (!info.isFile() || info.size > MAX_GLOBAL_CONFIG_BYTES) return 'the global playwright-cli config is not a plain file within the size bound';
  let parsed;
  try {
    const raw = fs.readFileSync(file, 'utf8');
    parsed = JSON.parse(raw.charCodeAt(0) === 65279 ? raw.slice(1) : raw);
  } catch (_error) {
    return 'the global playwright-cli config is not JSON the gate can judge';
  }
  const offending = harmlessKeyPath(parsed, GLOBAL_CONFIG_HARMLESS, '');
  if (offending) return `the global playwright-cli config sets ${offending}, which would merge under the run config`;
  const browser = parsed && typeof parsed === 'object' ? parsed.browser : undefined;
  if (browser && typeof browser === 'object' && browser.browserName !== undefined && browser.browserName !== 'chromium') {
    return REASONS.GLOBAL_BROWSER_NOT_CHROMIUM;
  }
  return '';
}

function ambientOverride(env) {
  for (const name of Object.keys(env || {})) {
    if (/^PLAYWRIGHT_MCP_/.test(name) && env[name] !== undefined && env[name] !== '') return name;
  }
  return '';
}

function readPolicy(env) {
  const raw = env && typeof env.ZENSU_VERIFY_NAVIGATION_POLICY_V1 === 'string' ? env.ZENSU_VERIFY_NAVIGATION_POLICY_V1 : '';
  if (raw === '') return null;
  const parsed = floor.parsePolicyTargets(raw);
  return parsed.ok ? { ok: true, mode: parsed.mode, targets: parsed.targets } : { ok: false, fault: parsed.fault };
}

function readInputs(env) {
  const projectRoot = env.ZENSU_VERIFY_PROJECT_ROOT || '';
  return {
    memoryPath: env.ZENSU_VERIFY_CONSENT_MEMORY || '',
    projectRoot,
    declaredRoutes: readRecipeRoutes(resolveRecipeFile(projectRoot)),
    policy: readPolicy(env),
  };
}

function judgeOrigin(rawUrl, options) {
  const classified = floor.classifyOrigin(rawUrl, options.navigation);
  if (!classified.ok) return { deny: classified.reason };
  const { origin, pathname: route, mode, hostname } = classified;
  if (options.policy) {
    if (!options.policy.ok) return { deny: `${REASONS.POLICY_INVALID}: ${options.policy.fault}` };
    const target = options.policy.targets.get(origin);
    if (!target) return { deny: `${origin}: ${REASONS.NOT_POLICY_TARGET}` };
    if (options.navigation && !target.routes.has(route)) return { deny: `${origin}${route}: ${REASONS.NOT_POLICY_ROUTE}` };
    if (mode === 'remote' && !net.isIP(hostname) && options.pins && !options.pins.has(hostname)) {
      return { deny: `${origin}: the run config carries no resolver pin for this remote host` };
    }
    return { origin, route, mode, decidedBy: 'policy-mode' };
  }
  if (mode !== 'local') return { deny: REASONS.REMOTE_NEEDS_POLICY };
  return { origin, route, mode };
}

function judgeCall(call, context) {
  if (call.fault) return { deny: call.fault };
  const { args, session } = call;
  if (context.principal !== principals.PRINCIPALS.MAIN) return { deny: REASONS.NOT_MAIN_THREAD };
  if (typeof session.value !== 'string' || !SESSION_RE.test(session.value)) return { deny: REASONS.SESSION_MALFORMED };
  if (call.invocation.assignments.some((item) => item.name !== SESSION_ENV)) return { deny: REASONS.ENV_ASSIGNMENT };
  if (call.invocation.wrappers.some((name) => ['env', 'sudo', 'doas'].includes(name))) return { deny: REASONS.ENV_ASSIGNMENT };
  if (call.invocation.wrappers.length > 0) return { deny: REASONS.WRAPPER };
  if (call.invocation.launcher) return { deny: REASONS.LAUNCHER };
  if (!call.invocation.bare) return { deny: REASONS.CLI_NOT_BARE };
  const flagKeys = Object.keys(args).filter((key) => key !== '_' && key !== 'session');
  if (flagKeys.some((key) => hasSentinel(key) || hasSentinel(args[key])) || args._.some(hasSentinel)) {
    return { deny: REASONS.ARGUMENT_UNEXPANDED };
  }
  const command = args._[0];
  if (command === undefined) return { targets: [] };
  if (!Object.prototype.hasOwnProperty.call(ALLOWED_COMMANDS, command)) return { deny: `command '${command}' ${REASONS.COMMAND_DENIED}` };
  const allowedFlags = ALLOWED_COMMANDS[command];
  for (const key of flagKeys) {
    if (!allowedFlags.includes(key) && !HARMLESS_FLAGS.includes(key)) return { deny: `flag '--${key}' ${REASONS.FLAG_DENIED}` };
    if (Array.isArray(args[key])) return { deny: `flag '--${key}' is given more than once` };
  }
  const positional = args._.slice(1);
  const targets = [];
  let pins = null;
  let configOrigins = [];
  if (command === 'open') {
    if (args.browser !== undefined && !CHROMIUM_BROWSERS.includes(args.browser)) return { deny: REASONS.BROWSER_NOT_CHROMIUM };
    if (typeof args.config !== 'string') return { deny: REASONS.CONFIG_REQUIRED };
    const config = readRunConfig(args.config);
    if (!config.ok) return { deny: config.fault };
    const ambient = ambientOverride(context.env);
    if (ambient) return { deny: `the launch environment sets ${ambient}, which overrides the run config` };
    const globalFault = globalConfigFault(context.env);
    if (globalFault) return { deny: globalFault };
    pins = config.pins;
    configOrigins = config.origins;
    for (const origin of configOrigins) {
      const judged = judgeOrigin(origin, { navigation: false, policy: context.policy, pins });
      if (judged.deny) return { deny: judged.deny };
      targets.push({ origin: judged.origin, route: '/', mode: judged.mode, decidedBy: judged.decidedBy });
    }
  }
  if (NAVIGATION_COMMANDS.includes(command) && positional.length > 0) {
    const url = positional[0];
    const judged = judgeOrigin(url, { navigation: true, policy: context.policy, pins });
    if (judged.deny) return { deny: judged.deny };
    if (command === 'open' && !configOrigins.includes(judged.origin)) return { deny: REASONS.OPEN_OUTSIDE_CONFIG };
    const existing = targets.find((item) => item.origin === judged.origin);
    if (existing) existing.route = judged.route;
    else targets.push({ origin: judged.origin, route: judged.route, mode: judged.mode, decidedBy: judged.decidedBy });
  }
  return { targets, session: session.value };
}

function principalOf(payload) {
  try { return principals.classifyPreToolPayload(payload); }
  catch (_error) { return ''; }
}

function evaluate({ command, payload, env, records, declaredRoutes, policy, platform }) {
  if (typeof command !== 'string' || command === '') return { verdict: 'none' };
  const marks = commandMarkers(command, env);
  if (!marks.cli) return { verdict: 'none' };
  if (Buffer.byteLength(command) > MAX_COMMAND_BYTES) {
    return marks.session ? { verdict: 'deny', reason: REASONS.COMMAND_TOO_LARGE } : { verdict: 'none' };
  }
  if (marks.session && REDEFINITION_RE.test(command)) return { verdict: 'deny', reason: REASONS.REDEFINED };
  const analysis = analyzeCommand(command, env, platform);
  if (analysis.unjudged) return { verdict: 'deny', reason: REASONS.UNJUDGED_BODY };
  if (analysis.indirect) return { verdict: 'deny', reason: REASONS.INDIRECT };
  const gated = analysis.calls.filter((call) => call.gated);
  if (gated.length === 0 && !marks.session) return { verdict: 'none' };
  if (analysis.envBuiltin) return { verdict: 'deny', reason: REASONS.ENV_BUILTIN };
  if (AMBIENT_TEXT_RE.test(command) || AMBIENT_TEXT_RE.test(strippedText(command))) {
    return { verdict: 'deny', reason: REASONS.AMBIENT_TEXT };
  }
  if (gated.length === 0) {
    if (!analysis.plain) return { verdict: 'deny', reason: REASONS.NOT_PLAIN };
    return marks.named ? { verdict: 'deny', reason: REASONS.SESSION_UNRESOLVED } : { verdict: 'none' };
  }
  const context = { principal: principalOf(payload || {}), env: env || {}, policy };
  const known = new Set((Array.isArray(records) ? records : []).map((entry) => entry.origin));
  const plan = [];
  const fresh = [];
  let session = '';
  for (const call of gated) {
    const judged = judgeCall(call, context);
    if (judged.deny) return { verdict: 'deny', reason: judged.deny };
    session = session || judged.session || '';
    for (const target of judged.targets) {
      const decidedBy = target.decidedBy || (known.has(target.origin) ? 'remembered' : 'asked');
      plan.push({ origin: target.origin, route: target.route, decidedBy });
      if (decidedBy === 'asked' && !fresh.includes(target.origin)) fresh.push(target.origin);
    }
  }
  if (!analysis.plain) return { verdict: 'deny', reason: REASONS.NOT_PLAIN };
  if (fresh.length > 0) {
    return { verdict: 'ask', reason: REASONS.NEW_ORIGIN, plan, origins: fresh, prompt: promptText({ origins: fresh, session, declaredRoutes }) };
  }
  return { verdict: 'none', plan };
}

function preEnvelope(decision) {
  if (decision.verdict !== 'ask' && decision.verdict !== 'deny') return null;
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: decision.verdict,
      permissionDecisionReason: decision.verdict === 'ask'
        ? decision.prompt
        : `Zensu browser consent gate denied the playwright-cli call: ${decision.reason}${SHAPE_TEXTS.has(decision.reason) ? ` ${SHAPE_MARKER}` : ''}`,
    },
  };
}

function commandOf(payload) {
  if (!payload || typeof payload !== 'object' || payload.tool_name !== 'Bash') return null;
  const input = payload.tool_input;
  return input && typeof input === 'object' && typeof input.command === 'string' ? input.command : null;
}

function runPre(payload, env, out, err) {
  if (!payload || typeof payload !== 'object' || typeof payload.tool_name !== 'string') {
    out.write(JSON.stringify(preEnvelope({ verdict: 'deny', reason: REASONS.PAYLOAD_UNREADABLE })));
    return true;
  }
  const command = commandOf(payload);
  if (command === null) return false;
  const inputs = readInputs(env);
  const memory = readConsentMemory(inputs.memoryPath, inputs.projectRoot);
  const decision = evaluate({
    command,
    payload,
    env,
    records: memory.records,
    declaredRoutes: inputs.declaredRoutes,
    policy: inputs.policy,
  });
  if (!memory.ok && decision.verdict === 'ask') err.write(`zensu: verify consent memory ignored (${memory.reason}); the call asks again\n`);
  const envelope = preEnvelope(decision);
  if (!envelope) return false;
  out.write(JSON.stringify(envelope));
  return true;
}

function runPost(payload, env, err) {
  if (!payload || typeof payload !== 'object' || typeof payload.tool_name !== 'string') {
    err.write(`zensu: verify consent memory not written (${REASONS.PAYLOAD_UNREADABLE})\n`);
    return { ok: false, reason: REASONS.PAYLOAD_UNREADABLE };
  }
  const command = commandOf(payload);
  if (command === null) return { ok: true, skipped: 'not-a-bash-call' };
  const response = payload.tool_response;
  if (response && typeof response === 'object' && response.interrupted === true) return { ok: true, skipped: 'interrupted' };
  const inputs = readInputs(env);
  const memory = readConsentMemory(inputs.memoryPath, inputs.projectRoot);
  const decision = evaluate({
    command,
    payload,
    env,
    records: memory.records,
    declaredRoutes: inputs.declaredRoutes,
    policy: inputs.policy,
  });
  if (decision.verdict === 'deny' || !Array.isArray(decision.plan) || decision.plan.length === 0) {
    return { ok: true, skipped: decision.reason || 'nothing-to-record' };
  }
  if (inputs.memoryPath === '') {
    err.write('zensu: verify consent memory not written (no bound session)\n');
    return { ok: false, reason: 'no-bound-session' };
  }
  const at = new Date().toISOString();
  let last = { ok: true };
  for (const entry of decision.plan) {
    const result = appendRecord(inputs.memoryPath, { origin: entry.origin, route: entry.route, decidedBy: entry.decidedBy, at }, { projectRoot: inputs.projectRoot });
    if (!result.ok) {
      err.write(`zensu: verify consent memory not written (${result.reason})\n`);
      return result;
    }
    last = result;
  }
  return last;
}

function hookRegistered(pluginRoot, event, hookFile) {
  const hookPath = path.join(pluginRoot, 'hooks', hookFile);
  const hooksJson = path.join(pluginRoot, 'hooks', 'hooks.json');
  try {
    if (!fs.statSync(hookPath).isFile()) return REGISTRATION.UNREGISTERED;
  } catch (error) {
    return error && error.code === 'ENOENT' ? REGISTRATION.UNREGISTERED : REGISTRATION.UNKNOWN;
  }
  let manifest;
  try {
    if (!fs.lstatSync(hooksJson).isFile()) return REGISTRATION.UNKNOWN;
    manifest = JSON.parse(fs.readFileSync(hooksJson, 'utf8'));
  } catch (_error) {
    return REGISTRATION.UNKNOWN;
  }
  return hookRegistration.registration(manifest, {
    event,
    tools: [CONSENT_MATCHER],
    names: (command) => command.includes(`/hooks/${hookFile}`),
    reading: hookRegistration.READINGS.HOST,
  });
}

function consentHookRegistered(pluginRoot) {
  return hookRegistered(pluginRoot, 'PreToolUse', CONSENT_HOOK_FILE);
}

function consentRecorderRegistered(pluginRoot) {
  return hookRegistered(pluginRoot, 'PostToolUse', CONSENT_RECORDER_FILE);
}

function recordingStream(out) {
  const state = { emitted: false };
  return {
    emitted: () => state.emitted,
    write: (chunk) => { state.emitted = true; return out.write(chunk); },
  };
}

module.exports = {
  ALLOWED_COMMANDS,
  CLI_BASENAMES,
  CLI_BOOLEAN_OPTIONS,
  CLI_STRING_OPTIONS,
  CHROMIUM_BROWSERS,
  CLI_PACKAGE,
  CLI_MARKERS,
  CONSENT_HOOK_FILE,
  CONSENT_MATCHER,
  CONSENT_RECORDER_FILE,
  DECIDED_BY,
  FINAL_REASONS,
  GLOBAL_CONFIG_HARMLESS,
  MAX_MEMORY_BYTES,
  MAX_PROMPT_ROUTE,
  MAX_PROMPT_ROUTES,
  MAX_PROMPT_ROUTES_TEXT,
  MAX_RECIPE_BYTES,
  MAX_RECORDS,
  MAX_RUN_ORIGINS,
  MEMORY_NAME_PREFIX,
  MEMORY_NAME_RE,
  MEMORY_VERSION,
  NAVIGATION_COMMANDS,
  PLAYWRIGHT_CLI_SOURCE_VERSION,
  REASONS,
  RECIPE_NAMES,
  REGISTRATION,
  RUN_CONFIG_NAME,
  RUN_OUTPUT_DIR_NAME,
  SESSION_ENV,
  SHAPE_MARKER,
  SHAPE_REASONS,
  SESSION_PREFIX,
  SESSION_RE,
  STATE_SEGMENTS,
  analyzeCommand,
  appendRecord,
  commandMarkers,
  consentHookRegistered,
  consentRecorderRegistered,
  declaredRoutesFromRecipe,
  emptyMemory,
  evaluate,
  globalConfigFault,
  globalConfigFile,
  isIsoInstant,
  judgeOrigin,
  lexShell,
  memoryPathAllowed,
  normalizeRoutes,
  parseCliArgs,
  payloadFromRaw,
  preEnvelope,
  promptRoute,
  promptRoutes,
  promptText,
  readConsentMemory,
  readInputs,
  readMemory,
  readPolicy,
  readRecipeRoutes,
  readRunConfig,
  recordingStream,
  resolveRecipeFile,
  runConfigShape,
  runPost,
  runPre,
  stateDirFor,
  validRecord,
};

if (require.main === module) {
  const mode = process.argv[2];
  if (mode !== 'pre' && mode !== 'post') {
    process.stderr.write('usage: verify-consent-v1.js pre|post\n');
    process.exitCode = 2;
  } else {
    let raw = '';
    let accumulationFailed = false;
    let settled = false;
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => {
      if (accumulationFailed) return;
      try { raw += chunk; } catch (_error) { accumulationFailed = true; raw = ''; }
    });
    const finalize = () => {
      if (settled) return;
      settled = true;
      const payload = payloadFromRaw(raw, accumulationFailed);
      const recorder = recordingStream(process.stdout);
      try {
        if (mode === 'pre') runPre(payload, process.env, recorder, process.stderr);
        else runPost(payload, process.env, process.stderr);
      } catch (error) {
        if (mode === 'pre') {
          if (!recorder.emitted()) {
            process.stdout.write(JSON.stringify(preEnvelope({ verdict: 'deny', reason: `hook-failed:${error && error.code ? error.code : 'unknown'}` })));
          }
          process.exitCode = 2;
        } else {
          process.stderr.write('zensu: verify consent memory not written (hook failed)\n');
        }
      }
    };
    process.stdin.on('error', () => { accumulationFailed = true; raw = ''; finalize(); });
    process.stdin.on('end', finalize);
    process.stdin.on('close', finalize);
  }
}
