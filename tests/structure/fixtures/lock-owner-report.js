'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const ARTIFACT = /\.(lock|recovery|candidate|quarantine)$/;

function liveness(pid) {
  try {
    process.kill(pid, 0);
    return 'alive';
  } catch (error) {
    return error.code === 'EPERM' ? 'alive' : `dead (${error.code})`;
  }
}

function run(command, args, timeout, env = { ...process.env, LC_ALL: 'C', LANG: 'C' }) {
  return execFileSync(command, args, {
    encoding: 'utf8',
    env,
    stdio: ['ignore', 'pipe', 'ignore'],
    timeout,
    windowsHide: true,
  }).replace(/\s+/g, ' ').trim();
}

function describeWindows(pid) {
  const configuredRoot = process.env.SystemRoot;
  const root = configuredRoot && path.win32.isAbsolute(configuredRoot) ? configuredRoot : 'C:\\Windows';
  const powershellDirectory = path.win32.join(root, 'System32', 'WindowsPowerShell', 'v1.0');
  const program = [
    "$PSModuleAutoLoadingPreference='None'",
    'Import-Module CimCmdlets -ErrorAction Stop',
    `$p = Get-CimInstance Win32_Process -Filter 'ProcessId=${pid}'`,
    "if ($p) { '{0}|{1}|{2}|{3}' -f $p.CreationDate.ToUniversalTime().ToString('o'), $p.Name, $p.ParentProcessId, $p.CommandLine }",
  ].join('\n');
  const row = run(
    path.win32.join(powershellDirectory, 'powershell.exe'),
    ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(program, 'utf16le').toString('base64')],
    30000,
    {
      SystemRoot: root,
      windir: root,
      SystemDrive: path.win32.parse(root).root.replace(/\\+$/, ''),
      ComSpec: path.win32.join(root, 'System32', 'cmd.exe'),
      PATH: [
        path.win32.join(root, 'System32'),
        root,
        path.win32.join(root, 'System32', 'Wbem'),
        powershellDirectory,
      ].join(';'),
      PSModulePath: path.win32.join(powershellDirectory, 'Modules'),
      PATHEXT: '.COM;.EXE;.BAT;.CMD',
      TEMP: process.env.TEMP || path.win32.join(root, 'Temp'),
      TMP: process.env.TMP || path.win32.join(root, 'Temp'),
      LOCALAPPDATA: process.env.LOCALAPPDATA || '',
      APPDATA: process.env.APPDATA || '',
      USERPROFILE: process.env.USERPROFILE || '',
      HOMEDRIVE: process.env.HOMEDRIVE || '',
      HOMEPATH: process.env.HOMEPATH || '',
    },
  );
  if (!row) return { text: 'no such process', startedMs: NaN, resolutionMs: 0 };
  const [started, name, parent, ...command] = row.split('|');
  return {
    text: `${name} ppid ${parent} started ${started} command ${command.join('|')}`,
    startedMs: Date.parse(started),
    resolutionMs: 50,
  };
}

function describePosix(pid) {
  const started = run('ps', ['-p', String(pid), '-o', 'lstart='], 5000);
  const rest = run('ps', ['-p', String(pid), '-o', 'ppid=,args='], 5000);
  if (!started && !rest) return { text: 'no such process', startedMs: NaN, resolutionMs: 0 };
  return { text: `ppid/args ${rest} started ${started}`, startedMs: Date.parse(started), resolutionMs: 1000 };
}

function describe(pid) {
  try {
    return process.platform === 'win32' ? describeWindows(pid) : describePosix(pid);
  } catch (error) {
    return { text: `unavailable (${error.code || error.message})`, startedMs: NaN, resolutionMs: 0 };
  }
}

function ownerLines(name, owner, ageSeconds) {
  const lines = [
    `${name}: age ${ageSeconds}s, kind ${owner.kind || 'unknown'}, created_at ${owner.created_at || 'unknown'}, `
      + `owner pid ${owner.pid}, start identity ${owner.process_start_identity || 'none'}`,
  ];
  const state = liveness(owner.pid);
  lines.push(`  owner pid ${owner.pid} is ${state}`);
  if (state !== 'alive') return lines;
  const holder = describe(owner.pid);
  lines.push(`  owner process: ${holder.text.slice(0, 600)}`);
  const recorded = Date.parse(owner.created_at || '');
  if (Number.isFinite(holder.startedMs) && Number.isFinite(recorded)) {
    if (holder.startedMs > recorded + holder.resolutionMs) {
      lines.push('  verdict: the live process started after the record was written, so the recorded owner is gone and its PID was reused');
    } else if (holder.startedMs <= recorded) {
      lines.push('  verdict: the live process predates the record and may be the real owner');
    } else {
      lines.push('  verdict: the start time is too coarse to tell the recorded owner from a reused PID');
    }
  }
  return lines;
}

function report(directory) {
  let names;
  try {
    names = fs.readdirSync(directory).filter((name) => ARTIFACT.test(name)).sort();
  } catch (error) {
    return [`lock directory unreadable: ${directory} (${error.code || error.message})`];
  }
  if (names.length === 0) return [`no lock artifacts in ${directory}`];
  const lines = [];
  for (const name of names) {
    const file = path.join(directory, name);
    let stat;
    let text;
    try {
      stat = fs.lstatSync(file);
      text = fs.readFileSync(file, 'utf8').slice(0, 2048);
    } catch (error) {
      if (error.code !== 'ENOENT') lines.push(`${name}: unreadable (${error.code || error.message})`);
      continue;
    }
    const ageSeconds = Math.round((Date.now() - stat.mtimeMs) / 1000);
    let owner = null;
    try {
      owner = JSON.parse(text);
    } catch (_error) {
      owner = null;
    }
    if (!owner || !Number.isSafeInteger(owner.pid) || owner.pid <= 0) {
      lines.push(`${name}: age ${ageSeconds}s, no parseable owner: ${JSON.stringify(text.slice(0, 200))}`);
      continue;
    }
    lines.push(...ownerLines(name, owner, ageSeconds));
  }
  return lines;
}

const directory = process.argv[2];
if (!directory) {
  process.stderr.write('usage: lock-owner-report.js <lock directory>\n');
  process.exit(2);
}
process.stdout.write(`${report(path.resolve(directory)).join('\n')}\n`);
