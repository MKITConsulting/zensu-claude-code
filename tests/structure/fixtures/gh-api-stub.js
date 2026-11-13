'use strict';

const fs = require('fs');
const path = require('path');

const REQUEST = [
  'function ghRequest(args) {',
  '  let endpoint = null;',
  '  let host = null;',
  '  for (let index = 0; index < args.length; index += 1) {',
  '    const arg = String(args[index]);',
  "    if (arg === '--hostname') { host = args[index + 1] || ''; index += 1; }",
  "    else if (arg.startsWith('--hostname=')) host = arg.slice('--hostname='.length);",
  "    else if (endpoint === null && !arg.startsWith('-')) endpoint = arg;",
  '  }',
  "  return { endpoint, host: host === null ? (process.env.GH_HOST || 'github.com') : host };",
  '}',
];

function posixScript(fixture, calls) {
  return [
    `#!${process.execPath}`,
    "const fs = require('fs');",
    ...REQUEST,
    `const map = JSON.parse(fs.readFileSync(${JSON.stringify(fixture)}, 'utf8'));`,
    "if (map.__probe) fs.appendFileSync(map.__probe.out, (fs.existsSync(map.__probe.path) ? 'present' : 'absent') + '\\n');",
    'const request = ghRequest(process.argv.slice(3));',
    'const endpoint = request.endpoint;',
    `fs.appendFileSync(${JSON.stringify(calls)}, endpoint + '\\n');`,
    'if (map.__delayMs) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, map.__delayMs);',
    "if (request.host !== 'github.com') { process.stderr.write('error connecting to ' + request.host + '\\n'); process.exit(1); }",
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
    ...REQUEST.map((line) => `  ${line}`),
    `  const map = JSON.parse(fs.readFileSync(${JSON.stringify(fixture)}, 'utf8'));`,
    "  if (map.__probe) fs.appendFileSync(map.__probe.out, (fs.existsSync(map.__probe.path) ? 'present' : 'absent') + '\\n');",
    '  const request = ghRequest(process.argv.slice(2));',
    '  const endpoint = request.endpoint;',
    `  fs.appendFileSync(${JSON.stringify(calls)}, endpoint + '\\n');`,
    '  if (map.__delayMs) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, map.__delayMs);',
    "  if (request.host !== 'github.com') { fs.writeSync(2, 'error connecting to ' + request.host + '\\n'); process.exit(1); }",
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

module.exports = { writeGhStub, posixScript, windowsPreload };
