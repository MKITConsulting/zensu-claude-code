#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const SAFE_BUILTINS = new Set([
  ':', '.', '[', 'alias', 'bg', 'bind', 'break', 'caller', 'cd', 'compgen', 'complete', 'compopt',
  'continue', 'declare', 'dirs', 'disown', 'echo', 'enable', 'exit', 'export', 'false', 'fc', 'fg',
  'getopts', 'hash', 'help', 'history', 'jobs', 'kill', 'let', 'local', 'logout', 'mapfile', 'popd',
  'printf', 'pushd', 'pwd', 'read', 'readarray', 'readonly', 'return', 'set', 'shift', 'shopt',
  'source', 'suspend', 'test', 'times', 'trap', 'true', 'type', 'typeset', 'ulimit', 'umask',
  'unalias', 'unset', 'wait',
]);
const DECLARERS = new Set(['declare', 'export', 'local', 'readonly', 'typeset']);
const WRAPPERS = new Set(['builtin', 'command']);
const LEADING_KEYWORDS = new Set(['!', 'do', 'elif', 'else', 'if', 'then', 'time', 'until', 'while']);
const STDIN_READERS = new Set(['cat', 'dd', 'head']);
const INPUT_REDIRECTS = new Set(['<', '<<', '<<-', '<<<', '<&', '<>']);
const REDIRECTS = ['<<<', '<<-', '&>>', '<<', '>>', '<&', '>&', '<>', '>|', '&>', '<', '>'];
const ASSIGNMENT = /^([A-Za-z_][A-Za-z0-9_]*)(\[[^=]*\])?\+?=/;
const ARRAY_OPEN = /^[A-Za-z_][A-Za-z0-9_]*(\[[^=]*\])?\+?=$/;
const NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
const WORD_END = /[ \t\r\n;&|()<>]/;
const BLANK = /[ \t\r\n]/;

class ParseError extends Error {
  constructor(message, line) {
    super(message);
    this.line = line;
  }
}

class ShellLexer {
  constructor(src, file, sink, lineOffset, scope) {
    this.src = src;
    this.file = file;
    this.sink = sink;
    this.lineOffset = lineOffset;
    this.i = 0;
    this.scopes = [scope];
    this.lists = [];
    this.pendingFunction = null;
    this.heredocs = [];
    this.newlines = [];
    for (let k = 0; k < src.length; k++) if (src[k] === '\n') this.newlines.push(k);
  }

  run() {
    const id = this.readList(null);
    if (this.scopes.length !== 1) this.fail('unclosed {', this.src.length);
    if (this.heredocs.length) this.fail('unterminated heredoc ' + this.heredocs[0].delimiter, this.heredocs[0].at);
    return id;
  }

