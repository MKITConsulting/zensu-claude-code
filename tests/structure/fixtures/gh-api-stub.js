'use strict';

const fs = require('fs');
const path = require('path');

function posixScript(fixture, calls) {
  return [
    `#!${process.execPath}`,
    "const fs = require('fs');",
    `const map = JSON.parse(fs.readFileSync(${JSON.stringify(fixture)}, 'utf8'));`,
    'const endpoint = process.argv[3];',
    `fs.appendFileSync(${JSON.stringify(calls)}, endpoint + '\\n');`,
    "if (!Object.prototype.hasOwnProperty.call(map, endpoint)) { process.stderr.write('HTTP 404: Not Found\\n'); process.exit(1); }",
    'const value = map[endpoint];',
    "if (value && value.__fail) { process.stderr.write(value.__fail + '\\n'); process.exit(1); }",
    'process.stdout.write(JSON.stringify(value));',
    '',
  ].join('\n');
}

function windowsPreload(fixture, calls) {
  return [
    "if (require('path').basename(process.execPath).toLowerCase() === 'gh.exe') {",
    "  const fs = require('fs');",
    `  const map = JSON.parse(fs.readFileSync(${JSON.stringify(fixture)}, 'utf8'));`,
    '  const endpoint = process.argv[process.argv.length - 1];',
    `  fs.appendFileSync(${JSON.stringify(calls)}, endpoint + '\\n');`,
    "  if (!Object.prototype.hasOwnProperty.call(map, endpoint)) { fs.writeSync(2, 'HTTP 404: Not Found\\n'); process.exit(1); }",
    '  const value = map[endpoint];',
    "  if (value && value.__fail) { fs.writeSync(2, value.__fail + '\\n'); process.exit(1); }",
    '  fs.writeSync(1, JSON.stringify(value));',
    '  process.exit(0);',
    '}',
    '',
  ].join('\n');
}

let copiedExecutable = null;

function stubExecutable(directory) {
  const exe = path.join(directory, 'gh.exe');
  if (copiedExecutable && fs.existsSync(copiedExecutable)) {
    try {
      fs.linkSync(copiedExecutable, exe);
      return exe;
    } catch {
      copiedExecutable = null;
    }
  }
  fs.copyFileSync(process.execPath, exe);
  copiedExecutable = exe;
  return exe;
}

function writeGhStub(directory, fixture, calls) {
  if (process.platform !== 'win32') {
    const script = path.join(directory, 'gh');
    fs.writeFileSync(script, posixScript(fixture, calls), { mode: 0o755 });
    return { ghPath: script, env: {} };
  }
  const exe = stubExecutable(directory);
  const preload = path.join(directory, 'gh-stub-preload.js');
  fs.writeFileSync(preload, windowsPreload(fixture, calls));
  return { ghPath: exe, env: { NODE_OPTIONS: `--require=${preload.split(path.sep).join('/')}` } };
}

module.exports = { writeGhStub };
