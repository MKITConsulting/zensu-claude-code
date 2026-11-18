'use strict';

const fs = require('fs');
const path = require('path');

const FILE_FLAG = /--([a-z][a-z0-9-]*?)-file[ =]"\$([A-Za-z_][A-Za-z0-9_]*)"/g;
const INLINE = /--([a-z][a-z0-9-]*)[ =]"\$\(cat "\$([A-Za-z_][A-Za-z0-9_]*)"\)"/g;
const CAT = /"\$\(cat "\$([A-Za-z_][A-Za-z0-9_]*)"\)"/g;
const COMMAND = /\bzensu ([a-z][a-z-]*) ([a-z][a-z-]*)/g;
const ZENSU_CALL = /(?:^\s*|[;&|(]\s*)(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*)\s+)*zensu(?=\s|$)/;
const FENCE = /^\s*(`{3,}|~{3,})/;
const FRONT = /^---\n[\s\S]*?\n---(?:\n|$)/;

function markdownFiles(dir) {
  const found = [];
  const walk = (current) => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile() && entry.name.endsWith('.md')) found.push(full);
    }
  };
  walk(dir);
  return found;
}

function lineTable(body) {
  const lines = [];
  let offset = 0;
  let fence = null;
  let logicalStart = -1;
  for (const text of body.split('\n')) {
    const marker = text.match(FENCE);
    let fenced = false;
    if (fence) {
      if (marker && marker[1][0] === fence[0] && marker[1].length >= fence.length && /^\s*[`~]+\s*$/.test(text)) fence = null;
      else fenced = true;
    } else if (marker) {
      fence = marker[1];
    }
    const entry = { offset, end: offset + text.length, fenced, logicalStart: offset };
    if (fenced && logicalStart >= 0) entry.logicalStart = logicalStart;
    logicalStart = fenced && /\\\s*$/.test(text) ? entry.logicalStart : -1;
    lines.push(entry);
    offset += text.length + 1;
  }
  return lines;
}

function lineAt(lines, index) {
  let low = 0;
  let high = lines.length - 1;
  while (low < high) {
    const mid = (low + high + 1) >> 1;
    if (lines[mid].offset <= index) low = mid;
    else high = mid - 1;
  }
  return low;
}

function commandBefore(body, from, to) {
  let found = null;
  COMMAND.lastIndex = from;
  for (let m = COMMAND.exec(body); m && m.index < to; m = COMMAND.exec(body)) found = `${m[1]} ${m[2]}`;
  return found;
}

function spanProgram(body, lineStart, index) {
  const before = body.slice(lineStart, index);
  const tick = before.lastIndexOf('`');
  if (tick < 0 || before.split('`').length % 2 === 1) return { known: false };
  const span = before.slice(tick + 1).replace(/^(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*)\s+)*/, '');
  const command = span.match(/\bzensu ([a-z][a-z-]*) ([a-z][a-z-]*)/);
  if (command) return { known: true, command: `${command[1]} ${command[2]}` };
  const word = span.match(/^([A-Za-z_][A-Za-z0-9_.\/-]*)(?:\s|$)/);
  if (word && word[1] === 'zensu') return { known: true, command: null, unread: true };
  if (word) return { known: true, command: null };
  return { known: false };
}

function fileSites(root, file) {
  const raw = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
  const front = raw.match(FRONT);
  const body = front ? raw.slice(front[0].length) : raw;
  const skipped = front ? front[0].split('\n').length - 1 : 0;
  const lines = lineTable(body);
  const rel = path.relative(root, file).split(path.sep).join('/');
  const sites = [];
  const covered = new Set();
  const place = (index) => {
    const at = lineAt(lines, index);
    const line = lines[at];
    if (!line.fenced) {
      const span = spanProgram(body, line.offset, index);
      if (span.unread) return { line: skipped + at + 1, command: null, foreign: false, unread: true };
      if (span.known) return { line: skipped + at + 1, command: span.command, foreign: span.command === null };
      return { line: skipped + at + 1, command: commandBefore(body, 0, index), foreign: false };
    }
    const command = commandBefore(body, line.logicalStart, index);
    if (command === null && ZENSU_CALL.test(body.slice(line.logicalStart, index))) {
      return { line: skipped + at + 1, command: null, foreign: false, unread: true };
    }
    return { line: skipped + at + 1, command, foreign: command === null };
  };
  for (const [pattern, form] of [[FILE_FLAG, 'file'], [INLINE, 'inline']]) {
    pattern.lastIndex = 0;
    for (const m of body.matchAll(pattern)) {
      if (form === 'inline') covered.add(m.index + m[0].indexOf('"$(cat'));
      sites.push(Object.assign({ file: rel, flag: m[1], variable: m[2], form }, place(m.index)));
    }
  }
  for (const m of body.matchAll(CAT)) {
    if (covered.has(m.index)) continue;
    sites.push(Object.assign({ file: rel, flag: '', variable: m[1], form: 'unattached' }, place(m.index)));
  }
  return sites.sort((a, b) => a.line - b.line);
}

