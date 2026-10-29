'use strict';

const fs = require('node:fs');
const os = require('node:os');
const hostPaths = require('./claude-path-v1.js');
const principals = require('./claude-principal-v1.js');

const CONFIG_KEY = 'subagentShell';
const GUARD_TAIL = 'The guard prevents accidents and is not a sandbox; report the need to the main thread instead.';
const GRANT_TAIL = 'Report the need to the main thread instead.';
const PERSONA_RE = /(?:^|:)zensu-review-/i;
const READ_ONLY_TYPES = new Set([
  ...principals.REVIEWER_TYPES,
  ...principals.PLM_TYPES,
  ...principals.EVIDENCE_WORKER_TYPES,
]);

const REASONS = Object.freeze({
  background: 'a background shell outlives the subagent that started it',
  sandbox: 'the command asks to run outside the host sandbox',
  protectedPath: 'the command names the private plugin data, the installed plugin, the session record or the Zensu config file',
  protectedParent: 'the command names a parent directory of protected Zensu state',
  workflowDirectory: 'the command names a .zensu directory, which holds Zensu workflow state or configuration',
  helper: 'the command runs a Zensu session or workflow helper',
  selector: 'the command reads or sets a Session Control selector variable',
  dump: 'the command prints the inherited environment',
  plugin: 'the command manages Claude Code plugins',
  projectRoot: 'the command removes or moves the project root or one of its parents',
  directories: 'the command changes directory more often than the guard can follow',
});
const MENTIONS = Object.freeze({
  protectedPath: 'its input names the private plugin data, the installed plugin, the session record or the Zensu config file',
  workflowDirectory: 'its input names a .zensu directory, which holds Zensu workflow state or configuration',
  dump: 'its input names the environment file of a process',
  protectedParent: 'its input names a parent directory of the private plugin data, the installed plugin or the session record, whose listing would show Zensu state',
});

const SELECTOR = 'CLAUDE_CODE_SESSION_ID|CLAUDE_PLUGIN_[A-Za-z0-9_]*|CLAUDE_ENV_FILE|ZENSU_[A-Za-z0-9_]+';
const SELECTOR_NAME_RE = new RegExp(`^(?:${SELECTOR})$`);
const SELECTOR_WORD_RE = new RegExp(`^(?:${SELECTOR})(?:=|$)`);
const SELECTOR_IN_TEXT_RE = new RegExp(`(?:^|[^A-Za-z0-9_])(?:${SELECTOR})(?![A-Za-z0-9_])`);
const SELECTOR_ACCESS_RE = new RegExp(
  `(?:\\b(?:env|environ)\\s*(?:\\?\\.|\\.|\\[)\\s*(?:(?:get|fetch|setdefault|pop)\\s*\\(\\s*)?['"]?|\\b(?:get|str)?env\\s*\\(\\s*['"]?|\\$env:|\\$ENV\\s*\\{\\s*['"]?|\\$_(?:ENV|SERVER)\\s*\\[\\s*['"]?)(?:${SELECTOR})(?![A-Za-z0-9_])`,
  'i',
);
const SELECTOR_COMMANDS = new Set(['export', 'unset', 'printenv', 'declare', 'typeset', 'readonly', 'local']);
const TEST_COMMANDS = new Set(['test', '[', '[[']);