  lineOf(index) {
    let lo = 0;
    let hi = this.newlines.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (this.newlines[mid] < index) lo = mid + 1;
      else hi = mid;
    }
    return this.lineOffset + lo + 1;
  }

  fail(message, index) {
    throw new ParseError(message, this.lineOf(index));
  }

  currentFunction() {
    for (let k = this.scopes.length - 1; k >= 0; k--) if (this.scopes[k]) return this.scopes[k];
    return null;
  }

  takePendingFunction() {
    const name = this.pendingFunction;
    this.pendingFunction = null;
    return name;
  }

  defineFunction(name) {
    if (!this.sink.definitions.has(name)) this.sink.definitions.set(name, new Set());
    this.sink.definitions.get(name).add(this.file);
    this.pendingFunction = name;
  }

  blankWord(start) {
    return { start, line: this.lineOf(start), text: '', literal: '', plain: true, refs: new Set(), substs: [] };
  }

  newSegment() {
    return {
      file: this.file, list: this.lists[this.lists.length - 1], fn: null, start: -1, line: 0,
      state: 'command', kind: null, assigns: [], cmd: null, args: [], redirs: [], loopHead: false,
      testMode: false, caseWords: 0, text: '',
    };
  }

  finishSegment(segment) {
    if (!segment.cmd && !segment.assigns.length) return;
    segment.text = this.src.slice(segment.start, this.i).replace(/\\\r?\n/g, ' ').replace(/\s+/g, ' ').trim();
    this.sink.segments.push(segment);
  }

  delimiterAt(index) {
    const c = this.src[index];
    return c === undefined || /[ \t\r\n;&|)<>]/.test(c);
  }

  atKeyword(keyword) {
    return this.src.startsWith(keyword, this.i) && this.delimiterAt(this.i + keyword.length);
  }

  readList(closer) {
    const id = ++this.sink.listCount;
    this.lists.push(id);
    const cases = [];
    const src = this.src;
    let segment = this.newSegment();
    const end = () => {
      this.finishSegment(segment);
      segment = this.newSegment();
    };
    for (;;) {
      if (cases.length && cases[cases.length - 1].expectPattern) {
        this.skipSeparators();
        if (this.atKeyword('esac')) {
          this.i += 4;
          cases.pop();
          segment.kind = 'closed';
          continue;
        }
        this.readCasePattern();
        cases[cases.length - 1].expectPattern = false;
        continue;
      }
      if (this.i >= src.length) {
        end();
        if (closer !== null) this.fail('unterminated $( or (', this.i);
        if (cases.length) this.fail('unclosed case', this.i);
        break;
      }
      const c = src[this.i];
      const next = src[this.i + 1];
      if (c === '\\' && next === '\n') {
        this.i += 2;
        continue;
      }
      if (segment.testMode) {
        if (BLANK.test(c)) {
          this.i++;
          continue;
        }
        if (src.startsWith(']]', this.i) && this.delimiterAt(this.i + 2)) {
          this.i += 2;
          segment.testMode = false;
          continue;
        }
        segment.args.push(this.readWord('test'));
        continue;
      }
      if (c === ' ' || c === '\t' || c === '\r') {
        this.i++;
        continue;
      }
      if (c === '\n') {
        this.i++;
        end();
        this.readHeredocBodies();
        continue;
      }
      if (c === '#') {
        this.skipComment();
        continue;
      }
      if (c === ')') {
        if (closer !== ')') this.fail('unexpected )', this.i);
        this.i++;
        end();
        break;
      }
      if (c === ';') {
        if (next === ';' || next === '&') {
          this.i += next === ';' && src[this.i + 2] === '&' ? 3 : 2;
          end();
          if (!cases.length) this.fail('case terminator outside case', this.i);
          cases[cases.length - 1].expectPattern = true;
          continue;
        }
        this.i++;
        end();
        continue;
      }
      if (c === '&' && next !== '>') {
        this.i += next === '&' ? 2 : 1;
        end();
        continue;
      }
      if (c === '|') {
        this.i += next === '|' || next === '&' ? 2 : 1;
        end();
        continue;
      }
      if (c === '(') {
        if (this.atFunctionHeader(segment)) {
          if (segment.kind !== 'function-def') this.defineFunction(segment.cmd.literal);
          this.i = src.indexOf(')', this.i) + 1;
          segment = this.newSegment();
          continue;
        }
        if (segment.state !== 'command' || segment.assigns.length) this.fail('unexpected (', this.i);
        if (next === '(') {
          this.skipParenthesized(this.i);
          segment.kind = 'skip';
          continue;
        }
        this.i++;
        this.scopes.push(this.takePendingFunction());
        this.readList(')');
        this.scopes.pop();
        continue;
      }
      const fd = /^(?:[0-9]+|\{[A-Za-z_][A-Za-z0-9_]*\})(?=[<>])/.exec(src.slice(this.i, this.i + 40));
      if (fd || ((c === '<' || c === '>') && next !== '(') || (c === '&' && next === '>')) {
        if (segment.start < 0) segment.start = this.i;
        if (fd) this.i += fd[0].length;
        this.readRedirect(segment);
        continue;
      }
      const word = this.readWord('normal');
      if (word.text === '') this.fail('unexpected character ' + JSON.stringify(c), this.i);
      this.placeWord(segment, word, cases);
      if (segment.kind === 'case-open') end();
    }
    this.lists.pop();
    return id;
  }

  atFunctionHeader(segment) {
    const named = segment.kind === 'function-def'
      || (segment.kind === null && segment.state === 'args' && !segment.assigns.length && !segment.args.length
        && segment.cmd.plain && /^[A-Za-z_][A-Za-z0-9_:.-]*$/.test(segment.cmd.literal));
    if (!named) return false;
    let k = this.i + 1;
    while (this.src[k] === ' ' || this.src[k] === '\t') k++;
    return this.src[k] === ')';
  }

  placeWord(segment, word, cases) {
    if (segment.start < 0) segment.start = word.start;
    const literal = word.plain ? word.literal : null;
    switch (segment.kind) {
      case 'skip':
      case 'test':
        return;
      case 'case-head':
        segment.caseWords++;
        if (literal === 'in' && segment.caseWords >= 2) {
          cases.push({ expectPattern: true });
          segment.kind = 'case-open';
        }
        return;
      case 'function-name':
        if (literal === null || !/^[A-Za-z_][A-Za-z0-9_:.-]*$/.test(literal)) this.fail('unnamed function', word.start);
        this.defineFunction(literal);
        segment.kind = 'function-def';
        return;
      case 'function-def':
        if (literal !== '{') this.fail('unexpected word after a function name', word.start);
        this.scopes.push(this.takePendingFunction());
        segment.kind = null;
        return;
      case 'closed':
        this.fail('unexpected word after a closing keyword', word.start);
        return;
      default:
        break;
    }
    if (segment.state === 'command' && literal !== null && !segment.assigns.length) {
      if (LEADING_KEYWORDS.has(literal)) {
        if (literal === 'while' || literal === 'until') segment.loopHead = true;
        return;
      }
      switch (literal) {
        case '{':
          this.scopes.push(this.takePendingFunction());
          return;
        case '}':
          if (this.scopes.length <= 1) this.fail('unbalanced }', word.start);
          this.scopes.pop();
          segment.kind = 'closed';
          return;
        case 'fi':
        case 'done':
          segment.kind = 'closed';
          return;
        case 'esac':
          if (!cases.length) this.fail('esac without case', word.start);
          cases.pop();
          segment.kind = 'closed';
          return;
        case 'case':
          segment.kind = 'case-head';
          return;
        case 'for':
        case 'select':
          segment.kind = 'skip';
          return;
        case 'function':
          segment.kind = 'function-name';
          return;
        case '[[':
          segment.kind = 'test';
          segment.testMode = true;
          return;
        default:
          break;
      }
    }
    if (segment.state === 'command') {
      if (!segment.line) {
        segment.fn = this.currentFunction();
        segment.line = word.line;
      }
      if (ASSIGNMENT.test(word.text)) segment.assigns.push(word);
      else {
        segment.cmd = word;
        segment.state = 'args';
      }
      return;
    }
    segment.args.push(word);
  }

  readRedirect(segment) {
    const src = this.src;
    const op = REDIRECTS.find((candidate) => src.startsWith(candidate, this.i));
    if (!op) this.fail('unknown redirection', this.i);
    this.i += op.length;
    while (src[this.i] === ' ' || src[this.i] === '\t') this.i++;
    const target = this.readWord('normal');
    if (target.text === '') this.fail('redirection without a target', this.i);
    if (op === '<<' || op === '<<-') {
      this.heredocs.push({ delimiter: target.literal, strip: op === '<<-', quoted: !target.plain, at: target.start });
    }
    segment.redirs.push({ op, word: target });
  }

  readHeredocBodies() {
    const src = this.src;
    while (this.heredocs.length) {
      const heredoc = this.heredocs.shift();
      const bodyStart = this.i;
      for (;;) {
        if (this.i >= src.length) this.fail('unterminated heredoc ' + heredoc.delimiter, heredoc.at);
        let lineEnd = src.indexOf('\n', this.i);
        if (lineEnd < 0) lineEnd = src.length;
        let line = src.slice(this.i, lineEnd).replace(/\r$/, '');
        if (heredoc.strip) line = line.replace(/^\t+/, '');
        if (line === heredoc.delimiter) {
          const bodyEnd = this.i;
          this.i = Math.min(lineEnd + 1, src.length);
          if (!heredoc.quoted) this.scanHeredocBody(bodyStart, bodyEnd);
          break;
        }
        this.i = lineEnd + 1;
      }
    }
  }

  scanHeredocBody(start, end) {
    const resume = this.i;
    const sink = this.blankWord(start);
    this.i = start;
    while (this.i < end) {
      const c = this.src[this.i];
      if (c === '\\') this.i += 2;
      else if (c === '$') this.readDollar(sink, true);
      else if (c === '`') this.readBackquote(sink);
      else this.i++;
    }
    this.i = resume;
  }

  skipComment() {
    const end = this.src.indexOf('\n', this.i);
    this.i = end < 0 ? this.src.length : end;
  }

  skipSeparators() {
    const src = this.src;
    for (;;) {
      const c = src[this.i];
      if (c === ' ' || c === '\t' || c === '\r') this.i++;
      else if (c === '\\' && src[this.i + 1] === '\n') this.i += 2;
      else if (c === '\n') {
        this.i++;
        this.readHeredocBodies();
      } else if (c === '#') this.skipComment();
      else return;
    }
  }

  readCasePattern() {
    const src = this.src;
    const open = this.i;
    if (src[this.i] === '(') this.i++;
    for (;;) {
      while (src[this.i] === ' ' || src[this.i] === '\t' || (src[this.i] === '\\' && src[this.i + 1] === '\n')) {
        this.i += src[this.i] === '\\' ? 2 : 1;
      }
      const c = src[this.i];
      if (c === ')') {
        this.i++;
        return;
      }
      if (c === '|') {
        this.i++;
        continue;
      }
      if (c === undefined || c === '\n') this.fail('unterminated case pattern', open);
      const word = this.readWord('pattern');
      if (word.text === '') this.fail('unexpected character in a case pattern', this.i);
    }
  }

  skipParenthesized(open) {
    let depth = 0;
    for (let k = open; k < this.src.length; k++) {
      const c = this.src[k];
      if (c === '\\') {
        k++;
        continue;
      }
      if (c === '(') depth++;
      else if (c === ')') {
        depth--;
        if (depth === 0) {
          this.i = k + 1;
          return;
        }
      }
    }
    this.fail('unbalanced parenthesis', open);
  }

  readWord(mode) {
    const src = this.src;
    const word = this.blankWord(this.i);
    while (this.i < src.length) {
      const c = src[this.i];
      const next = src[this.i + 1];
      if (c === '\\') {
        if (next !== '\n') {
          word.literal += next === undefined ? '' : next;
          word.plain = false;
        }
        this.i += 2;
        continue;
      }
      if (c === "'") {
        const close = src.indexOf("'", this.i + 1);
        if (close < 0) this.fail('unterminated single quote', this.i);
        word.literal += src.slice(this.i + 1, close);
        word.plain = false;
        this.i = close + 1;
        continue;
      }
      if (c === '"') {
        this.i++;
        this.readDoubleQuoted(word);
        continue;
      }
      if (c === '$') {
        this.readDollar(word, false);
        continue;
      }
      if (c === '`') {
        this.readBackquote(word);
        continue;
      }
      if (mode === 'normal' && (c === '<' || c === '>') && next === '(' && this.i > word.start) break;
      if (mode === 'normal' && (c === '<' || c === '>') && next === '(') {
        this.i += 2;
        word.substs.push(this.readList(')'));
        word.plain = false;
        continue;
      }
      if ('@!+*?'.includes(c) && next === '(') {
        this.skipParenthesized(this.i + 1);
        word.plain = false;
        continue;
      }
      if (c === '(' && mode === 'normal' && word.plain && ARRAY_OPEN.test(word.literal)) {
        this.i++;
        this.readArrayElements(word);
        continue;
      }
      if (mode === 'test' ? BLANK.test(c) : WORD_END.test(c)) break;
      word.literal += c;
      this.i++;
    }
    word.text = src.slice(word.start, this.i);
    return word;
  }

  readArrayElements(word) {
    const src = this.src;
    const open = this.i - 1;
    for (;;) {
      if (this.i >= src.length) this.fail('unterminated array', open);
      const c = src[this.i];
      if (c === ')') {
        this.i++;
        word.plain = false;
        return;
      }
      if (BLANK.test(c)) {
        this.i++;
        continue;
      }
      if (c === '\\' && src[this.i + 1] === '\n') {
        this.i += 2;
        continue;
      }
      if (c === '#') {
        this.skipComment();
        continue;
      }
      const element = this.readWord('normal');
      if (element.text === '') this.fail('unexpected character in an array', this.i);
      for (const ref of element.refs) word.refs.add(ref);
      word.substs.push(...element.substs);
    }
  }

  readDoubleQuoted(word) {
    const src = this.src;
    const open = this.i - 1;
    word.plain = false;
    for (;;) {
      if (this.i >= src.length) this.fail('unterminated double quote', open);
      const c = src[this.i];
      if (c === '"') {
        this.i++;
        return;
      }
      if (c === '\\') {
        const next = src[this.i + 1];
        if (next === '\n') this.i += 2;
        else if (next === '$' || next === '`' || next === '"' || next === '\\') {
          word.literal += next;
          this.i += 2;
        } else {
          word.literal += c;
          this.i++;
        }
        continue;
      }
      if (c === '$') {
        this.readDollar(word, true);
        continue;
      }
      if (c === '`') {
        this.readBackquote(word);
        continue;
      }
      word.literal += c;
      this.i++;
    }
  }

  readDollar(word, quoted) {
    const src = this.src;
    const next = src[this.i + 1];
    if (next === '(') {
      word.plain = false;
      if (src[this.i + 2] === '(') {
        this.skipParenthesized(this.i + 1);
        return;
      }
      this.i += 2;
      word.substs.push(this.readList(')'));
      return;
    }
    if (next === '{') {
      word.plain = false;
      this.i += 2;
      this.readBraced(word, quoted);
      return;
    }
    if (!quoted && next === "'") {
      word.plain = false;
      this.skipAnsiQuote();
      return;
    }
    if (!quoted && next === '"') {
      this.i++;
      return;
    }
    const name = /^(?:[A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-])/.exec(src.slice(this.i + 1, this.i + 129));
    if (name) {
      word.plain = false;
      this.addRef(word, name[0]);
      this.i += 1 + name[0].length;
      return;
    }
    word.literal += '$';
    this.i++;
  }

  skipAnsiQuote() {
    const src = this.src;
    const open = this.i;
    this.i += 2;
    for (;;) {
      if (this.i >= src.length) this.fail('unterminated $\'', open);
      if (src[this.i] === '\\') this.i += 2;
      else if (src[this.i] === "'") {
        this.i++;
        return;
      } else this.i++;
    }
  }

  readBraced(word, quoted) {
    const src = this.src;
    const open = this.i - 2;
    let counted = true;
    if ((src[this.i] === '#' || src[this.i] === '!') && src[this.i + 1] !== '}') {
      counted = false;
      this.i++;
    }
    const name = /^(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*#?$!-])/.exec(src.slice(this.i, this.i + 128));
    if (name) {
      if (counted) this.addRef(word, name[0]);
      this.i += name[0].length;
    }
    for (;;) {
      if (this.i >= src.length) this.fail('unterminated ${', open);
      const c = src[this.i];
      if (c === '}') {
        this.i++;
        return;
      }
      if (c === '\\') this.i += 2;
      else if (c === "'" && !quoted) {
        const close = src.indexOf("'", this.i + 1);
        if (close < 0) this.fail('unterminated single quote', this.i);
        this.i = close + 1;
      } else if (c === '"') {
        this.i++;
        this.readDoubleQuoted(word);
      } else if (c === '$') this.readDollar(word, quoted);
      else if (c === '`') this.readBackquote(word);
      else this.i++;
    }
  }

  addRef(word, name) {
    if (NAME.test(name) || /^[1-9][0-9]*$/.test(name)) word.refs.add(name);
    else if (name === '@' || name === '*') word.refs.add('@');
  }

  readBackquote(word) {
    const src = this.src;
    const open = this.i;
    let body = '';
    this.i++;
    for (;;) {
      if (this.i >= src.length) this.fail('unterminated backquote', open);
      const c = src[this.i];
      if (c === '`') {
        this.i++;
        break;
      }
      if (c === '\\' && '`\\$'.includes(src[this.i + 1])) {
        body += src[this.i + 1];
        this.i += 2;
        continue;
      }
      body += c;
      this.i++;
    }
    word.plain = false;
    const nested = new ShellLexer(body, this.file, this.sink, this.lineOf(open) - 1, this.currentFunction());
    word.substs.push(nested.run());
  }
}

