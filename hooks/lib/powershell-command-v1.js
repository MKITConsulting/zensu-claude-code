'use strict';

const MAX_TEXT_LENGTH = 1048576;
const MAX_DEPTH = 64;
const MAX_RECORDS = 16384;
const MAX_VERDICT_DEPTH = 4;

const chars = (...codes) => codes.map((code) => String.fromCodePoint(code));
const OPAQUE_ARGUMENT = String.fromCharCode(0);
const NEWLINES = new Set(chars(0x0a, 0x0d, 0x85, 0x2028, 0x2029));
const SINGLE_QUOTES = new Set(chars(0x27, 0x2018, 0x2019, 0x201a, 0x201b));
const DOUBLE_QUOTES = new Set(chars(0x22, 0x201c, 0x201d, 0x201e));
const DASHES = new Set(chars(0x2d, 0x2013, 0x2014, 0x2015));
const PLAIN_SPACES = new Set(chars(0x09, 0x0b, 0x0c, 0x20, 0xa0, 0xfeff));
const WORD_STOPS = new Set([';', '|', '&', ')', '}', ',', '<', '>']);
const CLOSERS = new Set([')', '}', ']']);
const ESCAPES = Object.freeze({
  0: String.fromCharCode(0),
  a: String.fromCharCode(7),
  b: String.fromCharCode(8),
  e: String.fromCharCode(27),
  f: String.fromCharCode(12),
  n: String.fromCharCode(10),
  r: String.fromCharCode(13),
  t: String.fromCharCode(9),
  v: String.fromCharCode(11),
});