const TEXT_DUMP_RES = Object.freeze([
  /\/proc\/[^\s/]+\/environ\b/,
]);
const CODE_DUMP_RES = Object.freeze([
  /\bprocess\.env\b(?!\s*(?:\?\.|\.|\[))/,
  /\bBun\.env\b(?!\s*(?:\?\.|\.|\[))/,
  /\bDeno\.env\s*\.\s*toObject\b/,
  /\bos\.environ\b(?!\s*(?:\.|\[))/,
  /\bos\.environ\s*\.\s*(?:items|keys|values|copy)\b/,
  /%ENV\b/,
  /\bENV\.(?:to_h|to_hash|to_a|each\w*|keys|values|inspect|select|filter|map)\b/,
  /(?:^|[\s;(])(?:p|pp|puts|print)\s*\(?\s*ENV\b(?!\s*(?:\[|\.))/,
  /\b(?:System\.)?getenv\s*\(\s*\)/,
  /GetEnvironmentVariables\b/i,
  /(?:^|[\s;|&(])(?:get-childitem|gci|ls|dir)\s+env:(?=$|[\s;|&)])/i,
  /\bENVIRON\b(?!\s*\[)/,
  /\$_(?:ENV|SERVER)\b(?!\s*\[)/,
]);
const JQ_ENV_RE = /(?:^|[^A-Za-z0-9_$.])(?:env|\$ENV)(?![A-Za-z0-9_])(?!\s*(?:\.\s*[A-Za-z_"]|\[))/;
const INDIRECT_LISTING_RE = /^![A-Za-z_][A-Za-z0-9_]*[*@]$/;
const NAME_ONLY_DECLARATIONS = new Set(['export', 'declare', 'typeset', 'readonly']);

const NODE_CODE_FLAGS = Object.freeze(['-e', '--eval', '-p', '--print']);
const PYTHON_CODE_FLAGS = Object.freeze(['-c']);
const INLINE_CODE_FLAGS = new Map([
  ['node', NODE_CODE_FLAGS],
  ['nodejs', NODE_CODE_FLAGS],
  ['bun', NODE_CODE_FLAGS],
  ['ruby', ['-e']],
  ['perl', ['-e', '-E']],
  ['php', ['-r']],
  ['lua', ['-e']],
  ['luajit', ['-e']],
  ['rscript', ['-e']],
  ['r', ['-e']],
  ['osascript', ['-e']],
]);
const STDIN_CODE = new Set(['node', 'nodejs', 'bun', 'ruby', 'perl', 'php', 'lua', 'luajit']);
const PYTHON_RE = /^(?:python|pypy)[0-9.]*$/;
const AWK_COMMANDS = new Set(['awk', 'gawk', 'mawk', 'nawk']);
const AWK_VALUE_OPTIONS = new Set(['-F', '-v', '-i', '-l', '--assign', '--field-separator', '--include', '--load']);
const JQ_COMMANDS = new Set(['jq', 'gojq', 'jaq', 'yq']);
const JQ_VALUE_OPTIONS = new Map([['--arg', 2], ['--argjson', 2], ['--slurpfile', 2], ['--rawfile', 2], ['--indent', 1], ['-L', 1]]);
const YQ_SUBCOMMANDS = new Set(['e', 'eval', 'ea', 'eval-all']);
const POWERSHELL = new Set(['pwsh', 'powershell']);

const HELPER_RE = /(?:^|[/(,=:'"`])(?:zensu-log\.sh|zensu-session[a-z0-9._-]*\.sh|zensu-doctor\.sh|zensu-review-evidence\.sh|(?:claude-hook-session-v1|claude-session-control-v1|session-control-core-v1|review-evidence-lease-v1|session-auto-adopt-v1)(?:\.js)?|zensu_bind_[a-z0-9_]+|model-bind)(?=$|[)\s;,:'"`])/i;
const READ_ONLY_COMMANDS = new Set([
  'cat', 'tac', 'head', 'tail', 'less', 'more', 'bat', 'batcat', 'nl', 'od', 'xxd', 'hexdump',
  'strings', 'wc', 'cut', 'sort', 'uniq', 'tr', 'fold', 'column', 'paste', 'comm', 'fmt',
  'grep', 'egrep', 'fgrep', 'rg', 'ag', 'ack', 'git', 'diff', 'cmp', 'sdiff', 'colordiff', 'delta',
  'sed', 'awk', 'gawk', 'mawk', 'nawk', 'ls', 'tree', 'stat', 'file', 'du', 'realpath', 'readlink',
  'dirname', 'basename', 'test', '[', '[[', 'echo', 'printf', 'true', 'false',
  'sha1sum', 'sha256sum', 'sha512sum', 'shasum', 'md5', 'md5sum', 'cksum', 'b2sum',
  'shellcheck', 'jq', 'yq', 'vi', 'vim', 'nvim', 'view', 'nano', 'emacs', 'code',
  'cp', 'mv', 'rm', 'touch', 'chmod', 'ln', 'mkdir', 'find', 'fd',
]);
const FIND_EXEC_WORDS = new Set(['-exec', '-execdir', '-ok', '-okdir']);
const FIND_NAME_TESTS = new Set(['-name', '-iname', '-path', '-ipath', '-wholename', '-iwholename', '-regex', '-iregex', '-lname', '-ilname', '-samefile', '-inum', '-newer']);
const SHELLS = new Set(['bash', 'sh', 'zsh', 'dash', 'ksh', 'mksh', 'fish']);
const BACKGROUND_COMMANDS = new Set(['setsid', 'disown', 'coproc']);
const TMUX_VALUE_OPTIONS = new Set(['c', 'f', 'L', 'S', 'T']);
const TMUX_PROCESS_ALIASES = new Set(['new', 'neww', 'splitw', 'respawnp', 'respawnw', 'run', 'if', 'pipep', 'send', 'pasteb', 'popup']);
const TMUX_PROCESS_COMMANDS = Object.freeze(['new-session', 'new-window', 'split-window', 'respawn-pane', 'respawn-window', 'run-shell', 'if-shell', 'pipe-pane', 'send-keys', 'paste-buffer', 'display-popup']);
const TMUX_INERT_ALIASES = new Set(['display']);
const SCREEN_ATTACHED_OPTIONS = new Set(['c', 'e', 'p']);
const SCREEN_NEXT_WORD_OPTIONS = new Set(['S', 's', 't', 'k', 'T', 'h']);
const SCREEN_SESSION_OPTIONS = new Set(['r', 'R', 'x']);
const SCREEN_COMMAND_OPTIONS = Object.freeze(['X', 'Q']);
const SCREEN_PROCESS_COMMANDS = new Set(['screen', 'exec', 'stuff', 'eval', 'at', 'paste', 'process']);
const EXIT_COMMANDS = new Set(['exit', 'return']);
const DIRECTORY_WRAPPERS = new Set(['command', 'builtin']);
const PS_ARGUMENT_OPTIONS = new Set(['-o', '-O', '-p', '-u', '-U', '-g', '-G', '-t', '-q', '-C', '--format', '--pid', '--user', '--group', '--tty', '--sort']);

const RESERVED_WORDS = new Set(['!', 'if', 'then', 'else', 'elif', 'fi', 'do', 'done', 'while', 'until', '{', '}']);
const ASSIGNMENT_RE = /^[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\+?=/;
const TIMEOUT_WRAPPER = Object.freeze({ args: ['-s', '-k', '--signal', '--kill-after'], positional: 1 });
const WRAPPERS = Object.freeze({
  env: { args: ['-u', '-C', '-S', '-P', '--unset', '--chdir', '--split-string'], positional: 0, assignments: true, chdir: { short: '-C', long: '--chdir' } },
  sudo: { args: ['-u', '-g', '-C', '-D', '-h', '-p', '-r', '-t', '-U', '-T', '--user', '--group', '--chdir'], positional: 0, assignments: true, chdir: { short: '-D', long: '--chdir' } },
  doas: { args: ['-u', '-C'], positional: 0 },
  nice: { args: ['-n', '--adjustment'], positional: 0 },
  nohup: { args: [], positional: 0 },
  exec: { args: ['-a'], positional: 0 },
  command: { args: [], positional: 0 },
  builtin: { args: [], positional: 0 },
  time: { args: ['-f', '-o', '--format', '--output'], positional: 0 },
  timeout: TIMEOUT_WRAPPER,
  gtimeout: TIMEOUT_WRAPPER,
  xargs: { args: ['-I', '-L', '-n', '-P', '-s', '-d', '-E', '-a', '--max-args', '--max-procs', '--delimiter', '--arg-file', '--replace', '--max-lines'], positional: 0 },
  stdbuf: { args: ['-i', '-o', '-e'], positional: 0 },
  caffeinate: { args: ['-w', '-t'], positional: 0 },
  unbuffer: { args: [], positional: 0 },
  watch: { args: ['-n', '-d', '--interval'], positional: 0 },
  flock: { args: ['-w', '-E', '--timeout', '--conflict-exit-code'], positional: 1 },
});
const GIT_GLOBAL_ARGS = new Set(['-c', '-C', '--git-dir', '--work-tree', '--namespace', '--exec-path', '--config-env', '--super-prefix', '--attr-source']);
const WHOLE_TREE_PATHSPECS = new Set(['.', './', ':/', ':/:', '*', '**']);
const MATCH_ALL_SEGMENTS = new Set(['*', '.*', '**']);
const REMOVING_COMMANDS = new Set(['rm', 'rmdir', 'unlink', 'mv']);
const DYNAMIC = '\u0001';
const PWD_MARK = '\u0002';
const MARKER_CHARS = new RegExp(`[${DYNAMIC}${PWD_MARK}]`, 'g');
const NEUTRAL_CHAR = String.fromCodePoint(0xfffd);
const VALUE_KEEPING_RE = /^[A-Za-z_][A-Za-z0-9_]*:?[-=?]/;
const MAX_DEPTH = 8;
const MAX_PATH_WORDS = 400;
const MAX_DIRECTORIES = 64;
const MAX_BRACE_WORDS = 256;

function boundedIdentity(value) {
  return typeof value === 'string' && value.trim() !== '' && value.length <= 512 && !/[\0\r\n]/.test(value);
}

function isPlainObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function nonEmpty(value) {
  return typeof value === 'string' && value !== '';
}

function strictCandidates(environment, platform = process.platform) {
  const spell = (value) => hostPaths.msysDrivePrefix(value, platform);
  const explicit = environment.ZENSU_CONFIG;
  if (nonEmpty(explicit)) return [spell(explicit)];
  const candidates = [];
  if (nonEmpty(environment.HOME)) candidates.push(`${spell(environment.HOME)}/.zensu/config.json`);
  if (nonEmpty(environment.CLAUDE_PROJECT_DIR)) candidates.push(`${spell(environment.CLAUDE_PROJECT_DIR)}/.zensu/config.json`);
  return candidates;
}

function absoluteCandidate(value, platform) {
  if (/[\r\n]/.test(value)) return false;
  if (value.startsWith('/')) return true;
  return platform === 'win32' && /^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/])/.test(value);
}

function strictFlagEnabled(key, environment = process.env, options = {}) {
  const platform = options.platform || process.platform;
  const fsModule = options.fs || fs;
  let candidates;
  try {
    candidates = strictCandidates(environment, platform);
  } catch {
    return false;
  }
  if (candidates.length === 0) return false;
  for (const file of candidates) {
    if (!absoluteCandidate(file, platform)) return false;
    try {
      fsModule.statSync(file);
    } catch (error) {
      if (error && error.code === 'ENOENT') continue;
      return false;
    }
    let value;
    try {
      value = JSON.parse(fsModule.readFileSync(file, 'utf8'));
    } catch {
      return false;
    }
    if (!isPlainObject(value)) return false;
    const hooks = value.hooks;
    if (hooks === undefined) continue;
    if (!isPlainObject(hooks)) return false;
    if (hooks[key] === false) return false;
  }
  return true;
}

function configLayers(environment) {
  const layers = [];
  if (nonEmpty(environment.HOME)) {
    layers.push({ directory: `${environment.HOME}/.zensu`, file: `${environment.HOME}/.zensu/config.json` });
  }
  if (nonEmpty(environment.ZENSU_CONFIG)) layers.push({ directory: null, file: environment.ZENSU_CONFIG });
  if (nonEmpty(environment.CLAUDE_PROJECT_DIR)) {
    layers.push({
      directory: `${environment.CLAUDE_PROJECT_DIR}/.zensu`,
      file: `${environment.CLAUDE_PROJECT_DIR}/.zensu/config.json`,
    });
  }
  return layers;
}

function configAuthorities(environment = process.env) {
  return configLayers(environment).flatMap((layer) => (layer.directory ? [layer.directory, layer.file] : [layer.file]));
}

function isShellCall(payload) {
  return payload.tool_name === 'Bash';
}

function grantRefusal(payload, environment = process.env, options = {}) {
  const type = payload.agent_type;
  if (!boundedIdentity(type)) {
    return 'the subagent reports no usable agent_type, so the shell grant cannot tell it from a read-only reviewer';
  }
  if (Object.prototype.hasOwnProperty.call(payload, 'agent_id') && !boundedIdentity(payload.agent_id)) {
    return 'the subagent reports an unusable agent_id, so the shell grant cannot tell it from a read-only reviewer';
  }
  if (READ_ONLY_TYPES.has(type)) return 'a read-only Zensu agent never holds a shell';
  if (PERSONA_RE.test(type)) return 'a zensu-review-* persona is a read-only reviewer';
  if (!strictFlagEnabled(CONFIG_KEY, environment, options)) {
    return `hooks.${CONFIG_KEY} withdraws the subagent shell (false in a config layer, a config layer that could not be read or resolved, or no config layer to consult)`;
  }
  return null;
}

function foldCase(value, platform) {
  return platform === 'darwin' || platform === 'win32' ? value.toLowerCase() : value;
}

function collapse(value) {
  const drive = /^[A-Za-z]:/.exec(value);
  const prefix = drive ? drive[0] : '';
  const parts = [];
  for (const part of value.slice(prefix.length).split('/')) {
    if (part === '' || part === '.') continue;
    if (part === '..') {
      parts.pop();
      continue;
    }
    parts.push(part);
  }
  return `${prefix}/${parts.join('/')}`;
}

function isAbsoluteSpelling(value) {
  return value.startsWith('/') || /^[A-Za-z]:\//.test(value);
}

function resolveSpelling(base, value) {
  return collapse(isAbsoluteSpelling(value) ? value : `${base}/${value}`);
}

function isAncestorOrSelf(ancestor, candidate) {
  if (candidate === ancestor) return true;
  return candidate.startsWith(ancestor.endsWith('/') ? ancestor : `${ancestor}/`);
}

function depthOf(value) {
  return value.replace(/^[A-Za-z]:/, '').split('/').filter(Boolean).length;
}

function slashSpelling(value, platform) {
  const slashed = String(value).replace(/\\/g, '/');
  return platform === 'win32' ? hostPaths.msysDrivePrefix(slashed, platform) : slashed;
}

function spellPath(value, platform) {
  return foldCase(collapse(slashSpelling(value, platform)), platform);
}

function realSpelling(value, platform, fsModule) {
  try {
    return spellPath(fsModule.realpathSync.native(value), platform);
  } catch {
    return null;
  }
}

function canonicalSpelling(value, platform, fsModule) {
  let current = collapse(slashSpelling(value, platform));
  const suffix = [];
  for (let step = 0; step < 64; step += 1) {
    const real = realSpelling(current, platform, fsModule);
    if (real) return collapse([real, ...suffix].join('/'));
    if (depthOf(current) === 0) return null;
    const cut = current.lastIndexOf('/');
    suffix.unshift(current.slice(cut + 1));
    current = cut <= 0 ? '/' : current.slice(0, cut);
    if (/^[A-Za-z]:$/.test(current)) current = `${current}/`;
  }
  return null;
}

function pathForms(value, platform, fsModule) {
  if (typeof value !== 'string' || value === '') return [];
  const forms = new Set([spellPath(value, platform)]);
  const real = canonicalSpelling(value, platform, fsModule);
  if (real) forms.add(foldCase(real, platform));
  return [...forms];
}

function shellText(text, home, platform, root = '') {
  let value = text.replace(/\\\r?\n/g, ' ').replace(/\\/g, '/').replace(/['"]/g, '');
  value = value.replace(/\$\(\s*git\s+rev-parse\s+--show-toplevel\s*\)|`\s*git\s+rev-parse\s+--show-toplevel\s*`/g, () => root || '.');
  value = value.replace(/\$\{PWD\}|\$PWD(?![A-Za-z0-9_])|\$\(\s*pwd(?:\s+-[LP])?\s*\)|`\s*pwd(?:\s+-[LP])?\s*`/g, '.');
  if (home) {
    value = value.replace(/\$\{HOME\}|\$HOME(?![A-Za-z0-9_])/g, () => home);
    value = value.replace(/(^|[\s=:;|&(){}<>`,])~(?=$|[/\s;|&(){}<>`,])/g, (match, lead) => `${lead}${home}`);
  }
  if (platform === 'win32') {
    value = value.replace(/(^|[\s=;|&(){}<>`,])\/([A-Za-z])(?=$|[/\s;|&(){}<>`,])/g, (match, lead, drive) => `${lead}${drive}:`);
  }
  return value;
}

function mentionsPath(text, root) {
  let index = text.indexOf(root);
  while (index !== -1) {
    const next = text.charAt(index + root.length);
    if (next === '' || !/[A-Za-z0-9._-]/.test(next)) return true;
    index = text.indexOf(root, index + 1);
  }
  return false;
}

function globRegExp(pattern) {
  let source = '';
  for (let index = 0; index < pattern.length; index += 1) {
    const char = pattern[index];
    if (char === '*') source += '[^/]*';
    else if (char === '?') source += '[^/]';
    else if (char === '[') {
      const close = pattern.indexOf(']', index + 2);
      if (close === -1) {
        source += '\\[';
      } else {
        const body = pattern.slice(index + 1, close).replace(/^!/, '^').replace(/\\/g, '\\\\');
        source += `[${body}]`;
        index = close;
      }
    } else {
      source += char.replace(/[.+^${}()|\\/]/g, '\\$&');
    }
  }
  try {
    return new RegExp(`^${source}$`);
  } catch {
    return /^$/;
  }
}

function segmentMatches(pattern, name) {
  if (!/[*?[]/.test(pattern)) return pattern === name;
  if (name.startsWith('.') && !pattern.startsWith('.')) return false;
  return globRegExp(pattern).test(name);
}

const OPERATOR_CHARS = new Set([';', '&', '|', '(', ')', '\n']);
const WORD_END_CHARS = new Set([' ', '\t', ';', '&', '|', '(', ')', '<', '>', '\n']);

function matchingParen(text, start) {
  let depth = 1;
  let index = start;
  while (index < text.length) {
    const char = text[index];
    if (char === '\\') {
      index += 2;
      continue;
    }
    if (char === "'") {
      const close = text.indexOf("'", index + 1);
      index = close === -1 ? text.length : close + 1;
      continue;
    }
    if (char === '"') {
      index += 1;
      while (index < text.length && text[index] !== '"') index += text[index] === '\\' ? 2 : 1;
      index += 1;
      continue;
    }
    if (char === '`') {
      index += 1;
      while (index < text.length && text[index] !== '`') index += text[index] === '\\' ? 2 : 1;
      index += 1;
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

function matchingBrace(text, start) {
  let depth = 1;
  for (let index = start; index < text.length; index += 1) {
    if (text[index] === '\\') {
      index += 1;
      continue;
    }
    if (text[index] === '{') depth += 1;
    if (text[index] === '}') {
      depth -= 1;
      if (depth === 0) return index;
    }
  }
  return -1;
}

function closingBacktick(text, start) {
  let index = start;
  while (index < text.length && text[index] !== '`') index += text[index] === '\\' ? 2 : 1;
  return index < text.length ? index : -1;
}

function ansiCString(text, start) {
  let value = '';
  let index = start;
  const escapes = { n: '\n', t: '\t', r: '\r', a: '\x07', b: '\b', e: '\x1b', f: '\f', v: '\v' };
  while (index < text.length && text[index] !== "'") {
    if (text[index] === '\\' && index + 1 < text.length) {
      const next = text[index + 1];
      value += Object.prototype.hasOwnProperty.call(escapes, next) ? escapes[next] : next;
      index += 2;
      continue;
    }
    value += text[index];
    index += 1;
  }
  return { value, end: index };
}

function substitutionSpelling(inner, root) {
  if (/^\s*pwd(?:\s+-[LP])?\s*$/.test(inner)) return PWD_MARK;
  if (/^\s*git\s+rev-parse\s+--show-toplevel\s*$/.test(inner)) return root || PWD_MARK;
  return null;
}

function substitutionsIn(body, skipSingle) {
  const found = [];
  let index = 0;
  let double = false;
  while (index < body.length) {
    const char = body[index];
    if (char === '\\') {
      index += 2;
      continue;
    }
    if (char === '"') {
      double = !double;
      index += 1;
      continue;
    }
    if (skipSingle && !double && char === '$' && body[index + 1] === "'") {
      index = ansiCString(body, index + 2).end + 1;
      continue;
    }
    if (skipSingle && !double && char === "'") {
      const close = body.indexOf("'", index + 1);
      index = close === -1 ? body.length : close + 1;
      continue;
    }
    if (char === '$' && body[index + 1] === '(' && body[index + 2] !== '(') {
      const close = matchingParen(body, index + 2);
      found.push(body.slice(index + 2, close === -1 ? body.length : close));
      index = close === -1 ? body.length : close + 1;
      continue;
    }
    if (char === '`') {
      const close = closingBacktick(body, index + 1);
      found.push(body.slice(index + 1, close === -1 ? body.length : close).replace(/\\`/g, '`'));
      index = close === -1 ? body.length : close + 1;
      continue;
    }
    index += 1;
  }
  return found;
}

function materialized(word, cwd) {
  if (!word.value.includes(PWD_MARK)) return word;
  let value = '';
  let mask = '';
  for (let index = 0; index < word.value.length; index += 1) {
    if (word.value[index] === PWD_MARK) {
      value += cwd;
      mask += '.'.repeat(cwd.length);
    } else {
      value += word.value[index];
      mask += word.mask[index];
    }
  }
  return { ...word, value, mask };
}

function withoutMarkers(text) {
  return text.replace(MARKER_CHARS, NEUTRAL_CHAR);
}

function braceSpan(value, mask) {
  const groups = [];
  let best = null;
  for (let index = 0; index < value.length; index += 1) {
    if (mask[index] !== 'x') continue;
    const char = value[index];
    if (char === '{') {
      groups.push({ open: index, commas: [] });
    } else if (char === ',') {
      if (groups.length > 0) groups[groups.length - 1].commas.push(index);
    } else if (char === '}' && groups.length > 0) {
      const group = groups.pop();
      if (group.commas.length > 0 && (best === null || group.open < best.open)) best = { ...group, close: index };
      if (best !== null && groups.length === 0) break;
    }
  }
  if (best === null) return null;
  const bounds = [best.open, ...best.commas, best.close];
  const parts = [];
  for (let part = 0; part + 1 < bounds.length; part += 1) {
    parts.push({
      value: value.slice(bounds[part] + 1, bounds[part + 1]),
      mask: mask.slice(bounds[part] + 1, bounds[part + 1]),
    });
  }
  return { open: best.open, close: best.close, parts };
}

function expandBraces(word, home) {
  const done = [];
  const pending = [{ value: word.value, mask: word.mask }];
  while (pending.length > 0 && done.length + pending.length <= MAX_BRACE_WORDS) {
    const current = pending.shift();
    const span = braceSpan(current.value, current.mask);
    if (!span) {
      done.push(current);
      continue;
    }
    for (const part of span.parts) {
      pending.push({
        value: current.value.slice(0, span.open) + part.value + current.value.slice(span.close + 1),
        mask: current.mask.slice(0, span.open) + part.mask + current.mask.slice(span.close + 1),
      });
    }
  }
  done.push(...pending);
  return done.map((variant) => {
    if (home && variant.mask[0] === 'x' && variant.value[0] === '~' && (variant.value.length === 1 || variant.value[1] === '/')) {
      return { ...word, value: home + variant.value.slice(1), mask: '.'.repeat(home.length) + variant.mask.slice(1) };
    }
    return { ...word, value: variant.value, mask: variant.mask };
  });
}

function parseScript(text, options = {}) {
  const platform = options.platform || process.platform;
  const home = options.home || '';
  const root = options.root || '';
  const nestedOptions = { platform, home, root };
  const items = [];
  const expansions = [];
  const comments = [];
  let command = null;
  let word = null;
  let pendingRedirect = null;
  let pendingHeredocs = [];
  let index = 0;
  let leadingAssignments = true;

  const ensureCommand = () => {
    if (!command) {
      command = { kind: 'command', words: [], redirects: [], heredocs: [], nested: [], sep: null };
      leadingAssignments = true;
    }
    return command;
  };
  const startWord = () => {
    if (!word) word = { value: '', mask: '', raw: '', quoted: false, dynamic: false, start: index };
    return word;
  };
  const append = (chars, quoted, mark = '.') => {
    const current = startWord();
    current.value += chars;
    current.mask += (quoted ? '.' : mark).repeat(chars.length);
    if (quoted) current.quoted = true;
  };
  const appendDynamic = () => {
    const current = startWord();
    current.value += DYNAMIC;
    current.mask += '.';
    current.dynamic = true;
  };
  const addNested = (script) => {
    ensureCommand().nested.push(script);
  };
  const endWord = () => {
    if (!word) return;
    word.raw = text.slice(word.start, index);
    const finished = word;
    word = null;
    if (pendingRedirect) {
      const redirect = pendingRedirect;
      pendingRedirect = null;
      if (redirect.heredoc) {
        const delimiter = finished.value;
        const heredoc = { delimiter, strip: redirect.strip, quoted: finished.quoted, body: null };
        ensureCommand().heredocs.push(heredoc);
        pendingHeredocs.push(heredoc);
        return;
      }
      ensureCommand().redirects.push({ op: redirect.op, word: finished });
      return;
    }
    const current = ensureCommand();
    const assignmentWord = ASSIGNMENT_RE.test(finished.raw);
    const assignment = assignmentWord && leadingAssignments;
    if (!assignmentWord) leadingAssignments = false;
    current.words.push(...(finished.mask.includes('x') && !assignment ? expandBraces(finished, home) : [finished]));
  };
  const endCommand = (sep) => {
    endWord();
    pendingRedirect = null;
    if (command) {
      command.sep = sep;
      items.push(command);
      command = null;
    } else if (sep !== null && items.length > 0 && items[items.length - 1].kind === 'close') {
      items[items.length - 1].sep = sep;
    }
  };
  const recordExpansion = (body) => {
    expansions.push(body);
  };
  const expandName = (name, body, quoted) => {
    recordExpansion(body);
    const unchanged = body === name || VALUE_KEEPING_RE.test(body);
    if (unchanged && name === 'HOME' && home) {
      append(home, true);
      return;
    }
    if (unchanged && name === 'PWD') {
      append(PWD_MARK, true);
      return;
    }
    appendDynamic();
    if (quoted) startWord().quoted = true;
  };
  const substitute = (inner, quoted) => {
    const spelling = substitutionSpelling(inner, root);
    if (spelling !== null) {
      append(spelling, true);
    } else {
      addNested(inner);
      appendDynamic();
    }
    if (quoted) startWord().quoted = true;
  };
  const parseDollar = (quoted) => {
    const next = text[index + 1];
    if (next === '(') {
      if (text[index + 2] === '(') {
        const close = matchingParen(text, index + 3);
        const end = close === -1 ? text.length : close + 1;
        const arithmetic = text.slice(index + 3, close === -1 ? text.length : close);
        recordExpansion(arithmetic);
        for (const inner of substitutionsIn(arithmetic, false)) addNested(inner);
        appendDynamic();
        index = end + (text[end] === ')' ? 1 : 0);
        return;
      }
      const close = matchingParen(text, index + 2);
      substitute(text.slice(index + 2, close === -1 ? text.length : close), quoted);
      index = close === -1 ? text.length : close + 1;
      return;
    }
    if (next === '{') {
      const close = matchingBrace(text, index + 2);
      const body = text.slice(index + 2, close === -1 ? text.length : close);
      index = close === -1 ? text.length : close + 1;
      for (const inner of substitutionsIn(body, !quoted)) addNested(inner);
      expandName(body.replace(/^[!#]/, '').match(/^[A-Za-z_][A-Za-z0-9_]*/)?.[0] || body, body, quoted);
      return;
    }
    if (next !== undefined && /[A-Za-z_]/.test(next)) {
      const match = /^[A-Za-z_][A-Za-z0-9_]*/.exec(text.slice(index + 1));
      index += 1 + match[0].length;
      expandName(match[0], match[0], quoted);
      return;
    }
    if (next !== undefined && /[0-9@*#?$!-]/.test(next)) {
      appendDynamic();
      index += 2;
      return;
    }
    if (!quoted && next === "'") {
      const parsed = ansiCString(text, index + 2);
      append(parsed.value, true);
      index = parsed.end + 1;
      return;
    }
    if (!quoted && next === '"') {
      index += 1;
      return;
    }
    append('$', quoted);
    index += 1;
  };
  const parseBacktick = (quoted) => {
    const close = closingBacktick(text, index + 1);
    substitute(text.slice(index + 1, close === -1 ? text.length : close).replace(/\\`/g, '`'), quoted);
    index = close === -1 ? text.length : close + 1;
  };
  const parseQuoted = (heredoc) => {
    startWord().quoted = true;
    while (index < text.length && (heredoc || text[index] !== '"')) {
      const char = text[index];
      if (char === '\\' && index + 1 < text.length) {
        const next = text[index + 1];
        if (next === '\n') {
          index += 2;
          continue;
        }
        if ((heredoc ? '$`\\' : '$`"\\').includes(next)) {
          append(next, true);
          index += 2;
          continue;
        }
        append(platform === 'win32' ? '/' : '\\', true);
        index += 1;
        continue;
      }
      if (char === '$') {
        parseDollar(true);
        continue;
      }
      if (char === '`') {
        parseBacktick(true);
        continue;
      }
      if (char === DYNAMIC) {
        appendDynamic();
        index += 1;
        continue;
      }
      append(char, true);
      index += 1;
    }
  };
  const parseDouble = () => {
    index += 1;
    parseQuoted(false);
    index += 1;
  };
  const consumeHeredocs = () => {
    for (const heredoc of pendingHeredocs) {
      const lines = [];
      while (index < text.length) {
        const newline = text.indexOf('\n', index);
        const line = text.slice(index, newline === -1 ? text.length : newline).replace(/\r$/, '');
        index = newline === -1 ? text.length : newline + 1;
        const compared = heredoc.strip ? line.replace(/^\t+/, '') : line;
        if (compared === heredoc.delimiter) break;
        lines.push(line);
      }
      heredoc.body = lines.join('\n');
      if (!heredoc.quoted) {
        const inner = parseScript(heredoc.body, { ...nestedOptions, heredoc: true });
        expansions.push(...inner.expansions);
        heredoc.expanded = inner.items.find((item) => item.kind === 'command')?.words[0] || null;
        heredoc.nestedScripts = inner.items
          .filter((item) => item.kind === 'command')
          .flatMap((item) => item.nested);
      }
    }
    pendingHeredocs = [];
  };

  if (options.heredoc) {
    parseQuoted(true);
    endCommand(null);
    return { items, expansions, comments };
  }

  while (index < text.length) {
    const char = text[index];
    if (char === '\\') {
      const next = text[index + 1];
      if (next === '\n') {
        index += 2;
        continue;
      }
      if (next === '\r' && text[index + 2] === '\n') {
        index += 3;
        continue;
      }
      if (next === undefined) {
        append('\\', false);
        index += 1;
        continue;
      }
      if (platform === 'win32' && /[A-Za-z0-9._~-]/.test(next)) {
        append('/', false);
        index += 1;
        continue;
      }
      append(next, true);
      index += 2;
      continue;
    }
    if (char === "'") {
      const close = text.indexOf("'", index + 1);
      append(text.slice(index + 1, close === -1 ? text.length : close), true);
      startWord().quoted = true;
      index = close === -1 ? text.length : close + 1;
      continue;
    }
    if (char === '"') {
      parseDouble();
      continue;
    }
    if (char === '$') {
      parseDollar(false);
      continue;
    }
    if (char === '`') {
      parseBacktick(false);
      continue;
    }
    if (char === ' ' || char === '\t' || char === '\r') {
      endWord();
      index += 1;
      continue;
    }
    if (char === '#' && !word) {
      const newline = text.indexOf('\n', index);
      const end = newline === -1 ? text.length : newline;
      comments.push([index, end]);
      index = end;
      continue;
    }
    if (char === '\n') {
      endCommand(';');
      index += 1;
      if (pendingHeredocs.length > 0) consumeHeredocs();
      continue;
    }
    if (char === '<' || char === '>') {
      if (word && /^[0-9]+$/.test(word.value) && !word.quoted) word = null;
      else endWord();
      if (text[index + 1] === '(') {
        const close = matchingParen(text, index + 2);
        addNested(text.slice(index + 2, close === -1 ? text.length : close));
        appendDynamic();
        index = close === -1 ? text.length : close + 1;
        continue;
      }
      let op = char;
      let length = 1;
      const rest = text.slice(index, index + 3);
      if (rest.startsWith('<<<')) [op, length] = ['<<<', 3];
      else if (rest.startsWith('<<-')) [op, length] = ['<<-', 3];
      else if (rest.startsWith('<<')) [op, length] = ['<<', 2];
      else if (rest.startsWith('>>')) [op, length] = ['>>', 2];
      else if (rest.startsWith('>|') || rest.startsWith('<>')) [op, length] = [rest.slice(0, 2), 2];
      else if (rest.startsWith('>&') || rest.startsWith('<&')) [op, length] = [rest.slice(0, 2), 2];
      index += length;
      if (op === '>&' || op === '<&') {
        const target = /^(?:[0-9]+-?|-)/.exec(text.slice(index));
        if (target) {
          index += target[0].length;
          continue;
        }
      }
      while (text[index] === ' ' || text[index] === '\t') index += 1;
      pendingRedirect = op === '<<' || op === '<<-' ? { heredoc: true, strip: op === '<<-' } : { op };
      continue;
    }
    if (char === '&' && text[index + 1] === '>') {
      endWord();
      index += text[index + 2] === '>' ? 3 : 2;
      while (text[index] === ' ' || text[index] === '\t') index += 1;
      pendingRedirect = { op: '&>' };
      continue;
    }
    if (OPERATOR_CHARS.has(char)) {
      if (char === ';') {
        endCommand(';');
        index += text[index + 1] === ';' || text[index + 1] === '&' ? 2 : 1;
        continue;
      }
      if (char === '&') {
        if (text[index + 1] === '&') {
          endCommand('&&');
          index += 2;
        } else {
          endCommand('&');
          index += 1;
        }
        continue;
      }
      if (char === '|') {
        if (text[index + 1] === '|') {
          endCommand('||');
          index += 2;
        } else {
          endCommand(text[index + 1] === '&' ? '|&' : '|');
          index += text[index + 1] === '&' ? 2 : 1;
        }
        continue;
      }
      if (char === '(') {
        endCommand(null);
        items.push({ kind: 'open', sep: null });
        index += 1;
        continue;
      }
      if (char === ')') {
        endCommand(null);
        items.push({ kind: 'close', sep: null });
        index += 1;
        continue;
      }
    }
    if (char === '~' && !word) {
      const next = text[index + 1];
      if (home && (next === undefined || next === '/' || WORD_END_CHARS.has(next))) {
        append(home, true);
        index += 1;
        continue;
      }
    }
    if (char === DYNAMIC) {
      appendDynamic();
      index += 1;
      continue;
    }
    let mark = '.';
    if (char === '*' || char === '?' || char === '[') mark = 'g';
    else if (char === '{' || char === ',' || char === '}' || char === '~') mark = 'x';
    append(char, false, mark);
    index += 1;
  }
  endCommand(null);
  return { items, expansions, comments };
}

function commandStart(words) {
  let index = 0;
  while (index < words.length) {
    const current = words[index];
    if (current.raw === current.value && RESERVED_WORDS.has(current.value)) {
      index += 1;
      continue;
    }
    if (ASSIGNMENT_RE.test(current.raw)) {
      index += 1;
      continue;
    }
    break;
  }
  return index;
}

function commandName(value, platform, fold = false) {
  const cut = platform === 'win32' ? Math.max(value.lastIndexOf('/'), value.lastIndexOf('\\')) : value.lastIndexOf('/');
  const name = value.slice(cut + 1).replace(/\.exe$/i, '');
  return fold ? name.toUpperCase().toLowerCase() : foldCase(name, platform);
}

function commandWord(item, platform) {
  if (!item || item.kind !== 'command') return null;
  const start = commandStart(item.words);
  return start < item.words.length ? commandName(item.words[start].value, platform) : null;
}

function unwrap(spec, rest) {
  let index = 0;
  let positional = spec.positional;
  while (index < rest.length) {
    const value = rest[index].value;
    if (value === '--') {
      index += 1;
      break;
    }
    if (value.startsWith('-') && value.length > 1) {
      const combined = /^-[A-Za-z]{2,}$/.test(value) && spec.args.includes(`-${value.slice(-1)}`);
      index += spec.args.includes(value) || combined ? 2 : 1;
      continue;
    }
    if (spec.assignments && ASSIGNMENT_RE.test(value)) {
      index += 1;
      continue;
    }
    if (positional > 0) {
      positional -= 1;
      index += 1;
      continue;
    }
    break;
  }
  return rest.slice(index);
}

function optionValue(value) {
  return value.replace(/^--[A-Za-z][A-Za-z0-9-]*=/, '').replace(/^-[A-Za-z]/, '');
}

function optionOperand(own, option) {
  for (let index = 0; index < own.length; index += 1) {
    const value = own[index].value;
    const letter = option.short.slice(1);
    if (value === option.short || value === option.long || (/^-[A-Za-z]{2,}$/.test(value) && value.endsWith(letter))) {
      return own[index + 1] || null;
    }
    if (value.startsWith(`${option.long}=`)) return { ...own[index], value: value.slice(option.long.length + 1) };
    if (value.startsWith(option.short) && value.length > option.short.length && !value.startsWith('--')) {
      return { ...own[index], value: value.slice(option.short.length) };
    }
  }
  return null;
}

function operands(rest) {
  const result = [];
  let options = true;
  for (const word of rest) {
    if (options && word.value === '--') {
      options = false;
      continue;
    }
    if (options && word.value.startsWith('-') && word.value.length > 1) continue;
    result.push(word);
  }
  return result;
}

function shortFlagsInclude(value, flag) {
  return /^-[A-Za-z]+$/.test(value) && value.includes(flag);
}

function gitViolation(rest, context) {
  let index = 0;
  let cwd = context.cwd;
  while (index < rest.length) {
    const value = rest[index].value;
    if (GIT_GLOBAL_ARGS.has(value)) {
      const operand = rest[index + 1];
      if (value === '-C' && operand && !operand.dynamic && operand.value !== '') {
        cwd = resolveSpelling(cwd, wordPath(operand, context));
      }
      index += 2;
      continue;
    }
    if (value.startsWith('-')) {
      index += 1;
      continue;
    }
    break;
  }
  const sub = rest[index] ? rest[index].value : undefined;
  const words = rest.slice(index + 1);
  const args = words.map((word) => word.value);
  const scoped = { ...context, cwd };
  const wholeTree = () => args.some((value) => WHOLE_TREE_PATHSPECS.has(value))
    || operands(words).some((word) => removesProjectRoot(word, scoped));
  const has = (long, short) => args.some((value) => value === long || shortFlagsInclude(value, short));
  if (sub === 'clean') return 'git clean';
  if (sub === 'stash' && !['list', 'show'].includes(args[0])) return 'git stash';
  if (sub === 'reset' && args.includes('--hard')) return 'git reset --hard';
  if (sub === 'checkout' && (wholeTree() || has('--force', 'f'))) {
    return 'git checkout over the whole tree or with --force';
  }
  if (sub === 'switch' && (args.includes('--discard-changes') || has('--force', 'f'))) {
    return 'git switch --force or --discard-changes';
  }
  if (sub === 'restore' && wholeTree() && (!has('--staged', 'S') || has('--worktree', 'W'))) {
    return 'git restore over the whole tree';
  }
  if (sub === 'rm' && wholeTree() && !args.includes('--cached')) return 'git rm over the whole tree';
  if (sub === 'worktree' && ['remove', 'prune', 'move'].includes(args[0])) return `git worktree ${args[0]}`;
  return null;
}

function removalTargets(name, rest) {
  const targets = operands(rest);
  if (name !== 'mv') return targets;
  const targetFlag = rest.findIndex((word) => word.value === '-t' || word.value === '--target-directory');
  if (targetFlag !== -1) return targets.filter((word) => word !== rest[targetFlag + 1]);
  if (rest.some((word) => word.value.startsWith('--target-directory='))) return targets;
  return targets.slice(0, -1);
}

function spellingForms(resolved, context) {
  const forms = new Set([resolved]);
  const real = canonicalSpelling(resolved, context.platform, context.fs);
  if (real) forms.add(foldCase(real, context.platform));
  return [...forms];
}

function firstGlob(word) {
  return word.mask.indexOf('g');
}

function wordPath(word, context) {
  return foldCase(slashSpelling(word.value, context.platform), context.platform);
}

function removesProjectRoot(word, context) {
  if (word.dynamic || word.value === '') return false;
  const value = wordPath(word, context);
  const glob = firstGlob(word);
  if (glob === -1) {
    return spellingForms(resolveSpelling(context.cwd, value), context)
      .some((candidate) => context.projectForms.some((root) => isAncestorOrSelf(candidate, root)));
  }
  const slash = value.lastIndexOf('/', glob);
  const prefix = slash === -1 ? '' : value.slice(0, slash);
  const base = slash === -1 ? context.cwd : resolveSpelling(context.cwd, prefix || '/');
  const pattern = value.slice(slash + 1).split('/').filter((segment) => segment !== '' && segment !== '.');
  if (pattern.includes('..')) return true;
  return spellingForms(base, context).some((directory) => context.projectForms.some((root) => {
    if (!isAncestorOrSelf(directory, root)) return false;
    const remaining = root === directory ? [] : root.slice(directory.length).replace(/^\//, '').split('/');
    if (remaining.length === 0) return pattern.length === 1 && MATCH_ALL_SEGMENTS.has(pattern[0]);
    if (pattern.length > remaining.length) return false;
    return pattern.every((segment, position) => segmentMatches(segment, remaining[position]));
  }));
}

function globReach(value, glob, context) {
  const cut = value.lastIndexOf('/', glob);
  let directory = cut === -1 ? context.cwd : resolveSpelling(context.cwd, value.slice(0, cut) || '/');
  const pattern = [];
  for (const segment of value.slice(cut + 1).split('/')) {
    if (segment === '' || segment === '.') continue;
    if (segment !== '..') pattern.push(segment);
    else if (pattern.length > 0) pattern.pop();
    else directory = collapse(`${directory}/..`);
  }
  for (const form of spellingForms(directory, context)) {
    for (const target of context.protectedTargets) {
      if (target === form || !isAncestorOrSelf(form, target)) continue;
      const remaining = target.slice(form.length).replace(/^\//, '').split('/');
      if (pattern.length < remaining.length) continue;
      if (remaining.every((name, position) => segmentMatches(pattern[position], name))) {
        return context.protectedForms.includes(target) ? REASONS.protectedPath : REASONS.protectedParent;
      }
    }
  }
  return null;
}

function pathWordViolation(word, context) {
  if (word.dynamic || word.value === '') return null;
  const values = [word.value];
  const equals = word.value.indexOf('=');
  if (equals > 0) values.push(word.value.slice(equals + 1));
  for (const raw of values) {
    if (raw === '' || raw.startsWith('-')) continue;
    const resolved = resolveSpelling(context.cwd, foldCase(slashSpelling(raw, context.platform), context.platform));
    const forms = spellingForms(resolved, context);
    if (forms.some((form) => context.protectedForms.some((root) => isAncestorOrSelf(root, form)))) {
      return REASONS.protectedPath;
    }
    if (forms.some((form) => context.protectedParents.has(form))) return REASONS.protectedParent;
  }
  const glob = firstGlob(word);
  if (glob === -1) return null;
  const value = wordPath(word, context);
  const reached = globReach(value, glob, context);
  if (reached) return reached;
  const segments = value.split('/');
  let offset = 0;
  for (const segment of segments) {
    const segmentMask = word.mask.slice(offset, offset + segment.length);
    offset += segment.length + 1;
    if (segment.startsWith('.') && segmentMask.includes('g') && globRegExp(segment).test('.zensu')) {
      return REASONS.workflowDirectory;
    }
  }
  return null;
}

function psShowsEnvironment(rest) {
  for (let index = 0; index < rest.length; index += 1) {
    const value = rest[index];
    if (PS_ARGUMENT_OPTIONS.has(value)) {
      index += 1;
      continue;
    }
    if (/^[A-Za-z]+$/.test(value) && value.includes('e')) return true;
    if (/^-[A-Za-z]*E/.test(value)) return true;
  }
  return false;
}

function tmuxCommandStart(rest) {
  let index = 0;
  while (index < rest.length) {
    const value = rest[index].value;
    if (value === '--') return index + 1;
    if (!/^-[A-Za-z0-9]/.test(value)) break;
    index += 1;
    for (let position = 1; position < value.length; position += 1) {
      if (!TMUX_VALUE_OPTIONS.has(value[position])) continue;
      if (position === value.length - 1) index += 1;
      break;
    }
  }
  return index;
}

function endsTmuxCommand(value) {
  return value.endsWith(';') && !value.endsWith('\\;');
}

function startsTmuxProcess(value) {
  const name = endsTmuxCommand(value) ? value.slice(0, -1) : value;
  if (name === '' || name.startsWith('-') || TMUX_INERT_ALIASES.has(name)) return false;
  return TMUX_PROCESS_ALIASES.has(name) || TMUX_PROCESS_COMMANDS.some((command) => command.startsWith(name));
}

function screenOptions(rest) {
  const flags = new Set();
  let index = 0;
  while (index < rest.length) {
    const value = rest[index].value;
    if (value === '--') return { flags, end: index + 1 };
    if (!/^-[A-Za-z]/.test(value)) break;
    index += 1;
    for (let position = 1; position < value.length; position += 1) {
      const letter = value[position];
      flags.add(letter);
      if (SCREEN_ATTACHED_OPTIONS.has(letter)) {
        if (position === value.length - 1) index += 1;
        break;
      }
      if (SCREEN_NEXT_WORD_OPTIONS.has(letter)) index += 1;
      else if (SCREEN_SESSION_OPTIONS.has(letter) && index < rest.length && !rest[index].value.startsWith('-')) index += 1;
    }
  }
  return { flags, end: index };
}

function startsDetachedSession(name, rest) {
  if (name === 'tmux') {
    let commandPosition = true;
    for (const word of rest.slice(tmuxCommandStart(rest))) {
      if (commandPosition && startsTmuxProcess(word.value)) return true;
      commandPosition = endsTmuxCommand(word.value);
    }
    return false;
  }
  if (name !== 'screen') return false;
  const { flags, end } = screenOptions(rest);
  if (flags.has('d') && flags.has('m')) return true;
  return SCREEN_COMMAND_OPTIONS.some((option) => flags.has(option))
    && end < rest.length && SCREEN_PROCESS_COMMANDS.has(rest[end].value);
}

function matchesEverything(test, pattern) {
  if (typeof pattern !== 'string') return true;
  if (/regex$/.test(test)) return /^(?:\.\*)+$/.test(pattern);
  return /^\*+$/.test(pattern);
}

function findFilters(values) {
  for (let index = 0; index < values.length; index += 1) {
    if (!FIND_NAME_TESTS.has(values[index])) continue;
    const negated = index > 0 && (values[index - 1] === '!' || values[index - 1] === '-not');
    if (negated || matchesEverything(values[index], values[index + 1])) continue;
    return true;
  }
  return false;
}

function findDeletesProjectTree(rest, context) {
  const values = rest.map((word) => word.value);
  const exec = values.findIndex((value) => FIND_EXEC_WORDS.has(value));
  const removes = values.includes('-delete')
    || (exec !== -1 && values[exec + 1] !== undefined && REMOVING_COMMANDS.has(commandName(values[exec + 1], context.platform)));
  if (!removes) return false;
  if (findFilters(values)) return false;
  const starts = [];
  for (const word of rest) {
    if (/^[-(!)]/.test(word.value)) break;
    starts.push(word);
  }
  const roots = starts.length > 0 ? starts : [{ value: '.', mask: '.', dynamic: false }];
  return roots.some((word) => !word.dynamic && spellingForms(resolveSpelling(context.cwd, wordPath(word, context)), context)
    .some((candidate) => context.projectForms.some((root) => isAncestorOrSelf(candidate, root))));
}

function heredocText(body) {
  return body.replace(/\\(?:([$`\\])|\n)/g, (match, char) => char || '');
}

function stdinCode(item, cwd = null) {
  const unquoted = (heredoc) => (cwd !== null && heredoc.expanded
    ? materialized(heredoc.expanded, cwd).value
    : heredocText(heredoc.body || ''));
  return [
    ...item.heredocs.map((heredoc) => (heredoc.quoted ? heredoc.body || '' : unquoted(heredoc))),
    ...item.redirects.filter((redirect) => redirect.op === '<<<')
      .map((redirect) => (cwd === null ? redirect.word.value : materialized(redirect.word, cwd).value)),
  ];
}

function inlineCode(rest, flags) {
  const code = [];
  for (let index = 0; index < rest.length; index += 1) {
    const value = rest[index].value;
    if (value === '--') break;
    const long = flags.find((flag) => flag.startsWith('--') && value.startsWith(`${flag}=`));
    if (long) {
      code.push(value.slice(long.length + 1));
      continue;
    }
    const combined = /^-[A-Za-z]{2,}$/.test(value) && flags.includes(`-${value.slice(-1)}`);
    if (flags.includes(value) || combined) {
      if (index + 1 < rest.length) code.push(rest[index + 1].value);
      index += 1;
    }
  }
  return code;
}

function readsScriptFromStdin(rest) {
  const names = operands(rest);
  return names.length === 0 || names[0].value === '-';
}

function awkProgram(rest) {
  const code = [];
  let file = false;
  let index = 0;
  for (; index < rest.length; index += 1) {
    const value = rest[index].value;
    if (value === '--') {
      index += 1;
      break;
    }
    if (AWK_VALUE_OPTIONS.has(value)) {
      index += 1;
      continue;
    }
    if (value === '-f' || value === '--file') {
      file = true;
      index += 1;
      continue;
    }
    if (value.startsWith('--file=')) {
      file = true;
      continue;
    }
    if (value === '-e' || value === '--source') {
      if (index + 1 < rest.length) code.push(rest[index + 1].value);
      index += 1;
      continue;
    }
    if (value.startsWith('--source=')) {
      code.push(value.slice('--source='.length));
      continue;
    }
    if (value.startsWith('-') && value.length > 1) continue;
    break;
  }
  if (!file && code.length === 0 && index < rest.length) code.push(rest[index].value);
  return code;
}

function jqProgram(rest, yq) {
  let skippedSubcommand = !yq;
  for (let index = 0; index < rest.length; index += 1) {
    const value = rest[index].value;
    if (value === '--') return rest[index + 1] ? [rest[index + 1].value] : [];
    if (value === '-f' || value === '--from-file') return [];
    if (JQ_VALUE_OPTIONS.has(value)) {
      index += JQ_VALUE_OPTIONS.get(value);
      continue;
    }
    if (value.startsWith('-') && value.length > 1) continue;
    if (!skippedSubcommand) {
      skippedSubcommand = true;
      if (YQ_SUBCOMMANDS.has(value)) continue;
    }
    return [value];
  }
  return [];
}

function interpreterCode(name, rest, item) {
  const lower = name.toLowerCase();
  if (JQ_COMMANDS.has(lower)) return { jq: true, code: jqProgram(rest, lower === 'yq') };
  if (AWK_COMMANDS.has(lower)) return { jq: false, code: awkProgram(rest) };
  if (POWERSHELL.has(lower)) {
    const flag = rest.findIndex((word) => /^-(?:c|command)$/i.test(word.value));
    return { jq: false, code: flag === -1 ? [] : [rest.slice(flag + 1).map((word) => word.value).join(' ')] };
  }
  if (lower === 'deno') {
    const names = operands(rest);
    return { jq: false, code: names.length > 1 && names[0].value === 'eval' ? [names[1].value] : [] };
  }
  const python = PYTHON_RE.test(lower);
  const flags = python ? PYTHON_CODE_FLAGS : INLINE_CODE_FLAGS.get(lower);
  if (!flags) return null;
  const inline = inlineCode(rest, flags);
  if (inline.length > 0) return { jq: false, code: inline };
  const fromStdin = (python || STDIN_CODE.has(lower)) && readsScriptFromStdin(rest);
  return { jq: false, code: fromStdin ? stdinCode(item) : [] };
}

function codeViolation(text, jq) {
  if (SELECTOR_ACCESS_RE.test(text)) return REASONS.selector;
  if (CODE_DUMP_RES.some((pattern) => pattern.test(text))) return REASONS.dump;
  if (jq && JQ_ENV_RE.test(text)) return REASONS.dump;
  return null;
}

function wordsViolation(words, item, context, depth) {
  if (depth > MAX_DEPTH) return null;
  const start = commandStart(words);
  if (start >= words.length) return null;
  const name = commandName(words[start].value, context.platform);
  const rest = words.slice(start + 1);
  const values = rest.map((word) => word.value);

  if (BACKGROUND_COMMANDS.has(name) || startsDetachedSession(name, rest)) return REASONS.background;
  if (name === 'eval') return scriptViolation(values.join(' '), context, depth + 1);
  const wrapper = Object.prototype.hasOwnProperty.call(WRAPPERS, name) ? WRAPPERS[name] : null;
  if (wrapper) {
    const inner = unwrap(wrapper, rest);
    const own = rest.slice(0, rest.length - inner.length);
    if (own.some((word) => SELECTOR_WORD_RE.test(optionValue(word.value)))) return REASONS.selector;
    if (inner.length === 0) return name === 'env' ? REASONS.dump : null;
    const directory = wrapper.chdir ? optionOperand(own, wrapper.chdir) : null;
    if (!directory || directory.dynamic || directory.value === '') return wordsViolation(inner, item, context, depth + 1);
    const cwd = resolveSpelling(context.cwd, wordPath(directory, context));
    return wordsViolation(inner, item, { ...context, cwd, cwds: [cwd] }, depth + 1);
  }

  const readOnly = READ_ONLY_COMMANDS.has(name)
    && !(name === 'find' && values.some((value) => FIND_EXEC_WORDS.has(value)));
  if (!readOnly && words.slice(start).some((word) => HELPER_RE.test(word.value))) return REASONS.helper;

  if (SHELLS.has(name)) {
    const flag = rest.findIndex((word) => shortFlagsInclude(word.value, 'c'));
    const scripts = flag === -1
      ? item.shellInput
      : [rest[flag + 1]].filter(Boolean).map((script) => script.value);
    for (const script of scripts) {
      const nested = scriptViolation(script, context, depth + 1);
      if (nested) return nested;
    }
  }

  const interpreter = interpreterCode(name, rest, item);
  if (interpreter) {
    for (const code of interpreter.code) {
      const violation = codeViolation(code, interpreter.jq);
      if (violation) return violation;
    }
  }

  if (SELECTOR_COMMANDS.has(name)
      && values.some((value) => SELECTOR_WORD_RE.test(value.replace(/^-[A-Za-z]/, '')))) {
    return REASONS.selector;
  }
  if (TEST_COMMANDS.has(name)
      && values.some((value, index) => value === '-v' && SELECTOR_NAME_RE.test(values[index + 1] || ''))) {
    return REASONS.selector;
  }

  const names = operands(rest);
  if (name === 'printenv' && names.length === 0) return REASONS.dump;
  if (name === 'set' && rest.length === 0) return REASONS.dump;
  const functionsOnly = rest.length > 0 && values.every((value) => /^-[fF]+$/.test(value));
  if (NAME_ONLY_DECLARATIONS.has(name) && names.length === 0 && !functionsOnly) return REASONS.dump;
  if (name === 'compgen' && values.some((value, index) => (
    shortFlagsInclude(value, 'e') || shortFlagsInclude(value, 'v')
    || (value === '-A' && ['export', 'variable'].includes(values[index + 1]))
  ))) {
    return REASONS.dump;
  }
  if (name === 'ps' && psShowsEnvironment(values)) return REASONS.dump;

  if (name === 'git') {
    const git = gitViolation(rest, context);
    if (git) return `the command runs a git operation that removes or reverts work (${git})`;
  }
  if (name === 'claude' && ['plugin', 'plugins'].includes(operands(rest).map((word) => word.value)[0])) return REASONS.plugin;
  if (REMOVING_COMMANDS.has(name)
      && removalTargets(name, rest).some((word) => removesProjectRoot(word, context))) {
    return REASONS.projectRoot;
  }
  if (name === 'find' && findDeletesProjectTree(rest, context)) return REASONS.projectRoot;
  return null;
}

function nextDirectories(words, context, current, history) {
  let start = commandStart(words);
  while (start < words.length && DIRECTORY_WRAPPERS.has(commandName(words[start].value, context.platform))) start += 1;
  if (start >= words.length) return current;
  const name = commandName(words[start].value, context.platform);
  if (name === 'popd') return [...history];
  if (name !== 'cd' && name !== 'pushd') return current;
  const targets = operands(words.slice(start + 1));
  if (targets.length === 0) return name === 'cd' && context.homeForm ? [context.homeForm] : [...history];
  const target = targets[0];
  if (target.dynamic || target.value === '-' || /^[+-][0-9]+$/.test(target.value)) return [...history];
  return [...new Set(current.map((directory) => resolveSpelling(directory, wordPath(materialized(target, directory), context))))];
}

function errexitAfter(words, enabled) {
  let state = enabled;
  const values = words.slice(commandStart(words) + 1).map((word) => word.value);
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (/^-[A-Za-z]*e[A-Za-z]*$/.test(value)) state = true;
    else if (/^\+[A-Za-z]*e[A-Za-z]*$/.test(value)) state = false;
    else if ((value === '-o' || value === '+o') && values[index + 1] === 'errexit') state = value === '-o';
  }
  return state;
}

function commandItemViolation(item, context, depth) {
  const words = item.words.map((word) => materialized(word, context.cwd));
  for (const word of words) {
    if (!ASSIGNMENT_RE.test(word.raw)) break;
    if (SELECTOR_WORD_RE.test(word.raw)) return REASONS.selector;
  }
  const candidates = [...words, ...item.redirects.map((redirect) => materialized(redirect.word, context.cwd))].slice(0, MAX_PATH_WORDS);
  for (const word of candidates) {
    const violation = pathWordViolation(word, context);
    if (violation) return violation;
  }
  const violation = wordsViolation(words, { ...item, shellInput: stdinCode(item, context.cwd) }, context, depth);
  if (violation) return violation;
  const nestedScripts = [...item.nested, ...item.heredocs.flatMap((heredoc) => heredoc.nestedScripts || [])];
  for (const script of nestedScripts) {
    const nested = scriptViolation(script, context, depth + 1);
    if (nested) return nested;
  }
  return null;
}

function expansionViolation(expansions) {
  for (const body of expansions) {
    if (INDIRECT_LISTING_RE.test(body)) return REASONS.dump;
    const name = body.replace(/^[!#]/, '').match(/^[A-Za-z_][A-Za-z0-9_]*/);
    if (name && SELECTOR_NAME_RE.test(name[0])) return REASONS.selector;
    if (!name && SELECTOR_IN_TEXT_RE.test(body)) return REASONS.selector;
  }
  return null;
}

function backgroundViolation(items, platform) {
  for (let index = 0; index < items.length; index += 1) {
    if (items[index].sep !== '&') continue;
    let depth = 0;
    let waited = false;
    for (let later = index + 1; later < items.length && !waited; later += 1) {
      const item = items[later];
      if (item.kind === 'open') {
        depth += 1;
      } else if (item.kind === 'close') {
        depth -= 1;
        if (depth < 0) break;
      } else if (depth === 0 && commandWord(item, platform) === 'wait') {
        waited = true;
      }
    }
    if (!waited) return REASONS.background;
  }
  return null;
}

function parseOptions(context) {
  return { platform: context.platform, home: context.home, root: context.root };
}

function scriptViolation(text, context, depth = 0) {
  if (depth > MAX_DEPTH || typeof text !== 'string' || text === '') return null;
  const parsed = parseScript(text, parseOptions(context));
  const expanded = expansionViolation(parsed.expansions);
  if (expanded) return expanded;
  const history = new Set(context.cwds);
  const stack = [];
  let state = { current: [...context.cwds], possible: new Set(context.cwds), errexit: false, previous: null };
  for (let position = 0; position < parsed.items.length; position += 1) {
    const item = parsed.items[position];
    if (item.kind === 'open') {
      stack.push({ ...state, current: [...state.current], possible: new Set(state.possible) });
      state = { ...state, previous: null };
      continue;
    }
    let next = state.current;
    if (item.kind === 'close') {
      if (stack.length > 0) state = stack.pop();
      next = state.current;
    } else {
      for (const cwd of state.current) {
        const violation = commandItemViolation(item, { ...context, cwd, cwds: [cwd] }, depth);
        if (violation) return violation;
      }
      if (commandWord(item, context.platform) === 'set') state.errexit = errexitAfter(item.words, state.errexit);
      next = nextDirectories(item.words, context, state.current, history);
    }
    const advanced = state.previous === '||' ? [...new Set([...next, ...state.current])] : next;
    for (const directory of advanced) {
      state.possible.add(directory);
      history.add(directory);
    }
    if (state.possible.size > MAX_DIRECTORIES) return REASONS.directories;
    const single = state.previous !== '&&' && state.previous !== '||';
    const terminates = item.sep === '||' && EXIT_COMMANDS.has(commandWord(parsed.items[position + 1], context.platform));
    if (item.sep === '&&') {
      state.current = advanced;
    } else if (terminates || (state.errexit && single && (item.sep === ';' || item.sep === null))) {
      state.possible = new Set(advanced);
      state.current = advanced;
    } else {
      state.current = [...state.possible];
    }
    state.previous = item.sep;
  }
  return backgroundViolation(parsed.items, context.platform);
}

function assignmentsOf(words) {
  const assignments = {};
  for (const word of words) {
    const match = /^([A-Za-z_][A-Za-z0-9_]*)\+?=/.exec(word.value);
    if (match) assignments[match[1]] = word.value.slice(match[0].length);
  }
  return assignments;
}

function commandInvocations(text, options = {}) {
  const platform = options.platform || process.platform;
  const parsing = { platform, home: options.home || '', root: options.root || '' };
  const fold = options.foldNames === true;
  const commands = [];
  const visitWords = (words, item, inherited, depth) => {
    if (depth > MAX_DEPTH) return;
    const start = commandStart(words);
    const environment = { ...inherited, ...assignmentsOf(words.slice(0, start)) };
    if (start >= words.length) return;
    const name = commandName(words[start].value, platform, fold);
    const rest = words.slice(start + 1);
    if (name === 'eval') {
      visitScript(rest.map((word) => word.value).join(' '), environment, depth + 1);
      return;
    }
    const wrapper = Object.prototype.hasOwnProperty.call(WRAPPERS, name) ? WRAPPERS[name] : null;
    if (wrapper) {
      const inner = unwrap(wrapper, rest);
      const own = rest.slice(0, rest.length - inner.length);
      visitWords(inner, item, wrapper.assignments ? { ...environment, ...assignmentsOf(own) } : environment, depth + 1);
      return;
    }
    if (SHELLS.has(name)) {
      const flag = rest.findIndex((word) => shortFlagsInclude(word.value, 'c'));
      const scripts = flag === -1 ? stdinCode(item) : [rest[flag + 1]].filter(Boolean).map((script) => script.value);
      for (const script of scripts) visitScript(script, environment, depth + 1);
    }
    commands.push({ name, environment, words: rest.map((word) => word.value) });
  };
  const visitScript = (script, inherited, depth) => {
    if (depth > MAX_DEPTH || typeof script !== 'string' || script === '') return;
    for (const item of parseScript(script, parsing).items) {
      if (item.kind !== 'command') continue;
      visitWords(item.words, item, inherited, depth);
      for (const nested of [...item.nested, ...item.heredocs.flatMap((heredoc) => heredoc.nestedScripts || [])]) {
        visitScript(nested, {}, depth + 1);
      }
    }
  };
  visitScript(typeof text === 'string' ? withoutMarkers(text) : text, {}, 0);
  return commands;
}

function withoutComments(text, context) {
  const parts = [];
  let last = 0;
  for (const [start, end] of parseScript(text, parseOptions(context)).comments) {
    parts.push(text.slice(last, start), ' '.repeat(end - start));
    last = end;
  }
  parts.push(text.slice(last));
  return parts.join('');
}

function textMention(value, context) {
  const raw = shellText(value, context.home, context.platform, context.root);
  const folded = foldCase(raw, context.platform);
  if (context.protectedForms.some((root) => mentionsPath(folded, root))) return 'protectedPath';
  if (/(?:^|[\s/=;|&(){}<>`,:])\.zensu(?=$|[\s/;|&(){}<>`,*?:\]])/.test(folded)) return 'workflowDirectory';
  if (TEXT_DUMP_RES.some((pattern) => pattern.test(raw))) return 'dump';
  return null;
}

function textViolation(value, context) {
  const kind = textMention(value, context);
  return kind ? REASONS[kind] : null;
}

function parentMention(value, context) {
  const raw = shellText(value, context.home, context.platform, context.root).trim();
  if (raw === '' || /[\r\n]/.test(raw)) return null;
  const resolved = resolveSpelling(context.cwd, foldCase(slashSpelling(raw, context.platform), context.platform));
  return spellingForms(resolved, context).some((form) => context.protectedParents.has(form)) ? 'protectedParent' : null;
}

function protectedParentsOf(forms, homeForm, projectForms) {
  const parents = new Set();
  for (const form of forms) {
    let current = collapse(`${form}/..`);
    while (depthOf(current) >= 2 && !(homeForm && isAncestorOrSelf(current, homeForm))) {
      if (!projectForms.some((root) => isAncestorOrSelf(current, root))) parents.add(current);
      current = collapse(`${current}/..`);
    }
  }
  return parents;
}

function guardContext(trusted, environment, options) {
  const platform = options.platform || process.platform;
  const fsModule = options.fs || fs;
  const homeValue = nonEmpty(environment.HOME) ? environment.HOME : os.homedir();
  const home = homeValue ? collapse(slashSpelling(homeValue, platform)) : '';
  const homeForm = home && home !== '/' ? foldCase(home, platform) : '';
  const absolute = (value) => nonEmpty(value) && absoluteCandidate(slashSpelling(value, platform), platform);
  const formsOf = (values) => [...new Set(values.flatMap((value) => pathForms(value, platform, fsModule)))];
  const stateForms = formsOf([
    trusted.pluginData,
    trusted.pluginRoot,
    trusted.contextFile,
    ...[environment.CLAUDE_PLUGIN_DATA, environment.CLAUDE_PLUGIN_ROOT].filter(absolute),
  ]);
  const configForms = formsOf(configLayers(environment).map((layer) => layer.file).filter(absolute));
  const projectForms = pathForms(trusted.projectRoot, platform, fsModule);
  const protectedForms = [...new Set([...stateForms, ...configForms])];
  const protectedParents = protectedParentsOf(stateForms, homeForm, projectForms);
  const start = spellPath(trusted.toolCwd || trusted.projectRoot || '/', platform);
  return {
    platform,
    fs: fsModule,
    home: home === '/' ? '' : home,
    homeForm,
    root: nonEmpty(trusted.projectRoot) ? collapse(slashSpelling(trusted.projectRoot, platform)) : '',
    protectedForms,
    protectedParents,
    protectedTargets: [...protectedForms, ...protectedParents],
    projectForms,
    cwd: start,
    cwds: [start],
  };
}

function inputStrings(input) {
  const strings = [];
  const pending = [input];
  let visited = 0;
  while (pending.length > 0) {
    const value = pending.pop();
    visited += 1;
    if (visited > 20000) throw new Error('tool input is too complex');
    if (typeof value === 'string') strings.push(value);
    else if (Array.isArray(value)) pending.push(...value);
    else if (value && typeof value === 'object') pending.push(...Object.values(value));
  }
  return strings;
}

function accidentReason(payload, trusted, environment = process.env, options = {}) {
  const input = isPlainObject(payload.tool_input) ? payload.tool_input : {};
  if (input.run_in_background === true) return REASONS.background;
  if (input.dangerouslyDisableSandbox === true) return REASONS.sandbox;
  const context = guardContext(trusted, environment, options);
  const raw = typeof input.command === 'string' ? input.command : null;
  const command = raw === null ? null : withoutMarkers(raw);
  const visible = command === null ? null : withoutComments(command, context);
  for (const value of inputStrings(input)) {
    const violation = textViolation(value === raw ? visible : value, context);
    if (violation) return violation;
  }
  if (command !== null) return scriptViolation(command, context, 0);
  return null;
}

function inputMention(payload, trusted, environment = process.env, options = {}) {
  const context = guardContext(trusted, environment, options);
  for (const value of inputStrings(payload.tool_input)) {
    const kind = textMention(value, context) || parentMention(value, context);
    if (kind) return MENTIONS[kind];
  }
  return null;
}

function shellViolation(payload, trusted, environment = process.env, options = {}) {
  const refusal = grantRefusal(payload, environment, options);
  if (refusal) return { kind: 'grant', reason: `${refusal}.` };
  const accident = accidentReason(payload, trusted, environment, options);
  if (accident) return { kind: 'guard', reason: `host-profile-v1 shell guard: ${accident}. ${GUARD_TAIL}` };
  return null;
}

module.exports = {
  CONFIG_KEY,
  GRANT_TAIL,
  GUARD_TAIL,
  MENTIONS,
  REASONS,
  accidentReason,
  commandInvocations,
  configAuthorities,
  grantRefusal,
  inputMention,
  isShellCall,
  parseScript,
  shellText,
  shellViolation,
  strictCandidates,
  strictFlagEnabled,
};