function literalOf(word) {
  return word && word.plain ? word.literal : null;
}

function declaredAssignments(segment) {
  let words = [];
  if (!segment.cmd) words = segment.assigns;
  else if (DECLARERS.has(literalOf(segment.cmd))) words = segment.args.filter((word) => ASSIGNMENT.test(word.text));
  return words.map((word) => ({ name: ASSIGNMENT.exec(word.text)[1], word }));
}

function readsHookStdin(segment) {
  const name = literalOf(segment.cmd);
  if (!STDIN_READERS.has(name)) return false;
  if (segment.redirs.some((redirect) => INPUT_REDIRECTS.has(redirect.op))) return false;
  const args = segment.args.map(literalOf);
  if (args.includes(null)) return false;
  if (name === 'dd') return !args.some((arg) => arg.startsWith('if=') && arg !== 'if=/dev/stdin');
  let value = false;
  for (const arg of args) {
    if (value) value = false;
    else if (name === 'head' && (arg === '-c' || arg === '-n')) value = true;
    else if (arg !== '-' && arg !== '/dev/stdin' && !arg.startsWith('-')) return false;
  }
  return true;
}

function slurpedNames(segment) {
  if (literalOf(segment.cmd) !== 'read' || segment.loopHead) return [];
  if (segment.redirs.some((redirect) => INPUT_REDIRECTS.has(redirect.op))) return [];
  const names = [];
  let slurp = false;
  const args = segment.args;
  for (let k = 0; k < args.length; k++) {
    const word = args[k];
    if (/^-[A-Za-z]/.test(word.text)) {
      const flags = word.literal.slice(1);
      for (let f = 0; f < flags.length; f++) {
        if (!'adinNptu'.includes(flags[f])) continue;
        const inline = word.text.slice(f + 2) !== '';
        let value = null;
        if (inline) value = flags.slice(f + 1);
        else if (k + 1 < args.length) value = args[++k].literal;
        if (flags[f] === 'd' && value === '') slurp = true;
        if (flags[f] === 'u' && value !== '0') return [];
        if (flags[f] === 'a' && value && NAME.test(value)) names.push(value);
        break;
      }
      continue;
    }
    if (word.plain && NAME.test(word.literal)) names.push(word.literal);
  }
  return slurp ? names : [];
}