const KEYWORDS = new Set([
  'begin', 'break', 'catch', 'class', 'clean', 'configuration', 'continue', 'data', 'default', 'define',
  'do', 'dynamicparam', 'else', 'elseif', 'end', 'enum', 'exit', 'filter', 'finally', 'for', 'foreach',
  'from', 'function', 'hidden', 'if', 'in', 'inlinescript', 'parallel', 'param', 'process', 'return',
  'sequence', 'static', 'switch', 'throw', 'trap', 'try', 'until', 'using', 'var', 'while', 'workflow',
]);
const PIPELINE_KEYWORDS = new Set(['return', 'throw', 'exit']);
const DEFINITION_KEYWORDS = new Set(['function', 'filter', 'workflow', 'configuration']);
const TYPE_KEYWORDS = new Set(['class', 'enum']);
const VARIABLE_SCOPES = new Set(['global', 'local', 'script', 'private', 'using', 'workflow', 'env', 'variable', 'function', 'alias']);
const EXTENSIONS = new Set(['com', 'exe', 'bat', 'cmd', 'vbs', 'vbe', 'js', 'jse', 'wsf', 'wsh', 'msc', 'cpl', 'ps1']);
const NUMBER_RE = /^[+-]?(?:0x[0-9a-f]+|0b[01]+|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:e[+-]?[0-9]+)?)(?:ul|us|uy|u|y|s|l|n|d)?(?:kb|mb|gb|tb|pb)?$/i;
const RANGE_RE = /^[0-9]+\.\.[0-9]+$/;
const PARAMETER_PREFIX_RE = /^-[\p{L}_][\p{L}\p{N}_]*:/u;
const ENV_PROVIDER_RE = /^(?:env:|environment::|microsoft\.powershell\.core\\environment::)/i;
const DEFINITION_PROVIDER_RE = /^(?:function|alias):/i;
const START_ENVIRONMENT_RE = /\.environment(?:variables)?\s*(?:\[|\.\s*(?:add|item|remove|clear)\b)/i;

const ALIASES = Object.freeze({
  '%': 'foreach-object',
  '?': 'where-object',
  ac: 'add-content',
  asnp: 'add-pssnapin',
  cat: 'get-content',
  cd: 'set-location',
  cfs: 'convertfrom-string',
  chdir: 'set-location',
  clc: 'clear-content',
  clear: 'clear-host',
  clhy: 'clear-history',
  cli: 'clear-item',
  clp: 'clear-itemproperty',
  cls: 'clear-host',
  clv: 'clear-variable',
  cnsn: 'connect-pssession',
  compare: 'compare-object',
  copy: 'copy-item',
  cp: 'copy-item',
  cpi: 'copy-item',
  cpp: 'copy-itemproperty',
  curl: 'invoke-webrequest',
  cvpa: 'convert-path',
  dbp: 'disable-psbreakpoint',
  del: 'remove-item',
  diff: 'compare-object',
  dir: 'get-childitem',
  dnsn: 'disconnect-pssession',
  ebp: 'enable-psbreakpoint',
  echo: 'write-output',
  epal: 'export-alias',
  epcsv: 'export-csv',
  epsn: 'export-pssession',
  erase: 'remove-item',
  etsn: 'enter-pssession',
  exsn: 'exit-pssession',
  fc: 'format-custom',
  fhx: 'format-hex',
  fl: 'format-list',
  foreach: 'foreach-object',
  ft: 'format-table',
  fw: 'format-wide',
  gal: 'get-alias',
  gbp: 'get-psbreakpoint',
  gc: 'get-content',
  gcb: 'get-clipboard',
  gci: 'get-childitem',
  gcm: 'get-command',
  gcs: 'get-pscallstack',
  gdr: 'get-psdrive',
  gerr: 'get-error',
  ghy: 'get-history',
  gi: 'get-item',
  gin: 'get-computerinfo',
  gjb: 'get-job',
  gl: 'get-location',
  gm: 'get-member',
  gmo: 'get-module',
  gp: 'get-itemproperty',
  gps: 'get-process',
  gpv: 'get-itempropertyvalue',
  group: 'group-object',
  gsn: 'get-pssession',
  gsnp: 'get-pssnapin',
  gsv: 'get-service',
  gtz: 'get-timezone',
  gu: 'get-unique',
  gv: 'get-variable',
  gwmi: 'get-wmiobject',
  h: 'get-history',
  history: 'get-history',
  icm: 'invoke-command',
  iex: 'invoke-expression',
  ihy: 'invoke-history',
  ii: 'invoke-item',
  ipal: 'import-alias',
  ipcsv: 'import-csv',
  ipmo: 'import-module',
  ipsn: 'import-pssession',
  irm: 'invoke-restmethod',
  ise: 'powershell_ise',
  iwmi: 'invoke-wmimethod',
  iwr: 'invoke-webrequest',
  kill: 'stop-process',
  lp: 'out-printer',
  ls: 'get-childitem',
  man: 'help',
  md: 'mkdir',
  measure: 'measure-object',
  mi: 'move-item',
  mount: 'new-psdrive',
  move: 'move-item',
  mp: 'move-itemproperty',
  mv: 'move-item',
  nal: 'new-alias',
  ndr: 'new-psdrive',
  ni: 'new-item',
  nmo: 'new-module',
  npssc: 'new-pssessionconfigurationfile',
  nsn: 'new-pssession',
  nv: 'new-variable',
  ogv: 'out-gridview',
  oh: 'out-host',
  popd: 'pop-location',
  ps: 'get-process',
  pushd: 'push-location',
  pwd: 'get-location',
  r: 'invoke-history',
  rbp: 'remove-psbreakpoint',
  rcjb: 'receive-job',
  rcsn: 'receive-pssession',
  rd: 'remove-item',
  rdr: 'remove-psdrive',
  ren: 'rename-item',
  ri: 'remove-item',
  rjb: 'remove-job',
  rm: 'remove-item',
  rmdir: 'remove-item',
  rmo: 'remove-module',
  rni: 'rename-item',
  rnp: 'rename-itemproperty',
  rp: 'remove-itemproperty',
  rsn: 'remove-pssession',
  rsnp: 'remove-pssnapin',
  rujb: 'resume-job',
  rv: 'remove-variable',
  rvpa: 'resolve-path',
  rwmi: 'remove-wmiobject',
  sajb: 'start-job',
  sal: 'set-alias',
  saps: 'start-process',
  sasv: 'start-service',
  sbp: 'set-psbreakpoint',
  sc: 'set-content',
  scb: 'set-clipboard',
  select: 'select-object',
  set: 'set-variable',
  shcm: 'show-command',
  si: 'set-item',
  sl: 'set-location',
  sleep: 'start-sleep',
  sls: 'select-string',
  sort: 'sort-object',
  sp: 'set-itemproperty',
  spjb: 'stop-job',
  spps: 'stop-process',
  spsv: 'stop-service',
  start: 'start-process',
  stz: 'set-timezone',
  sujb: 'suspend-job',
  sv: 'set-variable',
  swmi: 'set-wmiinstance',
  tee: 'tee-object',
  trcm: 'trace-command',
  type: 'get-content',
  wget: 'invoke-webrequest',
  where: 'where-object',
  wjb: 'wait-job',
  write: 'write-output',
});

const READ_ONLY_COMMANDS = new Set([
  'clear-host', 'compare-object', 'convert-path', 'convertfrom-csv', 'convertfrom-json', 'convertfrom-stringdata',
  'convertto-csv', 'convertto-html', 'convertto-json', 'convertto-xml', 'foreach-object', 'format-custom',
  'format-hex', 'format-list', 'format-table', 'format-wide', 'get-acl', 'get-alias', 'get-childitem',
  'get-command', 'get-computerinfo', 'get-content', 'get-culture', 'get-date', 'get-error', 'get-filehash',
  'get-help', 'get-history', 'get-host', 'get-item', 'get-itemproperty', 'get-itempropertyvalue',
  'get-location', 'get-member', 'get-module', 'get-process', 'get-psdrive', 'get-psprovider', 'get-random',
  'get-service', 'get-timezone', 'get-uiculture', 'get-unique', 'get-uptime', 'get-variable', 'get-verb',
  'group-object', 'help', 'join-path', 'measure-command', 'measure-object', 'new-timespan', 'out-default',
  'out-host', 'out-null', 'out-string', 'pop-location', 'push-location', 'resolve-path', 'select-object',
  'select-string', 'select-xml', 'set-location', 'sort-object', 'split-path', 'start-sleep', 'test-json',
  'test-path', 'where-object', 'write-debug', 'write-error', 'write-host', 'write-information', 'write-output',
  'write-progress', 'write-verbose', 'write-warning',
]);
const ENV_WRITE_COMMANDS = new Set([
  'add-content', 'clear-content', 'clear-item', 'clear-itemproperty', 'copy-item', 'copy-itemproperty', 'mkdir',
  'move-item', 'move-itemproperty', 'new-item', 'new-itemproperty', 'remove-item', 'remove-itemproperty',
  'rename-item', 'rename-itemproperty', 'set-content', 'set-item', 'set-itemproperty',
]);
const DEFINITION_WRITE_COMMANDS = new Set(['copy-item', 'new-item', 'rename-item', 'set-item']);
const LOCATION_COMMANDS = new Set(['set-location', 'push-location']);
const DRIVE_COMMANDS = new Set(['new-psdrive']);
const LAUNCHERS = new Set([
  'add-type', 'invoke-command', 'invoke-expression', 'invoke-history', 'invoke-item', 'start-job', 'start-process',
  'start-threadjob',
]);
const NESTED_SHELLS = new Set([
  'bash', 'busybox', 'cmd', 'dash', 'doas', 'env', 'fish', 'gsudo', 'ksh', 'nice', 'nohup', 'powershell',
  'powershell_ise', 'pwsh', 'runas', 'sh', 'stdbuf', 'sudo', 'time', 'timeout', 'wsl', 'xargs', 'zsh',
]);
const POWERSHELL_HOSTS = new Set(['powershell', 'powershell_ise', 'pwsh']);
const POSIX_SHELLS = new Set(['bash', 'dash', 'fish', 'ksh', 'sh', 'zsh']);
const STRICT_RUNNERS = new Set(['cmd', 'doas', 'env', 'gsudo', 'runas', 'sudo', 'wsl']);
const POWERSHELL_VALUE_OPTIONS = Object.freeze([
  ['configurationfile', 'configurationf'], ['configurationname', 'config'], ['custompipename', 'cus'],
  ['ep', 'ep'], ['executionpolicy', 'ex'], ['if', 'if'], ['inputformat', 'inp'], ['of', 'of'], ['outputformat', 'o'],
  ['psconsolefile', 'psc'], ['settingsfile', 'settings'], ['wd', 'wd'], ['windowstyle', 'w'], ['workingdirectory', 'wo'],
]);
const ALIAS_DEFINERS = new Set(['import-alias', 'new-alias', 'set-alias']);
const SAFE_METHODS = new Set([
  'combine', 'compareto', 'contains', 'containskey', 'containsvalue', 'endswith', 'equals', 'format',
  'getdirectoryname', 'getenvironmentvariable', 'getextension', 'getfilename', 'getfilenamewithoutextension',
  'getfullpath', 'gettype', 'indexof', 'indexofany', 'isnullorempty', 'isnullorwhitespace', 'join', 'lastindexof',
  'padleft', 'padright', 'split', 'startswith', 'substring', 'tolower', 'tolowerinvariant', 'tostring', 'toupper',
  'toupperinvariant', 'trim', 'trimend', 'trimstart',
]);
const BLOCK_METHODS = new Set(['foreach', 'where']);
const CODE_METHODS = new Set(['create', 'expandstring', 'invokescript', 'newscriptblock']);
const SAFE_MEMBERS = new Set([
  ...SAFE_METHODS, 'basename', 'count', 'creationtime', 'definition', 'directory', 'directoryname', 'displayname',
  'extension', 'filename', 'fullname', 'id', 'key', 'lastwritetime', 'length', 'line', 'linenumber', 'mode', 'name',
  'path', 'processname', 'source', 'status', 'value', 'version',
]);

class AnalysisFault extends Error {
  constructor(reason) {
    super(reason);
    this.analysisFault = reason;
  }
}

function fault(reason) {
  throw new AnalysisFault(reason);
}

function track(state, list, record) {
  state.records += 1;
  if (state.records > MAX_RECORDS) fault('it holds more constructs than the check reads');
  list.push(record);
  return record;
}

function literal(state, text) {
  if (state.literals && text) state.literals.push(text);
  return text;
}

function isNewline(ch) {
  return ch !== undefined && NEWLINES.has(ch);
}

function isSpace(ch) {
  return ch !== undefined && (PLAIN_SPACES.has(ch) || (ch.charCodeAt(0) > 0x7f && /\p{Zs}/u.test(ch)));
}

function isIdentifierStart(ch) {
  return ch !== undefined && /[\p{L}_]/u.test(ch);
}

function isIdentifierPart(ch) {
  return ch !== undefined && /[\p{L}\p{N}_]/u.test(ch);
}

function isQuote(ch) {
  return ch !== undefined && (SINGLE_QUOTES.has(ch) || DOUBLE_QUOTES.has(ch));
}

function newlineEnd(text, pos) {
  return text[pos] === '\r' && text[pos + 1] === '\n' ? pos + 2 : pos + 1;
}

function skipSpace(state) {
  const text = state.text;
  for (;;) {
    const ch = text[state.pos];
    if (isSpace(ch)) {
      state.pos += 1;
      continue;
    }
    if (ch === '`' && isNewline(text[state.pos + 1])) {
      state.pos = newlineEnd(text, state.pos + 1);
      continue;
    }
    return;
  }
}

function skipBlank(state) {
  for (;;) {
    skipSpace(state);
    if (!isNewline(state.text[state.pos])) return;
    state.pos += 1;
  }
}

function atComment(state) {
  const ch = state.text[state.pos];
  return ch === '#' || (ch === '<' && state.text[state.pos + 1] === '#');
}

function skipComment(state) {
  const text = state.text;
  if (text[state.pos] === '<') {
    const end = text.indexOf('#>', state.pos + 2);
    if (end === -1) fault('an unterminated block comment');
    state.pos = end + 2;
    return;
  }
  while (state.pos < text.length && !isNewline(text[state.pos])) state.pos += 1;
}

function startsVariable(text, pos) {
  if (text[pos] !== '$') return false;
  const next = text[pos + 1];
  return next === '{' || next === '$' || next === '?' || next === '^' || isIdentifierPart(next);
}

function readVariable(state) {
  const text = state.text;
  let pos = state.pos + 1;
  const first = text[pos];
  if (first === '{') {
    let name = '';
    pos += 1;
    for (;;) {
      const ch = text[pos];
      if (ch === undefined) fault('an unterminated variable name');
      if (ch === '`') {
        if (text[pos + 1] === undefined) fault('an unterminated variable name');
        name += text[pos + 1];
        pos += 2;
        continue;
      }
      if (ch === '}') {
        pos += 1;
        break;
      }
      name += ch;
      pos += 1;
    }
    state.pos = pos;
    return { name: literal(state, name), braced: true };
  }
  if (first === '$' || first === '?' || first === '^') {
    state.pos = pos + 1;
    return { name: first, braced: false };
  }
  let name = '';
  while (isIdentifierPart(text[pos])) {
    name += text[pos];
    pos += 1;
  }
  if (text[pos] === ':' && text[pos + 1] !== ':' && isIdentifierPart(text[pos + 1])) {
    name += ':';
    pos += 1;
    while (isIdentifierPart(text[pos])) {
      name += text[pos];
      pos += 1;
    }
  }
  state.pos = pos;
  return { name, braced: false };
}

function variableKind(variable) {
  const name = String(variable.name).toLowerCase();
  const colon = name.indexOf(':');
  if (colon === -1) return { kind: 'variable', item: name };
  const scope = name.slice(0, colon);
  const item = name.slice(colon + 1);
  if (scope === 'env') return { kind: 'env', item };
  if (scope === 'function' || scope === 'alias') return { kind: scope, item };
  if (VARIABLE_SCOPES.has(scope)) return { kind: 'variable', item };
  return { kind: 'provider', item: name };
}

function newWord() {
  return {
    literal: true,
    value: '',
    prefix: '',
    open: true,
    raw: '',
    parts: 0,
    scriptBlock: false,
    hash: false,
    splat: false,
    typeName: null,
    variables: [],
    member: false,
    verbatim: '',
  };
}

function addLiteral(word, text) {
  word.value += text;
  if (word.open) word.prefix += text;
}

function addOpaque(word) {
  word.literal = false;
  word.open = false;
}

function normalizeDash(word) {
  for (const key of ['value', 'prefix']) {
    const text = word[key];
    if (text && DASHES.has(text[0]) && text[0] !== '-') word[key] = '-' + text.slice(1);
  }
}

function scanVerbatim(state) {
  const text = state.text;
  let value = '';
  for (;;) {
    const ch = text[state.pos];
    if (ch === undefined) fault('an unterminated string');
    if (SINGLE_QUOTES.has(ch)) {
      if (SINGLE_QUOTES.has(text[state.pos + 1])) {
        value += "'";
        state.pos += 2;
        continue;
      }
      state.pos += 1;
      return literal(state, value);
    }
    value += ch;
    state.pos += 1;
  }
}

function hereClose(text, pos, quotes) {
  let index = pos;
  while (text[index] === ' ' || text[index] === '\t') index += 1;
  return quotes.has(text[index]) && text[index + 1] === '@' ? index + 2 : -1;
}

function scanVerbatimHere(state) {
  const text = state.text;
  let value = '';
  const empty = hereClose(text, state.pos, SINGLE_QUOTES);
  if (empty !== -1) {
    state.pos = empty;
    return value;
  }
  for (;;) {
    const ch = text[state.pos];
    if (ch === undefined) fault('an unterminated here-string');
    if (isNewline(ch)) {
      const end = hereClose(text, newlineEnd(text, state.pos), SINGLE_QUOTES);
      if (end !== -1) {
        state.pos = end;
        return literal(state, value);
      }
    }
    value += ch;
    state.pos += 1;
  }
}

function scanEscape(state, value) {
  const text = state.text;
  const next = text[state.pos + 1];
  if (next === undefined) fault('an unterminated string');
  if (next === 'u' && text[state.pos + 2] === '{') {
    const close = text.indexOf('}', state.pos + 3);
    if (close === -1) fault('an unterminated escape sequence');
    const code = parseInt(text.slice(state.pos + 3, close), 16);
    state.pos = close + 1;
    return value + (Number.isInteger(code) && code >= 0 && code <= 0x10ffff ? String.fromCodePoint(code) : '');
  }
  state.pos += 2;
  return value + (Object.prototype.hasOwnProperty.call(ESCAPES, next) ? ESCAPES[next] : next);
}

function scanExpandable(state, depth, here) {
  const text = state.text;
  let value = '';
  let prefix = null;
  const finish = () => {
    literal(state, value);
    return { literal: prefix === null, value, prefix: prefix === null ? value : prefix };
  };
  if (here) {
    const empty = hereClose(text, state.pos, DOUBLE_QUOTES);
    if (empty !== -1) {
      state.pos = empty;
      return finish();
    }
  }
  for (;;) {
    const ch = text[state.pos];
    if (ch === undefined) fault(here ? 'an unterminated here-string' : 'an unterminated string');
    if (!here && DOUBLE_QUOTES.has(ch)) {
      if (DOUBLE_QUOTES.has(text[state.pos + 1])) {
        value += '"';
        state.pos += 2;
        continue;
      }
      state.pos += 1;
      return finish();
    }
    if (here && isNewline(ch)) {
      const end = hereClose(text, newlineEnd(text, state.pos), DOUBLE_QUOTES);
      if (end !== -1) {
        state.pos = end;
        return finish();
      }
    }
    if (ch === '`') {
      value = scanEscape(state, value);
      continue;
    }
    if (ch === '$') {
      if (text[state.pos + 1] === '(') {
        if (prefix === null) prefix = value;
        state.pos += 2;
        scanBlock(state, ')', 'subexpr', depth + 1);
        continue;
      }
      if (startsVariable(text, state.pos)) {
        if (prefix === null) prefix = value;
        readVariable(state);
        continue;
      }
    }
    value += ch;
    state.pos += 1;
  }
}

function addExpandable(word, part) {
  if (part.literal) {
    addLiteral(word, part.value);
    return;
  }
  addLiteral(word, part.prefix);
  addOpaque(word);
}

function scanPlainDouble(state) {
  const text = state.text;
  let value = '';
  for (;;) {
    const ch = text[state.pos];
    if (ch === undefined) fault('an unterminated string');
    if (DOUBLE_QUOTES.has(ch)) {
      if (DOUBLE_QUOTES.has(text[state.pos + 1])) {
        value += '"';
        state.pos += 2;
        continue;
      }
      state.pos += 1;
      return value;
    }
    if (ch === '`') {
      value = scanEscape(state, value);
      continue;
    }
    if (ch === '$' && (text[state.pos + 1] === '(' || startsVariable(text, state.pos))) return null;
    value += ch;
    state.pos += 1;
  }
}

function scanHereString(state, depth, word) {
  const text = state.text;
  const quote = text[state.pos + 1];
  let pos = state.pos + 2;
  while (text[pos] === ' ' || text[pos] === '\t') pos += 1;
  if (!isNewline(text[pos])) fault('a here-string header that does not end its line');
  state.pos = newlineEnd(text, pos);
  if (SINGLE_QUOTES.has(quote)) {
    addLiteral(word, scanVerbatimHere(state));
    return;
  }
  addExpandable(word, scanExpandable(state, depth, true));
}

function scanPrimary(state, depth, word, first) {
  const text = state.text;
  const ch = text[state.pos];
  const next = text[state.pos + 1];
  if (ch === '{') {
    state.pos += 1;
    scanBlock(state, '}', 'block', depth + 1);
    if (first) word.scriptBlock = true;
    addOpaque(word);
    return true;
  }
  if (ch === '(') {
    state.pos += 1;
    scanBlock(state, ')', 'paren', depth + 1);
    addOpaque(word);
    return true;
  }
  if (ch === '$') {
    if (next === '(') {
      state.pos += 2;
      scanBlock(state, ')', 'subexpr', depth + 1);
      addOpaque(word);
      return true;
    }
    if (startsVariable(text, state.pos)) {
      word.variables.push(readVariable(state));
      addOpaque(word);
      return true;
    }
    return false;
  }
  if (ch === '@' && first) {
    if (next === '(') {
      state.pos += 2;
      scanBlock(state, ')', 'arraysubexpr', depth + 1);
      addOpaque(word);
      return true;
    }
    if (next === '{') {
      state.pos += 2;
      scanBlock(state, '}', 'hash', depth + 1);
      word.hash = true;
      addOpaque(word);
      return true;
    }
    if (isQuote(next)) {
      scanHereString(state, depth, word);
      return true;
    }
    if (isIdentifierPart(next)) {
      state.pos += 1;
      while (isIdentifierPart(text[state.pos])) state.pos += 1;
      word.splat = true;
      addOpaque(word);
      return true;
    }
    return false;
  }
  if (SINGLE_QUOTES.has(ch)) {
    state.pos += 1;
    addLiteral(word, scanVerbatim(state));
    return true;
  }
  if (DOUBLE_QUOTES.has(ch)) {
    state.pos += 1;
    addExpandable(word, scanExpandable(state, depth, false));
    return true;
  }
  return false;
}

function peekLiteralArgument(state) {
  const probe = { text: state.text, pos: state.pos };
  try {
    skipBlank(probe);
    const ch = probe.text[probe.pos];
    if (ch === '{') return { literal: false, value: '', scriptBlock: true };
    let value = null;
    if (SINGLE_QUOTES.has(ch)) {
      probe.pos += 1;
      value = scanVerbatim(probe);
    } else if (DOUBLE_QUOTES.has(ch)) {
      probe.pos += 1;
      value = scanPlainDouble(probe);
    }
    if (value === null) return { literal: false, value: '' };
    skipBlank(probe);
    const after = probe.text[probe.pos];
    if (after === ',' || after === ')') return { literal: true, value };
  } catch (error) {
    if (!(error instanceof AnalysisFault)) throw error;
  }
  return { literal: false, value: '' };
}

function methodCall(state, depth, name, isStatic, typeName) {
  const record = track(state, state.methods, {
    name: name === null ? null : name.toLowerCase(),
    isStatic,
    typeName: typeName || null,
    firstArgument: { literal: false, value: '' },
  });
  record.firstArgument = peekLiteralArgument(state);
  scanBlock(state, ')', 'paren', depth + 1);
}

function memberAccess(state, depth, word, isStatic) {
  const text = state.text;
  const begin = state.pos + (isStatic ? 2 : 1);
  let name = '';
  let dynamic = false;
  let pos = begin;
  if (isIdentifierStart(text[pos])) {
    while (isIdentifierPart(text[pos])) {
      name += text[pos];
      pos += 1;
    }
  } else if (text[pos] === '$' || isQuote(text[pos])) {
    dynamic = true;
  } else {
    return false;
  }
  state.pos = pos;
  addOpaque(word);
  if (dynamic) {
    const member = newWord();
    if (!scanPrimary(state, depth, member, true)) {
      state.pos += 1;
    } else if (member.literal) {
      name = member.value;
      dynamic = false;
    }
  }
  if (text[state.pos] === '(') {
    state.pos += 1;
    methodCall(state, depth, dynamic ? null : name, isStatic, word.typeName);
  }
  return true;
}

function postfix(state, depth, word) {
  const text = state.text;
  for (;;) {
    let ch = text[state.pos];
    if (ch === '?' && (text[state.pos + 1] === '.' || text[state.pos + 1] === '[')) {
      state.pos += 1;
      ch = text[state.pos];
    }
    if (ch === '.' && text[state.pos + 1] !== '.') {
      if (!memberAccess(state, depth, word, false)) return;
      word.member = true;
      continue;
    }
    if (ch === ':' && text[state.pos + 1] === ':') {
      if (!memberAccess(state, depth, word, true)) return;
      word.member = true;
      continue;
    }
    if (ch === '[') {
      state.pos += 1;
      scanBlock(state, ']', 'bracket', depth + 1);
      addOpaque(word);
      word.member = true;
      continue;
    }
    return;
  }
}

function scanBareRun(state, word) {
  const text = state.text;
  const start = state.pos;
  let run = '';
  for (;;) {
    const ch = text[state.pos];
    if (ch === undefined || isSpace(ch) || isNewline(ch) || WORD_STOPS.has(ch)) break;
    if (ch === '(' || ch === '{' || isQuote(ch)) break;
    if (ch === '$' && (text[state.pos + 1] === '(' || startsVariable(text, state.pos))) break;
    if (ch === '`') {
      const next = text[state.pos + 1];
      if (next === undefined) fault('a dangling escape character');
      if (isNewline(next)) break;
      run += next;
      state.pos += 2;
      continue;
    }
    run += ch;
    state.pos += 1;
  }
  if (state.pos === start) {
    run = text[state.pos];
    state.pos += 1;
  }
  addLiteral(word, run);
}

function scanWord(state, depth) {
  const text = state.text;
  const word = newWord();
  const start = state.pos;
  for (;;) {
    const ch = text[state.pos];
    if (ch === undefined || isSpace(ch) || isNewline(ch) || WORD_STOPS.has(ch)) break;
    if (ch === '`' && isNewline(text[state.pos + 1])) break;
    if ((ch === '(' || ch === '{') && word.parts > 0) break;
    if (scanPrimary(state, depth, word, word.parts === 0)) {
      word.parts += 1;
      postfix(state, depth, word);
      continue;
    }
    scanBareRun(state, word);
    word.parts += 1;
  }
  word.raw = text.slice(start, state.pos);
  word.verbatim = word.value;
  normalizeDash(word);
  literal(state, word.value);
  return word;
}

function peekBareword(text, pos) {
  let index = pos;
  let value = '';
  for (;;) {
    const ch = text[index];
    if (ch === undefined || isSpace(ch) || isNewline(ch) || WORD_STOPS.has(ch)) break;
    if (ch === '(' || ch === '{' || isQuote(ch)) break;
    if (ch === '$' && (text[index + 1] === '(' || startsVariable(text, index))) break;
    if (ch === '`') {
      const next = text[index + 1];
      if (next === undefined || isNewline(next)) break;
      value += next;
      index += 2;
      continue;
    }
    value += ch;
    index += 1;
  }
  return { value, length: index - pos };
}

function nextVisible(text, pos) {
  let index = pos;
  while (isSpace(text[index])) index += 1;
  return text[index];
}

function dotSourceAt(text, pos) {
  const next = text[pos + 1];
  return text[pos] === '.' && (isSpace(next) || isQuote(next) || next === '$' || next === '(' || next === '{');
}

function isExpressionStart(ch) {
  return ch === '$' || ch === '@' || ch === '(' || ch === '[' || ch === '{' || ch === '!' || ch === '+' || ch === ','
    || isQuote(ch) || DASHES.has(ch);
}

function redirectionAt(text, pos) {
  const ch = text[pos];
  const next = text[pos + 1];
  if (ch === '>') {
    if (next === '>') return '>>';
    if (next === '&' && /[1-6]/.test(text[pos + 2] || '')) return '>&' + text[pos + 2];
    return '>';
  }
  if ((ch === '*' || /[1-6]/.test(ch || '')) && next === '>') {
    const after = text[pos + 2];
    if (after === '>') return ch + '>>';
    if (after === '&' && /[1-6]/.test(text[pos + 3] || '')) return ch + '>&' + text[pos + 3];
    return ch + '>';
  }
  return null;
}

function scanRedirection(state, depth, operator, list) {
  state.pos += operator.length;
  if (operator.includes('&')) {
    track(state, list, { operator, merge: true, target: null });
    return;
  }
  skipSpace(state);
  const ch = state.text[state.pos];
  if (ch === undefined || isNewline(ch) || ch === ';' || ch === '|' || ch === '&' || CLOSERS.has(ch)) {
    fault('a redirection without a target');
  }
  const target = scanWord(state, depth);
  track(state, list, { operator, merge: false, target });
}

function stopParsingAt(text, pos) {
  const after = text[pos + 3];
  return DASHES.has(text[pos]) && DASHES.has(text[pos + 1]) && text[pos + 2] === '%'
    && (after === undefined || isSpace(after) || isNewline(after));
}

function assignmentLength(text, pos) {
  const ch = text[pos];
  const next = text[pos + 1];
  if (ch === '=') return 1;
  if (next === '=' && (ch === '+' || ch === '*' || ch === '/' || ch === '%' || DASHES.has(ch))) return 2;
  if (ch === '?' && next === '?' && text[pos + 2] === '=') return 3;
  return 0;
}

function terminator(state, closer) {
  const text = state.text;
  const ch = text[state.pos];
  if (ch === undefined) return 'eof';
  if (isNewline(ch) || ch === ';') {
    state.pos += 1;
    return 'next';
  }
  if (CLOSERS.has(ch)) {
    if (ch === closer) {
      state.pos += 1;
      return 'close';
    }
    fault(`an unbalanced ${ch}`);
  }
  if (ch === '|') {
    state.pos += text[state.pos + 1] === '|' ? 2 : 1;
    return 'pipe';
  }
  if (ch === '&' && text[state.pos + 1] === '&') {
    state.pos += 2;
    return 'pipe';
  }
  return null;
}

function recordAssignment(state, word) {
  if (word && word.member) {
    track(state, state.assignments, { kind: 'member', item: '' });
    return;
  }
  if (!word || word.variables.length === 0) {
    track(state, state.assignments, { kind: 'other', item: '' });
    return;
  }
  const target = variableKind(word.variables[0]);
  track(state, state.assignments, target);
  if (target.kind === 'function' || target.kind === 'alias') {
    track(state, state.definitions, { kind: target.kind, name: target.item });
  }
}

function scanTypeOperand(state, depth) {
  const text = state.text;
  const open = state.pos;
  state.pos += 1;
  scanBlock(state, ']', 'bracket', depth + 1);
  const typeName = text.slice(open + 1, state.pos - 1).replace(/\s+/g, '').toLowerCase();
  track(state, state.types, typeName);
  const word = newWord();
  addOpaque(word);
  word.typeName = typeName;
  postfix(state, depth, word);
  return word;
}

function scanExpression(state, closer, depth) {
  const text = state.text;
  let target = null;
  for (;;) {
    skipSpace(state);
    if (atComment(state)) {
      skipComment(state);
      continue;
    }
    const end = terminator(state, closer);
    if (end) return end;
    const ch = text[state.pos];
    if (ch === '&') {
      state.pos += 1;
      return 'next';
    }
    const redirect = redirectionAt(text, state.pos);
    if (redirect) {
      scanRedirection(state, depth, redirect, state.redirections);
      continue;
    }
    if (ch === '<') fault('the reserved operator <');
    const assignment = assignmentLength(text, state.pos);
    if (assignment) {
      state.pos += assignment;
      recordAssignment(state, target);
      return 'assign';
    }
    if (ch === '[') {
      target = scanTypeOperand(state, depth);
      continue;
    }
    if (ch === '$' || ch === '@' || ch === '(' || ch === '{' || isQuote(ch)) {
      const word = newWord();
      if (!scanPrimary(state, depth, word, true)) {
        state.pos += 1;
        continue;
      }
      postfix(state, depth, word);
      target = word;
      continue;
    }
    if (DASHES.has(ch) && isIdentifierStart(text[state.pos + 1])) {
      state.pos += 1;
      while (isIdentifierPart(text[state.pos])) state.pos += 1;
      continue;
    }
    if (isIdentifierPart(ch)) {
      let run = '';
      while (isIdentifierPart(text[state.pos])
        || (text[state.pos] === '.' && /^[0-9]+$/.test(run) && /[0-9]/.test(text[state.pos + 1] || ''))) {
        run += text[state.pos];
        state.pos += 1;
      }
      if (run.toLowerCase() === 'in') return 'assign';
      const word = newWord();
      addLiteral(word, run);
      postfix(state, depth, word);
      continue;
    }
    state.pos += 1;
  }
}

function readDefinitionName(state) {
  skipSpace(state);
  const word = scanWord(state, 0);
  return word.literal ? word.value.toLowerCase() : '';
}

function scanTypeBody(state, closer, depth) {
  const text = state.text;
  for (;;) {
    skipBlank(state);
    const ch = text[state.pos];
    if (ch === '{') {
      state.pos += 1;
      scanBlock(state, '}', 'typebody', depth + 1);
      return scanExpression(state, closer, depth);
    }
    if (ch === undefined) fault('a class or enum declaration without a body');
    if (isIdentifierPart(ch) || ch === ':' || ch === ',' || ch === '.' || ch === '[' || ch === ']') {
      state.pos += 1;
      continue;
    }
    fault('a class or enum declaration this check cannot read');
  }
}

function scanKeyword(state, closer, depth, keyword) {
  if (PIPELINE_KEYWORDS.has(keyword)) return 'assign';
  if (DEFINITION_KEYWORDS.has(keyword) || TYPE_KEYWORDS.has(keyword)) {
    const name = readDefinitionName(state);
    track(state, state.definitions, { kind: keyword, name });
    if (TYPE_KEYWORDS.has(keyword)) return scanTypeBody(state, closer, depth);
  }
  return scanExpression(state, closer, depth);
}

function opaqueArgument(raw) {
  const word = newWord();
  addOpaque(word);
  word.raw = raw;
  return word;
}

function scanArguments(state, closer, depth, record) {
  const text = state.text;
  for (;;) {
    skipSpace(state);
    if (atComment(state)) {
      skipComment(state);
      continue;
    }
    const end = terminator(state, closer);
    if (end) return end;
    const ch = text[state.pos];
    if (ch === '&') {
      state.pos += 1;
      return 'next';
    }
    const redirect = redirectionAt(text, state.pos);
    if (redirect) {
      scanRedirection(state, depth, redirect, record.redirections);
      continue;
    }
    if (ch === '<') fault('the reserved operator <');
    if (ch === ',') {
      state.pos += 1;
      continue;
    }
    if (stopParsingAt(text, state.pos)) {
      state.pos += 3;
      const begin = state.pos;
      while (state.pos < text.length && !isNewline(text[state.pos]) && text[state.pos] !== '|') state.pos += 1;
      record.stopParsing = true;
      record.args.push(opaqueArgument(text.slice(begin, state.pos)));
      continue;
    }
    record.args.push(scanWord(state, depth));
  }
}

function displayText(raw) {
  const text = String(raw).replace(/[\x00-\x1f\x7f]/g, '?');
  return text.length > 80 ? text.slice(0, 77) + '...' : text;
}

function scanCommand(state, closer, depth, invocation) {
  const record = track(state, state.commands, {
    name: null,
    display: '',
    invocation,
    scriptBlock: false,
    args: [],
    redirections: [],
    stopParsing: false,
    depth,
  });
  skipSpace(state);
  const text = state.text;
  const ch = text[state.pos];
  if (ch === undefined || isNewline(ch) || ch === ';' || ch === '|' || ch === '&' || CLOSERS.has(ch) || atComment(state)) {
    fault('a call operator without a command');
  }
  const word = scanWord(state, depth);
  record.display = displayText(word.raw);
  if (word.scriptBlock && word.parts === 1) record.scriptBlock = true;
  else if (word.literal) record.name = normalizeCommandName(word.value);
  return scanArguments(state, closer, depth, record);
}

function scanElement(state, closer, depth) {
  const text = state.text;
  for (;;) {
    skipSpace(state);
    if (atComment(state)) {
      skipComment(state);
      continue;
    }
    const end = terminator(state, closer);
    if (end) return end;
    const ch = text[state.pos];
    if (ch === '&') {
      state.pos += 1;
      return scanCommand(state, closer, depth, 'call');
    }
    if (dotSourceAt(text, state.pos)) {
      state.pos += 1;
      return scanCommand(state, closer, depth, 'dot');
    }
    if (redirectionAt(text, state.pos) || ch === '<' || isExpressionStart(ch)) return scanExpression(state, closer, depth);
    const peek = peekBareword(text, state.pos);
    const lower = peek.value.toLowerCase();
    if (lower.length > 1 && lower[0] === ':' && isIdentifierStart(lower[1])) {
      state.pos += peek.length;
      continue;
    }
    if (KEYWORDS.has(lower) && !(lower === 'foreach' && nextVisible(text, state.pos + peek.length) !== '(')) {
      state.pos += peek.length;
      return scanKeyword(state, closer, depth, lower);
    }
    if (NUMBER_RE.test(peek.value) || RANGE_RE.test(peek.value)) return scanExpression(state, closer, depth);
    return scanCommand(state, closer, depth, 'bare');
  }
}

function scanStatement(state, closer, kind, depth) {
  let commandPosition = kind !== 'hash' && kind !== 'bracket' && kind !== 'typebody';
  for (;;) {
    const end = commandPosition ? scanElement(state, closer, depth) : scanExpression(state, closer, depth);
    if (end === 'pipe' || end === 'assign') {
      commandPosition = true;
      continue;
    }
    return end;
  }
}

function scanBlock(state, closer, kind, depth) {
  if (depth > MAX_DEPTH) fault('it nests deeper than the check reads');
  for (;;) {
    const end = scanStatement(state, closer, kind, depth);
    if (end === 'close') return;
    if (end === 'eof') {
      if (closer) fault(`an unterminated ${kind === 'bracket' ? 'bracket' : 'group'}`);
      return;
    }
  }
}

function analyze(text) {
  const state = {
    text: String(text),
    pos: 0,
    records: 0,
    commands: [],
    methods: [],
    redirections: [],
    assignments: [],
    definitions: [],
    types: [],
    literals: [],
  };
  let faultReason = null;
  if (state.text.length > MAX_TEXT_LENGTH) {
    faultReason = 'it is larger than the check reads';
  } else {
    try {
      scanBlock(state, null, 'top', 0);
    } catch (error) {
      if (!(error instanceof AnalysisFault)) throw error;
      faultReason = error.analysisFault;
    }
  }
  return {
    fault: faultReason,
    commands: state.commands,
    methods: state.methods,
    redirections: state.redirections,
    assignments: state.assignments,
    definitions: state.definitions,
    types: state.types,
    literals: state.literals,
  };
}

function normalizeCommandName(value) {
  const raw = String(value);
  const segments = raw.split(/[\\/]/);
  const moduleQualified = segments.length === 2 && !raw.includes('/') && /^[A-Za-z_][\w.]*$/.test(segments[0]);
  const hasPath = segments.length > 1 && !moduleQualified;
  let name = segments[segments.length - 1];
  if (/^[A-Za-z]:/.test(name)) name = name.slice(2);
  name = name.toLowerCase().replace(/[. ]+$/, '');
  const dot = name.lastIndexOf('.');
  if (dot > 0 && EXTENSIONS.has(name.slice(dot + 1))) name = name.slice(0, dot).replace(/[. ]+$/, '');
  if (!hasPath && Object.prototype.hasOwnProperty.call(ALIASES, name)) return ALIASES[name];
  return name;
}

function escapeRegExp(text) {
  return String(text).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function flatten(text) {
  return String(text).replace(/`/g, '');
}

const CONCATENATION_RE = /['"\u2018-\u201e]\s*\+\s*['"\u2018-\u201e]/g;

function joinConcatenations(text) {
  return flatten(text).replace(CONCATENATION_RE, '');
}

function namesZensu(text) {
  return /(?:^|[^A-Za-z0-9_.-])zensu(?![A-Za-z0-9_-])/i.test(flatten(text));
}

function namesWord(text, name) {
  const pattern = new RegExp(`(?<![A-Za-z0-9_])${escapeRegExp(name)}(?![A-Za-z0-9_])`, 'i');
  return pattern.test(String(text)) || pattern.test(flatten(text));
}

function envDriveMentioned(text) {
  const flat = flatten(text);
  return /(?:^|[^$\w{])env:/i.test(flat) || /environment::/i.test(flat);
}

function argumentPrefix(argument) {
  return String(argument.prefix || '').replace(PARAMETER_PREFIX_RE, '');
}

function targetsEnvironment(argument) {
  return ENV_PROVIDER_RE.test(argumentPrefix(argument));
}

function optionName(value) {
  const text = String(value);
  if (text.length < 2 || !(DASHES.has(text[0]) || text[0] === '/')) return null;
  return text.slice(1).replace(/:.*$/s, '').toLowerCase() || null;
}

function isEncodedParameter(value) {
  const option = optionName(value);
  if (!option) return false;
  if (option === 'ec' || option === 'ea') return true;
  return 'encodedcommand'.startsWith(option) || 'encodedarguments'.startsWith(option);
}

function isCommandOption(option) {
  return option === 'cwa' || 'command'.startsWith(option) || 'commandwithargs'.startsWith(option);
}

function takesPowerShellValue(option) {
  return POWERSHELL_VALUE_OPTIONS.some(([full, shortest]) => option.length >= shortest.length && full.startsWith(option));
}

function attachedValue(value) {
  const colon = value.indexOf(':');
  return colon === -1 ? null : value.slice(colon + 1);
}

function powershellCode(values, host) {
  const result = { encoded: false, stdin: false, dynamicOption: false, file: null, candidates: [] };
  if (values.some(isEncodedParameter)) return { ...result, encoded: true };
  const candidates = [];
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    const option = optionName(value);
    if (option === null) {
      if (host === 'pwsh') {
        result.file = { path: value, argsFrom: index + 1 };
        break;
      }
      candidates.push(values.slice(index).join(' '));
      continue;
    }
    if (option.includes(OPAQUE_ARGUMENT)) return { ...result, dynamicOption: true };
    const attached = attachedValue(value);
    if (isCommandOption(option)) {
      candidates.push([attached, ...values.slice(index + 1)].filter((part) => part !== null).join(' ') || '-');
      break;
    }
    if ('file'.startsWith(option)) {
      result.file = attached === null
        ? { path: index + 1 < values.length ? values[index + 1] : '', argsFrom: index + 2 }
        : { path: attached, argsFrom: index + 1 };
      break;
    }
    if (takesPowerShellValue(option) && attached === null) index += 1;
  }
  result.stdin = candidates.some((code) => code.trim() === '-')
    || (result.file !== null && result.file.path.trim() === '-')
    || (result.file === null && candidates.length === 0);
  result.candidates = candidates.filter((code) => code.trim() !== '-');
  return result;
}

function posixShellCode(values) {
  let code = false;
  let stdin = false;
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (value === '--' || value === '-') {
      const next = values[index + 1];
      if (next === undefined) return { mode: code ? 'code' : 'stdin', text: null };
      if (code) return { mode: 'code', text: next };
      return { mode: stdin ? 'stdin' : 'file', text: null };
    }
    if (value === '--rcfile' || value === '--init-file') {
      index += 1;
      continue;
    }
    if (value.startsWith('--')) {
      const equals = value.indexOf('=');
      const name = equals === -1 ? value : value.slice(0, equals);
      if (name.includes(OPAQUE_ARGUMENT)) return { mode: 'dynamic', text: null };
      if (/^--(?:help|version)$/i.test(value)) return { mode: 'file', text: null };
      if (/command/i.test(name)) {
        if (equals !== -1) return { mode: 'code', text: value.slice(equals + 1) };
        code = true;
      }
      continue;
    }
    if (value.length > 1 && (value[0] === '-' || value[0] === '+')) {
      const flags = value.slice(1);
      if (flags.includes(OPAQUE_ARGUMENT)) return { mode: 'dynamic', text: null };
      if (/c/i.test(flags)) code = true;
      if (/s/.test(flags)) stdin = true;
      if (/o/i.test(flags)) index += 1;
      continue;
    }
    if (code) return { mode: 'code', text: value };
    return { mode: stdin ? 'stdin' : 'file', text: null };
  }
  return { mode: code ? 'code' : 'stdin', text: null };
}

function wrappedShell(args) {
  const index = args.findIndex((argument) => argument.literal && NESTED_SHELLS.has(normalizeCommandName(argument.value)));
  if (index === -1) return null;
  return { name: normalizeCommandName(args[index].value), args: args.slice(index + 1) };
}

function argumentValues(args) {
  return args.map((argument) => (argument.literal ? argument.value : argument.prefix + OPAQUE_ARGUMENT));
}

function opaqueValues(args) {
  return args.map((argument) => (argument.literal ? argument.verbatim || argument.value : OPAQUE_ARGUMENT));
}

function nestedShellReason(name, args, options, level, strict = false) {
  if (level > MAX_VERDICT_DEPTH) return 'nests more shells than the check reads';
  const dynamic = args.some((argument) => !argument.literal);
  if (dynamic && (strict || STRICT_RUNNERS.has(name))) return 'passes text built at run time to another shell or wrapper';
  const values = argumentValues(args);
  if (POWERSHELL_HOSTS.has(name)) {
    const code = powershellCode(values, name);
    if (code.encoded) return 'passes an encoded command to PowerShell';
    if (code.dynamicOption) return 'passes a PowerShell option built at run time';
    if (code.stdin) return 'makes PowerShell read its command from standard input';
    for (const candidate of code.candidates) {
      if (candidate.includes(OPAQUE_ARGUMENT)) return 'passes PowerShell code built at run time';
      const nested = controlVerdict(candidate, options, level + 1);
      if (nested) return `runs PowerShell text in which ${nested}`;
    }
    return '';
  }
  if (POSIX_SHELLS.has(name)) {
    const code = posixShellCode(values);
    if (code.mode === 'dynamic') return 'passes a shell option built at run time';
    if (code.mode === 'stdin') return 'makes a shell read its code from standard input';
    if (code.mode === 'code' && (code.text === null || code.text.includes(OPAQUE_ARGUMENT))) {
      return 'passes shell code built at run time';
    }
    return '';
  }
  if (name === 'cmd' && /(?:^|[\s&|(])set\s+(?:\/[ap]\s+)?"?[^=\s"]*%/i.test(values.join(' '))) {
    return 'sets an environment variable whose name cmd builds at run time';
  }
  const inner = wrappedShell(args);
  return inner ? nestedShellReason(inner.name, inner.args, options, level + 1, strict) : '';
}

function startProcessReason(command, options, level) {
  const args = command.args;
  const rest = [];
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    const option = argument.literal ? optionName(argument.value) : null;
    if (option && option.length >= 2 && 'environment'.startsWith(option)) {
      const value = args[index + 1];
      if (!value || !value.hash || /[$(]/.test(value.raw)) return 'starts a process with an environment built at run time';
      index += 1;
      continue;
    }
    rest.push(argument);
  }
  const inner = wrappedShell(rest);
  return inner ? nestedShellReason(inner.name, inner.args, options, level, true) : '';
}

function commandControlReason(command, envMentioned, options, level) {
  const name = command.name;
  const display = command.display;
  const dynamic = name === null && !command.scriptBlock;
  if (command.stopParsing && (dynamic || NESTED_SHELLS.has(name))) {
    return `${display} passes text through the stop-parsing token --%`;
  }
  if (dynamic || ENV_WRITE_COMMANDS.has(name)) {
    for (const argument of command.args) {
      if (argument.literal) continue;
      if (targetsEnvironment(argument)) return `${display} writes the Environment provider under a name built at run time`;
      if (envMentioned && argument.prefix === '') {
        return `${display} writes a path built at run time while the command names the Environment provider`;
      }
    }
  }
  if (LOCATION_COMMANDS.has(name)) {
    for (const argument of command.args) {
      if (targetsEnvironment(argument)) return `${display} moves into the Environment provider`;
      if (!argument.literal && envMentioned && argument.prefix === '') {
        return `${display} moves to a location built at run time while the command names the Environment provider`;
      }
    }
  }
  if (DRIVE_COMMANDS.has(name) && command.args.some((argument) => !argument.literal || /environment/i.test(argument.value))) {
    return `${display} can map a drive onto the Environment provider`;
  }
  if (name === 'invoke-expression') {
    if (command.args.length === 0 || command.args.some((argument) => !argument.literal)) {
      return `${display} runs text built at run time`;
    }
    const nested = controlVerdict(command.args.map((argument) => argument.value).join(' '), options, level + 1);
    if (nested) return `${display} runs text in which ${nested}`;
  }
  if (name === 'add-type') {
    if (command.args.some((argument) => !argument.literal)) return `${display} compiles code built at run time`;
    if (command.args.some((argument) => /setenvironmentvariable/i.test(argument.value))) {
      return `${display} compiles code that sets environment variables`;
    }
  }
  if (name === 'start-process') {
    const reason = startProcessReason(command, options, level);
    if (reason) return `${display} ${reason}`;
  }
  if (NESTED_SHELLS.has(name)) {
    const reason = nestedShellReason(name, command.args, options, level);
    if (reason) return `${display} ${reason}`;
  }
  return '';
}

function isScriptBlockType(typeName) {
  return typeof typeName === 'string' && /(?:^|\.)scriptblock$/.test(typeName);
}

function isProcessType(typeName) {
  return typeof typeName === 'string' && /(?:^|\.)process$/.test(typeName);
}

function methodControlReason(method, options, level) {
  if (method.name === null) return 'it calls a .NET method whose name is built at run time';
  const first = method.firstArgument || { literal: false, value: '' };
  if (method.name === 'setenvironmentvariable') {
    return first.literal ? '' : 'it calls SetEnvironmentVariable with a name built at run time';
  }
  const codeSink = CODE_METHODS.has(method.name)
    && (method.name !== 'create' || isScriptBlockType(method.typeName) || (method.isStatic && method.typeName === null));
  if (codeSink) {
    if (!first.literal) return `it turns text built at run time into code through ${method.name}`;
    const nested = controlVerdict(first.value, options, level + 1);
    if (nested) return `it turns text into code in which ${nested}`;
  }
  if (method.name === 'start' && method.isStatic && (isProcessType(method.typeName) || method.typeName === null)
    && first.literal && NESTED_SHELLS.has(normalizeCommandName(first.value))) {
    return 'it starts a shell through Process.Start, which this check does not read';
  }
  return '';
}

function controlVerdict(text, options = {}, level = 0) {
  const source = String(text);
  if (level > MAX_VERDICT_DEPTH) return 'it nests more command text than the check reads';
  const analysis = analyze(source);
  const joined = joinConcatenations(source);
  const spellings = [source, flatten(source), joined, ...analysis.literals].join('\n');
  for (const name of options.names || []) {
    if (namesWord(spellings, name)) return `it names the protected Session Control input ${name}`;
  }
  if (typeof options.refersToEnvFile === 'function' && options.refersToEnvFile(spellings)) {
    return 'it names the file behind CLAUDE_ENV_FILE';
  }
  if (analysis.fault) return `it could not be read (${analysis.fault})`;
  const envMentioned = envDriveMentioned(source) || envDriveMentioned(joined);
  for (const command of analysis.commands) {
    const reason = commandControlReason(command, envMentioned, options, level);
    if (reason) return reason;
  }
  for (const method of analysis.methods) {
    const reason = methodControlReason(method, options, level);
    if (reason) return reason;
  }
  if (START_ENVIRONMENT_RE.test(flatten(source))) return 'it changes the environment of a process it starts';
  if (/processstartinfo/i.test(flatten(source))) return 'it builds a ProcessStartInfo, which this check does not read';
  return '';
}

function safeMethod(method) {
  if (method.name === null) return false;
  if (SAFE_METHODS.has(method.name)) return true;
  return BLOCK_METHODS.has(method.name) && Boolean(method.firstArgument && method.firstArgument.scriptBlock);
}

function memberInvocationReason(command) {
  let memberSeen = false;
  for (let index = 0; index < command.args.length; index += 1) {
    const argument = command.args[index];
    if (argument.scriptBlock || argument.hash) continue;
    const option = argument.literal ? optionName(argument.value) : null;
    if (option !== null && argument.value.startsWith('-')) {
      if ('membername'.startsWith(option)) {
        const value = command.args[index + 1];
        if (!value || !value.literal || !SAFE_MEMBERS.has(value.value.toLowerCase())) {
          return `${command.display} invokes a member this check does not know to be read-only`;
        }
        memberSeen = true;
        index += 1;
      }
      continue;
    }
    if (memberSeen) continue;
    if (!argument.literal || !SAFE_MEMBERS.has(argument.value.toLowerCase())) {
      return `${command.display} invokes a member this check does not know to be read-only`;
    }
    memberSeen = true;
  }
  return '';
}

function harmlessRedirection(entry) {
  return entry.merge || Boolean(entry.target && /^\$null$/i.test(entry.target.raw));
}

function refusal(reason) {
  return { readOnly: false, reason };
}

function readOnlyVerdict(text) {
  const analysis = analyze(text);
  if (analysis.fault) return refusal(`it could not be read (${analysis.fault})`);
  for (const command of analysis.commands) {
    if (command.stopParsing) return refusal(`${command.display} passes text through the stop-parsing token --%`);
    if (command.invocation === 'dot') return refusal('it dot-sources a script');
    if (command.name === null) {
      if (command.scriptBlock) continue;
      return refusal(`it runs a command whose name is built at run time (${command.display})`);
    }
    if (!READ_ONLY_COMMANDS.has(command.name)) return refusal(`${command.display} is not a read-only command`);
    if (command.name === 'foreach-object') {
      const reason = memberInvocationReason(command);
      if (reason) return refusal(reason);
    }
    if (command.redirections.some((entry) => !harmlessRedirection(entry))) return refusal('it redirects output into a file');
  }
  if (analysis.redirections.some((entry) => !harmlessRedirection(entry))) return refusal('it redirects output into a file');
  const method = analysis.methods.find((entry) => !safeMethod(entry));
  if (method) return refusal(`it calls the .NET method ${method.name || '(built at run time)'}`);
  if (analysis.assignments.some((entry) => entry.kind === 'provider')) return refusal('it assigns to a provider path');
  if (analysis.assignments.some((entry) => entry.kind === 'member' || entry.kind === 'other')) {
    return refusal('it assigns to a property or an element, which can change a file or an item');
  }
  return { readOnly: true, reason: '' };
}

function unjudged(reason) {
  return { unjudged: reason, invocations: [] };
}

function nestedZensu(command, level) {
  const values = argumentValues(command.args);
  if (POWERSHELL_HOSTS.has(command.name)) {
    const code = powershellCode(values, command.name);
    if (code.encoded) return unjudged(`${command.display} passes an encoded command to PowerShell`);
    if (code.dynamicOption) return unjudged(`${command.display} passes a PowerShell option built at run time`);
    if (code.stdin) return unjudged(`${command.display} reads its command from standard input`);
    const invocations = [];
    for (const candidate of code.candidates) {
      if (candidate.includes(OPAQUE_ARGUMENT)) return unjudged(`${command.display} runs PowerShell code built at run time`);
      const nested = zensuInvocations(candidate, level + 1);
      if (nested.unjudged) return nested;
      invocations.push(...nested.invocations);
    }
    if (code.file && !code.file.path.includes(OPAQUE_ARGUMENT) && normalizeCommandName(code.file.path) === 'zensu') {
      invocations.push({ envp: {}, rest: opaqueValues(command.args.slice(code.file.argsFrom)) });
    }
    return { unjudged: '', invocations };
  }
  if (POSIX_SHELLS.has(command.name) && posixShellCode(values).mode === 'file') return { unjudged: '', invocations: [] };
  return unjudged(`${command.display} can start another command`);
}

function zensuInvocations(text, level = 0) {
  const source = String(text);
  if (level > MAX_VERDICT_DEPTH) return unjudged('it nests more command text than the check reads');
  const analysis = analyze(source);
  if (!namesZensu(source) && !namesZensu(joinConcatenations(source)) && !namesZensu(analysis.literals.join('\n'))) {
    return { unjudged: '', invocations: [] };
  }
  if (analysis.fault) return unjudged(`the command could not be read (${analysis.fault})`);
  const invocations = [];
  for (const command of analysis.commands) {
    if (command.name === null) {
      if (command.scriptBlock) continue;
      return unjudged(`it runs a command whose name is built at run time (${command.display})`);
    }
    if (command.name === 'zensu') {
      if (command.invocation === 'dot') return unjudged('it dot-sources zensu');
      invocations.push({
        envp: {},
        rest: opaqueValues(command.args),
      });
      continue;
    }
    if (NESTED_SHELLS.has(command.name)) {
      const nested = nestedZensu(command, level);
      if (nested.unjudged) return nested;
      invocations.push(...nested.invocations);
      continue;
    }
    if (LAUNCHERS.has(command.name)) return unjudged(`${command.display} can start another command`);
    if (ALIAS_DEFINERS.has(command.name)) return unjudged(`${command.display} defines an alias`);
    if (DEFINITION_WRITE_COMMANDS.has(command.name)
      && command.args.some((argument) => DEFINITION_PROVIDER_RE.test(argumentPrefix(argument)))) {
      return unjudged(`${command.display} defines a function or an alias`);
    }
  }
  if (analysis.definitions.length > 0) return unjudged('it defines a function, filter or alias');
  const method = analysis.methods.find((entry) => !safeMethod(entry));
  if (method) return unjudged(`it calls the .NET method ${method.name || '(built at run time)'}`);
  return { unjudged: '', invocations };
}

module.exports = {
  ALIASES,
  LAUNCHERS: Object.freeze([...LAUNCHERS]),
  MAX_TEXT_LENGTH,
  NESTED_SHELLS: Object.freeze([...NESTED_SHELLS]),
  OPAQUE_ARGUMENT,
  READ_ONLY_COMMANDS: Object.freeze([...READ_ONLY_COMMANDS]),
  SAFE_METHODS: Object.freeze([...SAFE_METHODS]),
  analyze,
  controlVerdict,
  namesZensu,
  normalizeCommandName,
  readOnlyVerdict,
  zensuInvocations,
};