function sites(root) {
  return markdownFiles(path.join(root, 'skills')).flatMap((file) => fileSites(root, file));
}

function commands(root) {
  return [...new Set(sites(root).filter((s) => !s.foreign && s.command).map((s) => s.command))].sort();
}

function helpFlags(text) {
  const flags = new Set();
  for (const line of String(text).split('\n')) {
    const m = line.match(/^\s+(?:-[A-Za-z], )?--([a-z][a-z0-9-]*)/);
    if (m) flags.add(m[1]);
  }
  return flags;
}

function recordedVersion(fixture) {
  const m = String(fixture.version || '').match(/^zensu v?(\S+)/);
  return m ? m[1] : '';
}

function judge(root, fixture, floor) {
  const bad = [];
  if (floor !== undefined && recordedVersion(fixture) !== floor) {
    bad.push(`the floor fixture records ${recordedVersion(fixture) || 'no version'}, the floor is ${floor}`);
  }
  const recorded = fixture.commands && typeof fixture.commands === 'object' ? fixture.commands : {};
  const list = sites(root);
  for (const s of list) {
    const at = `${s.file}:${s.line}`;
    if (s.foreign) continue;
    if (s.form === 'unattached') {
      bad.push(`${at} passes "$(cat "$${s.variable}")" without the flag it fills`);
      continue;
    }
    if (!s.command) {
      bad.push(s.unread
        ? `${at} --${s.flag} follows a zensu call whose noun and verb the scanner cannot read`
        : `${at} --${s.flag} follows no zensu command`);
      continue;
    }
    if (!Object.prototype.hasOwnProperty.call(recorded, s.command)) {
      bad.push(`${at} zensu ${s.command} is not recorded in the floor fixture`);
      continue;
    }
    const flags = helpFlags(recorded[s.command]);
    if (s.form === 'file') {
      if (!flags.has(`${s.flag}-file`)) bad.push(`${at} zensu ${s.command} has no --${s.flag}-file in the floor release`);
    } else if (s.flag.endsWith('-file')) {
      bad.push(`${at} --${s.flag} takes the file's path, never its text`);
    } else if (!flags.has(s.flag)) {
      bad.push(`${at} zensu ${s.command} has no --${s.flag} in the floor release`);
    } else if (flags.has(`${s.flag}-file`)) {
      bad.push(`${at} zensu ${s.command} reads --${s.flag}-file in the floor release, so pass the file instead of "$(cat "$${s.variable}")"`);
    }
  }
  return { bad, sites: list };
}

function main(argv) {
  const [verb, root, fixturePath, floor] = argv;
  if (verb === 'sites' && root) {
    for (const s of sites(root)) console.log(`${s.file}:${s.line}\t${s.form}\t${s.flag}\t${s.command || '-'}\t${s.foreign ? 'foreign' : 'zensu'}`);
    return 0;
  }
  if (verb === 'commands' && root) {
    for (const command of commands(root)) console.log(command);
    return 0;
  }
  if (verb === 'judge' && root && fixturePath) {
    const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
    const result = judge(root, fixture, floor);
    for (const line of result.bad) console.log(`BAD ${line}`);
    console.log(`SITES ${result.sites.filter((s) => !s.foreign).length}`);
    return 0;
  }
  console.error('usage: lib-skill-free-text.js sites <root> | commands <root> | judge <root> <fixture> [<floor>]');
  return 2;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));

module.exports = { sites, commands, helpFlags, judge, recordedVersion };