function analyze(files) {
  const sink = { segments: [], definitions: new Map(), listCount: 0 };
  const errors = [];
  for (const file of files) {
    try {
      new ShellLexer(file.source, file.rel, sink, 0, null).run();
    } catch (error) {
      if (!(error instanceof ParseError)) throw error;
      errors.push({ file: file.rel, line: error.line, message: error.message });
    }
  }
  const byList = new Map();
  for (const segment of sink.segments) {
    if (!byList.has(segment.list)) byList.set(segment.list, []);
    byList.get(segment.list).push(segment);
  }
  const resolve = (file, name) => {
    const owners = sink.definitions.get(name);
    if (!owners) return [];
    if (owners.has(file)) return [file + '::' + name];
    return [...owners].filter((owner) => owner.startsWith('hooks/lib/')).map((owner) => owner + '::' + name);
  };
  const scopeKey = (segment) => (segment.fn ? segment.file + '::' + segment.fn : segment.file);
  const scoped = new Map();
  const scopeVars = (key) => {
    if (!scoped.has(key)) scoped.set(key, new Set());
    return scoped.get(key);
  };
  const params = new Map();
  const paramsOf = (key) => {
    if (!params.has(key)) params.set(key, new Set());
    return params.get(key);
  };
  const sources = [];
  const shifted = new Set();
  for (const segment of sink.segments) {
    const command = literalOf(segment.cmd);
    if (command === 'shift' || (command === 'set' && literalOf(segment.args[0]) === '--')) shifted.add(scopeKey(segment));
    for (const { name, word } of declaredAssignments(segment)) {
      if (word.substs.some((id) => (byList.get(id) || []).some(readsHookStdin))) {
        scopeVars(scopeKey(segment)).add(name);
        sources.push({ file: segment.file, line: word.line, name });
      }
    }
    for (const name of slurpedNames(segment)) {
      scopeVars(scopeKey(segment)).add(name);
      sources.push({ file: segment.file, line: segment.line, name });
    }
  }
  const varsFor = (segment) => {
    const vars = new Set(['INPUT']);
    for (const name of scoped.get(segment.file) || []) vars.add(name);
    if (segment.fn) {
      const key = segment.file + '::' + segment.fn;
      for (const name of scoped.get(key) || []) vars.add(name);
      const positions = params.get(key);
      if (positions && positions.size) {
        for (const position of positions) vars.add(position);
        vars.add('@');
        if (shifted.has(key)) vars.add('#');
      }
    }
    return vars;
  };
  const carried = (word, vars) => [...word.refs].find((ref) => vars.has(ref) || (vars.has('#') && /^[1-9]/.test(ref)));
  let changed = true;
  while (changed) {
    changed = false;
    for (const segment of sink.segments) {
      const vars = varsFor(segment);
      for (const { name, word } of declaredAssignments(segment)) {
        const target = scopeVars(scopeKey(segment));
        if (carried(word, vars) && !target.has(name)) {
          target.add(name);
          changed = true;
        }
      }
      const name = literalOf(segment.cmd);
      if (name === null) continue;
      const callees = resolve(segment.file, name);
      if (!callees.length) continue;
      const own = segment.fn ? params.get(segment.file + '::' + segment.fn) : null;
      segment.args.forEach((word, index) => {
        const positions = [];
        if (carried(word, vars)) positions.push(String(index + 1));
        if (word.refs.has('@') && own) for (const position of own) positions.push(String(index + Number(position)));
        for (const callee of callees) {
          const target = paramsOf(callee);
          for (const position of positions) {
            if (!target.has(position)) {
              target.add(position);
              changed = true;
            }
          }
        }
      });
    }
  }
  const findings = [];
  const report = (segment, word, channel, variable) => {
    findings.push({ file: segment.file, line: word.line, channel, variable, text: segment.text });
  };
  for (const segment of sink.segments) {
    if (!segment.cmd) continue;
    const vars = varsFor(segment);
    for (const word of segment.assigns) {
      const hit = carried(word, vars);
      if (hit) report(segment, word, 'environment', hit);
    }
    let name = literalOf(segment.cmd);
    let args = segment.args;
    while (WRAPPERS.has(name)) {
      let k = 0;
      while (k < args.length && /^-/.test(args[k].text)) k++;
      name = k < args.length ? literalOf(args[k]) : null;
      args = args.slice(k + 1);
    }
    const exporting = name === 'export'
      || (DECLARERS.has(name) && args.some((word) => word.plain && /^-[A-Za-z]*x/.test(word.literal)));
    if (exporting) {
      for (const word of args) {
        const hit = ASSIGNMENT.test(word.text) ? carried(word, vars) : (word.plain && vars.has(word.literal) ? word.literal : null);
        if (hit) report(segment, word, 'export', hit);
      }
      continue;
    }
    if (name !== null && (SAFE_BUILTINS.has(name) || resolve(segment.file, name).length)) continue;
    for (const word of args) {
      const hit = carried(word, vars);
      if (hit) report(segment, word, 'argument', hit);
    }
  }
  const functions = [...params.values()].filter((positions) => positions.size).length;
  const hooks = new Set(sources.map((source) => source.file).filter((file) => !file.startsWith('hooks/lib/'))).size;
  return { findings, errors, sources, hooks, functions };
}

