'use strict';

const fs = require('node:fs');
const path = require('node:path');

const ALLOW_TOOLS = ['Read', 'Glob', 'Grep', 'LS', 'LSP', 'WebSearch', 'WebFetch', 'BashOutput', 'TodoWrite', 'TaskCreate', 'TaskUpdate', 'TaskList', 'TaskGet', 'ToolSearch'];
const SETUP_TOOLS = ['EnterWorktree'];
const PLAIN = /^[^;&|<>$`\\\r\n]*$/;
const QUIET = /\s+([12]?>\s*\/dev\/null|2>&1)(?=\s|$)/g;
const READ_COMMAND = /^(ls|cat|head|tail|wc|pwd|tree|file|stat|cd|grep|egrep|fgrep|rg|find|echo|printf|nl|true|test|\[)(\s|$)|^sed\s+-n\s+\d+(,\d+)?p(\s+[^\s-]\S*)*$|^git\s+(-C\s+\S+\s+)?(--no-pager\s+)?(status|log|diff|show|ls-files|rev-parse|check-ignore|version)(\s|$)|^git\s+(-C\s+\S+\s+)?(--no-pager\s+)?remote(\s+(-v|--verbose))?$|^(node\s+--test|npm\s+(run\s+)?test|pnpm\s+(run\s+)?test)(\s|$)|^(node\s+(--version|-v)|git\s+--version)$/;
const CONFIG_COMMAND = /^git\s+(-C\s+\S+\s+)?(--no-pager\s+)?config(?=\s|$)/;
const CONFIG_READS = new Set(['--get', '--get-all', '--get-regexp', '--list', '-l']);
const CONFIG_SUBCOMMANDS = new Set(['get', 'list']);
const CONFIG_SOURCES = new Set(['-f', '--file', '--blob']);
const CONFIG_FLAG = /^(--(global|system|local|worktree|show-origin|show-scope|name-only|null|includes|no-includes|fixed-value|all|regexp|bool|int|bool-or-int|path|expiry-date)|-z|--(type|default|value|file|blob)=.*)$/;
const CONFIG_STDIN = /^-?$|(^|\/)(dev|proc)(\/|$)/;
const CONFIG_GLOB = /[*?[\]]/;
const VERSION_PROGRAM = /^[\w.+-]+$/;
const NAME_FLAG = /^(test|\[|printf)\s(.*\s)?-[vR](\s|$)/;
const UNSAFE_FLAG = /(^|\s)(--output|--ext-diff|--pre|--watch|--stdin|--test-reporter-destination|--test-update-snapshots|-exec|-execdir|-delete|-ok|-okdir|-fprint|-fprint0|-fprintf|-fls)(=|\s|$)/;
const FOLLOW = /^tail\s(.*\s)?(-[A-Za-z0-9]*[fF][A-Za-z0-9]*|--follow)(=|\s|$)/;
const SETUP_COMMAND = /^git\s+(-C\s+\S+\s+)?(--no-pager\s+)?(worktree|checkout|switch|branch)(\s|$)/;
const QUOTED_META = /[;&|<>()$`\\{}*?[\]]/;
const SED_READ = /^sed\s+-n\s+\d+(,\d+)?p(\s+[^\s-]\S*)*$/;
const WRITE_FLAG = /^(--output|--ext-diff|--pre|--test-reporter-destination|--test-update-snapshots|--write|--fix|--in-place)(=|$)|^-(exec|execdir|ok|okdir|delete|fprint|fprint0|fprintf|fls)$/;
const ROUTE_FLAG = /zensu-delivery-route\.sh["']?\s+--(?:direct|build)(?=\s|$)|(?:^|\s)--tdd-begin(?=\s|$)/;
const MUTATION = /(^|[\s;&|/])zensu(?:\s+--?[\w-]+(?:=\S+)?)*\s+(?:[a-z][\w-]*\s+)?(create|update|delete|set|add|remove|link|import|move)\b/;
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=/;
const SUBST = '\u0001';
const EXPANDED = /[$\u0001*?{}[\]]/;
const KEYWORDS = new Set(['!', '{', '}', 'then', 'do', 'else', 'elif', 'if', 'while', 'until', 'done', 'fi', 'esac', 'time']);
const HEADERS = new Set(['for', 'select', 'case']);
const READ_PROGRAMS = new Set(['ls', 'cat', 'head', 'tail', 'wc', 'pwd', 'tree', 'file', 'stat', 'cd', 'grep', 'egrep', 'fgrep', 'rg', 'find', 'echo', 'printf', 'nl', 'true', 'test', '[', 'sed', 'git', 'node', 'npm', 'pnpm', 'yarn']);
const WRITE_PROGRAMS = new Set([
  'mkdir', 'rmdir', 'rm', 'mv', 'cp', 'ln', 'link', 'unlink', 'touch', 'chmod', 'chown', 'chgrp', 'chflags', 'tee', 'dd',
  'truncate', 'install', 'patch', 'mktemp', 'mkfifo', 'mknod', 'split', 'csplit', 'shred', 'sponge', 'rename', 'tar', 'zip',
  'unzip', 'gzip', 'gunzip', 'bzip2', 'bunzip2', 'xz', 'unxz', 'zstd', 'rsync', 'scp', 'sftp', 'ftp', 'curl', 'wget', 'ed',
  'ex', 'vi', 'vim', 'nvim', 'emacs', 'nano', 'pico', 'code', 'open', 'pbcopy', 'crontab', 'kill', 'pkill', 'killall',
  'shutdown', 'reboot', 'docker', 'podman', 'kubectl', 'helm', 'terraform', 'brew', 'apt', 'apt-get', 'yum', 'dnf',
  'pip', 'pip3', 'pipx', 'gem', 'bundle', 'cargo', 'go', 'mvn', 'gradle', 'dotnet', 'swift', 'xcodebuild', 'launchctl',
  'defaults', 'corepack', 'nvm', 'volta', 'fnm', 'asdf', 'mise',
]);
const RUN_PROGRAMS = new Set([
  'python', 'python2', 'python3', 'ruby', 'perl', 'php', 'lua', 'deno', 'bun', 'bunx', 'npx', 'pnpx', 'java', 'javac', 'gcc',
  'g++', 'clang', 'make', 'cmake', 'ninja', 'bash', 'sh', 'zsh', 'dash', 'ksh', 'fish', 'csh', 'tcsh', 'exec', 'eval',
  'source', '.', 'xargs', 'nohup', 'sudo', 'doas', 'timeout', 'watch', 'nice', 'ionice', 'stdbuf', 'builtin', 'parallel',
  'script', 'expect', 'osascript', 'awk', 'gawk', 'mawk', 'nawk', 'jshell', 'alias', 'trap',
]);
const GIT_READS = new Set(['status', 'log', 'diff', 'show', 'ls-files', 'rev-parse', 'check-ignore', 'blame', 'grep', 'shortlog', 'describe', 'cat-file', 'ls-tree', 'rev-list', 'for-each-ref', 'show-ref', 'merge-base', 'name-rev', 'check-attr', 'var', 'help', 'version']);
const PACKAGE_MANAGERS = new Set(['npm', 'pnpm', 'yarn']);
const PACKAGE_READS = new Set(['ls', 'list', 'la', 'll', 'view', 'info', 'show', 'why', 'explain', 'outdated', 'help', 'root', 'prefix', 'bin']);
const VERSION = ['--version', '-v'];
const END_REASON = 'Not available in this environment; end your turn now with one sentence naming what you would do next.';
const RETRY_REASON = 'This shell form is not supported in this run. Use plain read commands such as cat, sed -n, grep, ls or git status instead.';
const CONTINUE_REASON = 'No person can answer questions in this run.';
const SETUP_REASON = 'Worktrees and branches are not available in this environment; work in the current directory.';
const CAPTURE_REASON = 'Zensu work capture is not part of this run; continue the task without it.';
const CAPTURE_COMMAND = /ai-work-capture-v1\.js|(^|[^\w/.-])zensu\s+ai-work(\s|$)/;
const SETUP_SIGNALS = new Set(['git:worktree', 'git:branch', 'git:checkout', 'git:switch']);
const NODE_VARIABLE = /^node\s+\$\{?([A-Za-z_]\w*)\}?(?=\s|$)/;
const RETRY_CAP = 3;
const LIMIT = 4000;
const PART_LIMIT = 200;
const LABEL_CAP = 8;
const QUESTION_CAP = 4;

function bounded(value, limit) {
  const text = typeof value === 'string' ? value : value == null ? '' : JSON.stringify(value);
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
}

function flattenQuestion(input) {
  const parts = [];
  const questions = input && Array.isArray(input.questions) ? input.questions : [];
  for (const q of questions) {
    if (!q || typeof q !== 'object') continue;
    for (const key of ['header', 'question']) if (typeof q[key] === 'string') parts.push(q[key]);
    for (const o of Array.isArray(q.options) ? q.options : []) {
      if (!o || typeof o !== 'object') continue;
      for (const key of ['label', 'description']) if (typeof o[key] === 'string') parts.push(o[key]);
    }
  }
  if (!parts.length && input && typeof input.question === 'string') parts.push(input.question);
  return bounded(parts.join(' | '), LIMIT);
}

function questionLabels(input) {
  const questions = input && Array.isArray(input.questions) ? input.questions : [];
  return questions
    .filter((q) => q && typeof q === 'object')
    .slice(0, QUESTION_CAP)
    .map((q) => (Array.isArray(q.options) ? q.options : [])
      .slice(0, LABEL_CAP)
      .map((o) => (o && typeof o === 'object' && typeof o.label === 'string' ? bounded(o.label, PART_LIMIT) : '')));
}

function segments(command) {
  const parts = [];
  let current = '';
  let quote = '';
  for (let i = 0; i < command.length; i += 1) {
    const c = command[i];
    if (quote === "'") {
      if (c === quote) quote = '';
      else current += QUOTED_META.test(c) ? '_' : c;
      continue;
    }
    if (quote === '"') {
      if (c === quote) quote = '';
      else if (c === '$' || c === '`') return null;
      else if (c === '\\') {
        i += 1;
        current += '_';
      } else current += QUOTED_META.test(c) ? '_' : c;
      continue;
    }
    if (c === '"' || c === "'") {
      quote = c;
      continue;
    }
    if (c === '\\') {
      const next = command[i + 1];
      if (next === undefined) return null;
      current += QUOTED_META.test(next) ? '_' : next;
      i += 1;
      continue;
    }
    const pair = command.slice(i, i + 2);
    if (pair === '&&' || pair === '||') {
      parts.push(current);
      current = '';
      i += 1;
    } else if (c === '|' || c === ';' || c === '(' || c === ')') {
      parts.push(current);
      current = '';
    } else current += c;
  }
  if (quote) return null;
  parts.push(current);
  return parts.map((p) => p.trim()).filter(Boolean);
}

function readsDevice(args) {
  return args.some((word, i) => {
    if (CONFIG_SOURCES.has(word)) return CONFIG_STDIN.test(args[i + 1] || '');
    const value = /^--(file|blob)=(.*)$/.exec(word);
    return Boolean(value) && CONFIG_STDIN.test(value[2]);
  });
}

function configReads(args) {
  if (readsDevice(args)) return false;
  let reads = CONFIG_SUBCOMMANDS.has(args[0]);
  let i = reads ? 1 : 0;
  for (; i < args.length && args[i].startsWith('-'); i += 1) {
    const word = args[i];
    if (CONFIG_SOURCES.has(word)) i += 1;
    else if (CONFIG_READS.has(word)) reads = true;
    else if (!CONFIG_FLAG.test(word)) return false;
  }
  const names = args.slice(i);
  return reads || (names.length === 1 && names[0].includes('.'));
}

function configPart(part) {
  const head = CONFIG_COMMAND.exec(part);
  return Boolean(head) && !CONFIG_GLOB.test(part) && configReads(part.slice(head[0].length).split(/\s+/).filter(Boolean));
}

function expands(part) {
  const open = [];
  for (let i = 0; i < part.length; i += 1) {
    const c = part[i];
    if (c === '{') open.push(false);
    else if (c === '}' && open.length) {
      if (open.pop()) return true;
    } else if (open.length && (c === ',' || part.startsWith('..', i))) open[open.length - 1] = true;
  }
  return false;
}

function bashPart(raw) {
  const part = raw.replace(QUIET, '');
  if (!PLAIN.test(part) || expands(part)) return 'other';
  if ((READ_COMMAND.test(part) || configPart(part)) && !UNSAFE_FLAG.test(part) && !FOLLOW.test(part) && !NAME_FLAG.test(part)) return 'read';
  if (SETUP_COMMAND.test(part)) return 'setup';
  return 'other';
}

function provenDecision(command) {
  if (/[\r\n]/.test(command)) return null;
  const parts = segments(command);
  if (!parts || parts.length === 0) return null;
  const kinds = parts.map(bashPart);
  if (kinds.every((k) => k === 'read')) return 'ALLOW';
  if (kinds.every((k) => k !== 'other')) return 'SETUP';
  return null;
}

function closing(text, from) {
  let depth = 1;
  for (let i = from; i < text.length; i += 1) {
    if (text[i] === '\\') i += 1;
    else if (text[i] === '(') depth += 1;
    else if (text[i] === ')') {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

function backtick(text, from) {
  for (let i = from; i < text.length; i += 1) {
    if (text[i] === '\\') i += 1;
    else if (text[i] === '`') return i;
  }
  return -1;
}

function lex(text, base) {
  const parts = [];
  const signals = [];
  let words = [];
  let word = null;
  let bare = false;
  let start = -1;
  const take = () => {
    if (word !== null) words.push(word);
    word = null;
  };
  const descriptor = () => {
    if (word !== null && bare && /^\d+$/.test(word)) word = null;
    else take();
  };
  const cut = () => {
    take();
    if (words.length) parts.push({ at: base + start, words });
    words = [];
    start = -1;
  };
  const add = (s, at, plain) => {
    if (start < 0) start = at;
    bare = (word === null || bare) && plain === true;
    word = (word === null ? '' : word) + s;
  };
  const flag = (code, at, part) => signals.push({ at: base + at, code, part });
  const nested = (from, end) => {
    const inner = lex(text.slice(from, end < 0 ? text.length : end), base + from);
    parts.push(...inner.parts);
    signals.push(...inner.signals);
    return end < 0 ? text.length : end + 1;
  };
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    const next = text[i + 1];
    if (c === ' ' || c === '\t') {
      take();
      i += 1;
    } else if (c === '\n' || c === '\r') {
      cut();
      i += 1;
    } else if (c === '#' && word === null) {
      while (i < text.length && text[i] !== '\n') i += 1;
    } else if (c === '\\') {
      if (next !== undefined && next !== '\n') add(next, i);
      i += 2;
    } else if (c === "'" || (c === '$' && next === "'")) {
      if (c === '$') flag('ansi-c', i, text.slice(i, i + 40));
      const open = c === '$' ? i + 1 : i;
      const end = text.indexOf("'", open + 1);
      add(text.slice(open + 1, end < 0 ? text.length : end), i);
      i = end < 0 ? text.length : end + 1;
    } else if (c === '"') {
      let j = i + 1;
      let buf = '';
      while (j < text.length && text[j] !== '"') {
        if (text[j] === '\\' && j + 1 < text.length) {
          buf += text[j + 1];
          j += 2;
        } else if (text[j] === '$' && text[j + 1] === '(') {
          j = nested(j + 2, closing(text, j + 2));
          buf += SUBST;
        } else if (text[j] === '`') {
          j = nested(j + 1, backtick(text, j + 1));
          buf += SUBST;
        } else {
          buf += text[j];
          j += 1;
        }
      }
      add(buf, i);
      i = j + 1;
    } else if (c === '$' && next === '(') {
      add(SUBST, i);
      i = nested(i + 2, closing(text, i + 2));
    } else if (c === '`') {
      add(SUBST, i);
      i = nested(i + 1, backtick(text, i + 1));
    } else if ((c === '<' || c === '>') && next === '(') {
      if (c === '>') flag('process-substitution', i, text.slice(i, i + 40));
      take();
      i = nested(i + 2, closing(text, i + 2));
    } else if (c === '<' && next === '<' && text[i + 2] !== '<') {
      flag('heredoc', i, text.slice(i, i + 40).split('\n')[0]);
      cut();
      return { parts, signals };
    } else if (c === '<') {
      descriptor();
      let j = i + (text.startsWith('<<<', i) ? 3 : 1);
      if (text[j] === '&') j += 1;
      while (text[j] === ' ' || text[j] === '\t') j += 1;
      const source = /^("[^"]*"|'[^']*'|[^\s;&|<>()])*/.exec(text.slice(j))[0];
      for (let k = j; k < j + source.length; k += 1) {
        if (text[k] === '$' && text[k + 1] === '(') k = nested(k + 2, closing(text, k + 2)) - 1;
        else if (text[k] === '`') k = nested(k + 1, backtick(text, k + 1)) - 1;
      }
      i = j + source.length;
    } else if (c === '>' || (c === '&' && next === '>')) {
      if (c === '>') descriptor();
      else take();
      let j = c === '&' ? i + 2 : i + 1;
      if (text[j] === '>' || text[j] === '|') j += 1;
      if (text[j] === '&') {
        j += 1;
        while (j < text.length && /[0-9-]/.test(text[j])) j += 1;
      } else {
        while (text[j] === ' ' || text[j] === '\t') j += 1;
        const target = /^[^\s;&|<>()]*/.exec(text.slice(j))[0];
        if (target.replace(/^["']|["']$/g, '') !== '/dev/null') flag('redirect', i, text.slice(i, j + target.length));
        j += target.length;
      }
      i = j;
    } else if (c === '&' && next === '&') {
      cut();
      i += 2;
    } else if (c === '&') {
      flag('background', i, text.slice(Math.max(0, i - 60), i + 1).trim());
      cut();
      i += 1;
    } else if (c === '|') {
      cut();
      i += next === '|' || next === '&' ? 2 : 1;
    } else if (c === ';' || c === '(' || c === ')') {
      cut();
      i += 1;
    } else {
      add(c, i, true);
      i += 1;
    }
  }
  cut();
  return { parts, signals };
}

function gitSignal(rest) {
  let i = 0;
  while (i < rest.length && rest[i].startsWith('-')) {
    if (rest[i] === '-c' || rest[i].startsWith('--config-env')) return 'git:-c';
    i += rest[i] === '-C' ? 2 : 1;
  }
  const sub = rest[i];
  if (sub === undefined) return null;
  if (sub === 'remote') return rest.slice(i + 1).every((x) => x === '-v' || x === '--verbose') ? null : 'git:remote';
  if (sub === 'config') return configReads(rest.slice(i + 1)) ? null : 'git:config';
  return GIT_READS.has(sub) ? null : `git:${sub}`;
}

function partSignal(all) {
  if (HEADERS.has(all[0])) return null;
  let words = all;
  while (words.length && KEYWORDS.has(words[0])) words = words.slice(1);
  if (!words.length) return null;
  if (ASSIGNMENT.test(words[0])) return 'assignment';
  const program = words[0];
  if (program === '[[') return /(^|\s)-[vR](\s|$)/.test(words.slice(1).join(' ')) ? 'name-flag' : null;
  if (program !== '[' && EXPANDED.test(program)) return 'program:expanded';
  const name = program.slice(program.lastIndexOf('/') + 1);
  const rest = words.slice(1);
  const text = words.join(' ');
  if (MUTATION.test(text)) return 'zensu-mutation';
  const flagged = words.find((w) => WRITE_FLAG.test(w));
  if (flagged) return `flag:${flagged.split('=')[0]}`;
  if (VERSION_PROGRAM.test(program) && rest.length === 1 && (rest[0] === '--version' || (program === 'npx' && rest[0] === '-v'))) return null;
  if (program.includes('/') && !READ_PROGRAMS.has(name)) return `program:${program}`;
  if (WRITE_PROGRAMS.has(name) || RUN_PROGRAMS.has(name)) return `program:${name}`;
  if (name === 'node') return rest[0] === '--test' || (rest.length === 1 && VERSION.includes(rest[0])) ? null : 'program:node';
  if (PACKAGE_MANAGERS.has(name)) {
    const quiet = rest[0] === 'test' || (rest[0] === 'run' && rest[1] === 'test') || (rest.length === 1 && VERSION.includes(rest[0]))
      || PACKAGE_READS.has(rest[0]) || (rest[0] === 'config' && (rest[1] === 'get' || rest[1] === 'list'));
    return quiet ? null : `program:${name}`;
  }
  if (name === 'uniq') return rest.filter((w) => !w.startsWith('-')).length >= 2 ? 'program:uniq' : null;
  if (name === 'sed') return SED_READ.test(text) ? null : 'program:sed';
  if (name === 'sort') return rest.some((w) => /^-[A-Za-z]*o/.test(w) || w.startsWith('--output')) ? 'program:sort' : null;
  if (name === 'command') return rest[0] === '-v' || rest[0] === '-V' ? null : 'program:command';
  if (name === 'env') return rest.length ? 'program:env' : null;
  if (name === 'git') return gitSignal(rest);
  if (NAME_FLAG.test(`${name} ${rest.join(' ')}`)) return 'name-flag';
  return null;
}

function signalsOf(command, lexed) {
  const { parts, signals } = lexed || lex(command, 0);
  const found = [...signals];
  for (const p of parts) {
    const code = partSignal(p.words);
    const start = p.words.findIndex((w) => !KEYWORDS.has(w));
    if (code) found.push({ at: p.at, code, part: p.words.slice(Math.max(0, start)).join(' ').split(SUBST).join('$(…)') });
  }
  const route = ROUTE_FLAG.exec(command);
  if (route) found.push({ at: route.index, code: 'route-flag', part: route[0].trim() });
  return found.sort((a, b) => a.at - b.at);
}

function unproven(command) {
  if (/[\r\n]/.test(command)) return { code: 'multi-line', part: command.split(/\r?\n/)[0] };
  if (/[$`]/.test(command.replace(/'[^']*'/g, ''))) return { code: 'expansion', part: command };
  const parts = segments(command);
  if (!parts) return { code: 'unparsed', part: command };
  return { code: 'unlisted', part: parts.find((p) => bashPart(p) === 'other') || command };
}

function helperVariables(parts) {
  const names = new Set();
  for (const p of parts) {
    for (const w of p.words) {
      const name = /^([A-Za-z_]\w*)=/.exec(w);
      if (name && CAPTURE_COMMAND.test(w)) names.add(name[1]);
    }
  }
  return names;
}

function bashVerdict(command) {
  const text = String(command || '');
  if (!text.trim()) return { decision: 'END', code: 'empty', part: '' };
  const lexed = lex(text, 0);
  const signals = signalsOf(text, lexed);
  const capture = CAPTURE_COMMAND.test(text);
  const held = capture ? helperVariables(lexed.parts) : new Set();
  const runsHelper = (s) => CAPTURE_COMMAND.test(s.part) || (s.code === 'program:node' && held.has((NODE_VARIABLE.exec(s.part) || [])[1]));
  const deciding = signals.filter((s) => !SETUP_SIGNALS.has(s.code) && !(capture && runsHelper(s)));
  if (capture && !deciding.length) return { decision: 'SETUP', code: 'capture', part: '' };
  const proven = signals.some((s) => s.code === 'git:config') ? null : provenDecision(text);
  if (proven) return { decision: proven, code: proven === 'ALLOW' ? 'read' : 'setup', part: '' };
  if (deciding.length) return { decision: 'END', code: deciding[0].code, part: deciding[0].part };
  if (signals.length && /[\r\n]/.test(text)) return { decision: 'END', code: 'multi-line', part: text.split(/\r?\n/)[0] };
  if (signals.length) return { decision: 'SETUP', code: 'setup', part: signals[0].part };
  if (!lexed.parts.length) return { decision: 'END', code: 'empty', part: text };
  const cause = unproven(text);
  return { decision: 'RETRY', code: cause.code, part: cause.part };
}

function bashDecision(command) {
  return bashVerdict(command).decision;
}

function verdictFor(tool, input) {
  if (ALLOW_TOOLS.includes(tool)) return { decision: 'ALLOW' };
  if (SETUP_TOOLS.includes(tool)) return { decision: 'SETUP' };
  if (tool === 'Bash') return bashVerdict(String((input && input.command) || ''));
  if (tool === 'AskUserQuestion') return { decision: 'CONTINUE' };
  return { decision: 'END' };
}

function decide(tool, input) {
  return verdictFor(tool, input).decision;
}

function reasonFor(decision, code) {
  if (decision === 'CONTINUE') return CONTINUE_REASON;
  if (decision === 'SETUP') return code === 'capture' ? CAPTURE_REASON : SETUP_REASON;
  if (decision === 'RETRY') return RETRY_REASON;
  return END_REASON;
}

function record(tool, input, id, decision, detail) {
  const entry = { id: id || '', tool, decision };
  if (tool === 'Skill') entry.skill = bounded((input && (input.skill || input.name || input.command)) || '', 200);
  if (tool === 'Skill' && input && input.args) entry.args = bounded(input.args, LIMIT);
  if (tool === 'Bash') entry.command = bounded((input && input.command) || '', 400);
  if (input && (input.file_path || input.path || input.pattern)) entry.path = bounded(input.file_path || input.path || input.pattern, 400);
  if (tool === 'AskUserQuestion') {
    entry.question = flattenQuestion(input);
    entry.labels = questionLabels(input);
  }
  if (detail && detail.code) entry.code = detail.code;
  if (detail && detail.part) entry.part = bounded(detail.part, PART_LIMIT);
  if (detail && detail.cap) entry.cap = true;
  return entry;
}

function logged(dir) {
  try {
    return fs.readFileSync(path.join(dir, 'hook.log'), 'utf8').split('\n').filter((l) => l.startsWith('probe '));
  } catch (_) {
    return [];
  }
}

function retries(dir) {
  if (!dir) return 0;
  return logged(dir).filter((l) => {
    try {
      return JSON.parse(l.slice('probe '.length)).decision === 'RETRY';
    } catch (_) {
      return false;
    }
  }).length;
}

function append(dir, entry) {
  if (!dir) return;
  try {
    const file = path.join(dir, 'hook.log');
    const seq = logged(dir).length + 1;
    fs.appendFileSync(file, `probe ${JSON.stringify({ seq, ...entry })}\n`, { mode: 0o600 });
  } catch (_) {
    return;
  }
}

function main(raw, dir) {
  let payload = {};
  try { payload = JSON.parse(raw || '{}'); } catch (_) { payload = {}; }
  const tool = typeof payload.tool_name === 'string' ? payload.tool_name : '';
  const input = payload.tool_input && typeof payload.tool_input === 'object' ? payload.tool_input : {};
  let verdict = verdictFor(tool, input);
  if (verdict.decision === 'RETRY' && retries(dir) >= RETRY_CAP) verdict = { ...verdict, decision: 'END', cap: true };
  append(dir, record(tool, input, payload.tool_use_id, verdict.decision, verdict));
  if (verdict.decision === 'ALLOW') return '';
  return JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reasonFor(verdict.decision, verdict.code) } });
}

if (require.main === module) {
  let raw = '';
  process.stdin.on('data', (chunk) => { raw += chunk; });
  process.stdin.on('end', () => {
    const out = main(raw, process.env.ZENSU_ROUTE_EVAL_DIR || '');
    if (out) process.stdout.write(`${out}\n`);
  });
}

module.exports = {
  ALLOW_TOOLS,
  SETUP_TOOLS,
  READ_COMMAND,
  UNSAFE_FLAG,
  FOLLOW,
  QUIET,
  SETUP_COMMAND,
  WRITE_PROGRAMS,
  RUN_PROGRAMS,
  GIT_READS,
  MUTATION,
  ROUTE_FLAG,
  END_REASON,
  RETRY_REASON,
  CONTINUE_REASON,
  SETUP_REASON,
  CAPTURE_REASON,
  CAPTURE_COMMAND,
  SETUP_SIGNALS,
  RETRY_CAP,
  LABEL_CAP,
  QUESTION_CAP,
  segments,
  lex,
  signalsOf,
  bashVerdict,
  bashDecision,
  verdictFor,
  decide,
  reasonFor,
  flattenQuestion,
  questionLabels,
  record,
  main,
};