function hookFiles(root) {
  const files = [];
  for (const dir of ['hooks', 'hooks/lib']) {
    let entries = [];
    try {
      entries = fs.readdirSync(path.join(root, dir), { withFileTypes: true });
    } catch (_) {
      continue;
    }
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith('.sh')) continue;
      const rel = dir + '/' + entry.name;
      files.push({ rel, source: fs.readFileSync(path.join(root, dir, entry.name), 'utf8') });
    }
  }
  return files.sort((a, b) => (a.rel < b.rel ? -1 : a.rel > b.rel ? 1 : 0));
}

function main() {
  const root = process.argv[2];
  if (!root || process.argv.length !== 3 || !fs.existsSync(path.join(root, 'hooks'))) {
    process.stderr.write('usage: hook-payload-stdin-scan.js <plugin-root>\n');
    process.exit(2);
  }
  const files = hookFiles(root);
  const { findings, errors, sources, hooks, functions } = analyze(files);
  const lines = [];
  for (const error of errors) lines.push(error.file + ':' + error.line + '\tunparsed\t-\t' + error.message);
  findings.sort((a, b) => (a.file === b.file ? a.line - b.line : a.file < b.file ? -1 : 1));
  for (const finding of findings) {
    const excerpt = finding.text.length > 160 ? finding.text.slice(0, 157) + '...' : finding.text;
    lines.push(finding.file + ':' + finding.line + '\t' + finding.channel + '\t$' + finding.variable + '\t' + excerpt);
  }
  if (lines.length) process.stdout.write(lines.join('\n') + '\n');
  process.stderr.write(
    'scanned ' + files.length + ' shell file(s); payload sources ' + sources.length + ' in ' + hooks
    + ' hook script(s); payload functions ' + functions + '; findings ' + lines.length + '\n'
  );
  process.exit(lines.length ? 1 : 0);
}

main();
