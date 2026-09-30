'use strict';

const childProcess = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { performance } = require('node:perf_hooks');

const WIN = process.platform === 'win32';
const OUT_DIR = path.resolve(process.argv[2] || path.join(os.tmpdir(), 'win32-identity-probe'));
const LABEL = process.env.PROBE_LABEL || `${process.platform}-local`;
const ROUNDS = Number(process.env.PROBE_ROUNDS || 20);
const REUSE_SPAWNS = Number(process.env.PROBE_REUSE_SPAWNS || 1500);
const REUSE_BUDGET_MS = Number(process.env.PROBE_REUSE_BUDGET_MS || 60000);
const PARALLEL_BUDGET_MS = Number(process.env.PROBE_PARALLEL_BUDGET_MS || 30000);
fs.mkdirSync(OUT_DIR, { recursive: true });

const systemRoot = process.env.SystemRoot || process.env.SYSTEMROOT || 'C:\\Windows';
const system32 = path.join(systemRoot, 'System32');
const powershell = path.join(system32, 'WindowsPowerShell', 'v1.0', 'powershell.exe');
const cscript = path.join(system32, 'cscript.exe');
const wmic = path.join(system32, 'wbem', 'WMIC.exe');
const cmd = path.join(system32, 'cmd.exe');
const MIN_ENV = {
  SystemRoot: systemRoot,
  windir: systemRoot,
  PATH: [system32, path.join(system32, 'Wbem'), path.dirname(powershell)].join(';'),
};

function exists(file) {
  try {
    return fs.statSync(file).isFile();
  } catch {
    return false;
  }
}

function which(name) {
  for (const dir of String(process.env.PATH || '').split(path.delimiter)) {
    if (!dir) continue;
    const candidate = path.join(dir, name);
    if (exists(candidate)) return candidate;
  }
  return null;
}

function stats(values) {
  const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
  if (sorted.length === 0) return null;
  const at = (q) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))];
  const mean = sorted.reduce((sum, value) => sum + value, 0) / sorted.length;
  const round = (value) => Math.round(value * 10) / 10;
  return {
    n: sorted.length,
    min: round(sorted[0]),
    p50: round(at(0.5)),
    p90: round(at(0.9)),
    max: round(sorted[sorted.length - 1]),
    mean: round(mean),
  };
}

function timed(fn) {
  const started = performance.now();
  try {
    const result = fn();
    return { ms: performance.now() - started, result, error: null };
  } catch (error) {
    return {
      ms: performance.now() - started,
      result: null,
      error: String((error && (error.code || error.message)) || error).slice(0, 300),
      stderr: error && error.stderr ? String(error.stderr).slice(0, 300) : '',
      status: error && error.status !== undefined ? error.status : null,
    };
  }
}

function run(file, args, options = {}) {
  return childProcess.execFileSync(file, args, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: options.timeout || 30000,
    windowsHide: true,
    env: options.env || process.env,
  });
}

function parseFiletime(text) {
  const trimmed = String(text || '').trim();
  if (!/^[0-9]{1,20}$/.test(trimmed)) return null;
  return Number(BigInt(trimmed) / 10000n - 11644473600000n);
}

function parseWmiDate(text) {
  const match = /([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})\.([0-9]{6})([+-])([0-9]{3})/.exec(String(text || ''));
  if (!match) return null;
  const [, y, mo, d, h, mi, s, micro, sign, offset] = match;
  const local = Date.UTC(Number(y), Number(mo) - 1, Number(d), Number(h), Number(mi), Number(s)) + Math.floor(Number(micro) / 1000);
  const offsetMs = Number(offset) * 60000 * (sign === '-' ? -1 : 1);
  return local - offsetMs;
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
function parseLstart(text) {
  const match = /^[A-Z][a-z]{2} ([A-Z][a-z]{2}) +([0-9]{1,2}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) ([0-9]{4})$/.exec(String(text || '').trim().replace(/\s+/g, ' '));
  if (!match) return null;
  const month = MONTHS.indexOf(match[1]);
  if (month < 0) return null;
  return Date.UTC(Number(match[6]), month, Number(match[2]), Number(match[3]), Number(match[4]), Number(match[5]));
}

const wmiScript = path.join(OUT_DIR, 'creation-date.js');
fs.writeFileSync(wmiScript, [
  'var pid = WScript.Arguments.Item(0);',
  'var service = GetObject("winmgmts:{impersonationLevel=impersonate}!\\\\\\\\.\\\\root\\\\cimv2");',
  'var items = new Enumerator(service.ExecQuery("SELECT CreationDate FROM Win32_Process WHERE ProcessId = " + pid));',
  'for (; !items.atEnd(); items.moveNext()) { WScript.StdOut.Write(items.item().CreationDate); }',
  '',
].join('\r\n'));

const psArgs = (script) => ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script];
const pwsh = WIN ? which('pwsh.exe') : null;
const msysPs = WIN ? ['C:\\Program Files\\Git\\usr\\bin\\ps.exe'].find(exists) || null : null;
const dotnetScript = (pid) => `[System.Diagnostics.Process]::GetProcessById(${pid}).StartTime.ToFileTimeUtc()`;
const cmdletScript = (pid) => `(Get-Process -Id ${pid} -ErrorAction Stop).StartTime.ToFileTimeUtc()`;

const candidates = [
  {
    id: 'ps51-dotnet',
    available: WIN && exists(powershell),
    run: (pid) => run(powershell, psArgs(dotnetScript(pid))),
    parse: parseFiletime,
  },
  {
    id: 'ps51-dotnet-minenv',
    available: WIN && exists(powershell),
    run: (pid) => run(powershell, psArgs(dotnetScript(pid)), { env: MIN_ENV }),
    parse: parseFiletime,
  },
  {
    id: 'ps51-getprocess',
    available: WIN && exists(powershell),
    run: (pid) => run(powershell, psArgs(cmdletScript(pid))),
    parse: parseFiletime,
  },
  {
    id: 'ps51-getprocess-minenv',
    available: WIN && exists(powershell),
    run: (pid) => run(powershell, psArgs(cmdletScript(pid)), { env: MIN_ENV }),
    parse: parseFiletime,
  },
  {
    id: 'ps51-cim',
    available: WIN && exists(powershell),
    run: (pid) => run(powershell, psArgs(`(Get-CimInstance Win32_Process -Filter 'ProcessId = ${pid}' -ErrorAction Stop).CreationDate.ToFileTimeUtc()`)),
    parse: parseFiletime,
  },
  {
    id: 'pwsh-dotnet',
    available: Boolean(pwsh),
    run: (pid) => run(pwsh, psArgs(dotnetScript(pid))),
    parse: parseFiletime,
  },
  {
    id: 'cscript-wmi',
    available: WIN && exists(cscript),
    run: (pid) => run(cscript, ['//Nologo', '//E:JScript', wmiScript, String(pid)]),
    parse: parseWmiDate,
  },
  {
    id: 'wmic',
    available: WIN && exists(wmic),
    run: (pid) => run(wmic, ['process', 'where', `ProcessId=${pid}`, 'get', 'CreationDate', '/value']),
    parse: parseWmiDate,
  },
  {
    id: 'msys-ps-W',
    available: Boolean(msysPs),
    run: () => run(msysPs, ['-W']),
    parse: () => null,
    keepRaw: false,
  },
  {
    id: 'darwin-ps-lstart',
    available: process.platform === 'darwin',
    run: (pid) => run('/bin/ps', ['-p', String(pid), '-o', 'lstart='], {
      env: { PATH: '/usr/bin:/bin', LC_ALL: 'C', LANG: 'C', TZ: 'UTC' },
      timeout: 5000,
    }),
    parse: parseLstart,
  },
];

const baselines = [
  {
    id: 'spawn-node-e0',
    available: true,
    run: () => run(process.execPath, ['-e', '0']),
  },
  {
    id: 'spawn-cmd-exit',
    available: WIN && exists(cmd),
    run: () => run(cmd, ['/d', '/c', 'exit 0']),
  },
  {
    id: 'spawn-true',
    available: !WIN,
    run: () => run('/usr/bin/true', []),
  },
];

const exactReader = () => candidates.find((entry) => entry.available && (entry.id === 'ps51-dotnet' || entry.id === 'darwin-ps-lstart')) || null;

function startTarget() {
  return childProcess.spawn(process.execPath, ['-e', 'setInterval(() => {}, 1e6)'], { stdio: 'ignore', windowsHide: true });
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function spawnReady(source, args = []) {
  return new Promise((resolve) => {
    const child = childProcess.spawn(process.execPath, ['-e', source, ...args], { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    let stdout = '';
    let stderr = '';
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      resolve({ child, line: stdout.split('\n')[0], stderr });
    };
    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString('utf8');
      if (stdout.includes('\n')) finish();
    });
    child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
    child.on('error', finish);
    child.on('exit', finish);
    setTimeout(finish, 20000);
  });
}

function waitExit(child) {
  return new Promise((resolve) => {
    if (child.exitCode !== null || child.signalCode !== null) {
      resolve();
      return;
    }
    child.on('exit', () => resolve());
    setTimeout(resolve, 10000);
  });
}

function measure(entry, pid, rounds) {
  const samples = [];
  for (let index = 0; index < rounds; index += 1) {
    const sample = timed(() => entry.run(pid));
    samples.push({
      ms: sample.ms,
      raw: sample.result === null ? null : String(sample.result).trim().slice(0, 200),
      error: sample.error,
      stderr: sample.stderr || '',
    });
  }
  const ok = samples.filter((sample) => sample.error === null);
  const failed = samples.find((sample) => sample.error !== null) || {};
  const last = ok.length ? ok[ok.length - 1].raw : null;
  return {
    id: entry.id,
    cold_ms: samples.length ? Math.round(samples[0].ms * 10) / 10 : null,
    warm: stats(ok.slice(1).map((sample) => sample.ms)),
    all: stats(ok.map((sample) => sample.ms)),
    failures: samples.length - ok.length,
    first_error: failed.error || null,
    first_stderr: failed.stderr || null,
    sample_raw: entry.keepRaw === false ? null : last,
    parsed_ms: entry.parse && last !== null ? entry.parse(last) : null,
    over_1000ms: ok.filter((sample) => sample.ms > 1000).length,
    over_2000ms: ok.filter((sample) => sample.ms > 2000).length,
  };
}

async function clockOrdering(count) {
  const exact = exactReader();
  const cim = candidates.find((entry) => entry.available && entry.id === 'ps51-cim') || null;
  const source = [
    'const { performance } = require("node:perf_hooks");',
    'const now = Date.now();',
    'process.stdout.write(JSON.stringify({ pid: process.pid, timeOrigin: performance.timeOrigin, now, uptimeMs: process.uptime() * 1000 }) + "\\n");',
    'process.stdin.resume();',
    'process.stdin.on("end", () => process.exit(0));',
  ].join('\n');
  const rows = [];
  for (let index = 0; index < count; index += 1) {
    const spawnedAt = Date.now();
    const { child, line } = await spawnReady(source);
    let reported = null;
    try {
      reported = JSON.parse(line);
    } catch {
      rows.push({ error: `unparseable child report: ${String(line).slice(0, 120)}` });
      child.kill();
      continue;
    }
    const exactRead = exact ? timed(() => exact.run(reported.pid)) : null;
    const cimRead = cim && index < 4 ? timed(() => cim.run(reported.pid)) : null;
    const created = exactRead && exactRead.error === null ? exact.parse(exactRead.result) : null;
    const createdCim = cimRead && cimRead.error === null ? cim.parse(cimRead.result) : null;
    rows.push({
      pid: reported.pid,
      spawned_at_ms: spawnedAt,
      created_ms: created,
      created_cim_ms: createdCim,
      time_origin_ms: reported.timeOrigin,
      now_ms: reported.now,
      created_minus_spawned: created === null ? null : created - spawnedAt,
      time_origin_minus_created: created === null ? null : Math.round((reported.timeOrigin - created) * 1000) / 1000,
      now_minus_created: created === null ? null : reported.now - created,
      cim_minus_exact: created === null || createdCim === null ? null : createdCim - created,
      error: exactRead ? exactRead.error : 'no reader',
    });
    child.stdin.end();
    await waitExit(child);
  }
  const pick = (key) => stats(rows.map((row) => row[key]).filter((value) => value !== null && value !== undefined));
  return {
    reader: exact ? exact.id : null,
    rows,
    created_minus_spawned: pick('created_minus_spawned'),
    time_origin_minus_created: pick('time_origin_minus_created'),
    now_minus_created: pick('now_minus_created'),
    cim_minus_exact: pick('cim_minus_exact'),
    negative_now_minus_created: rows.filter((row) => Number.isFinite(row.now_minus_created) && row.now_minus_created < 0).length,
    negative_time_origin_minus_created: rows.filter((row) => Number.isFinite(row.time_origin_minus_created) && row.time_origin_minus_created < 0).length,
  };
}

function pidReuseSequential() {
  const file = WIN ? cmd : '/usr/bin/true';
  const args = WIN ? ['/d', '/c', 'exit 0'] : [];
  const lastExit = new Map();
  const lastIndex = new Map();
  const gaps = [];
  const spawnGaps = [];
  const started = Date.now();
  let spawns = 0;
  while (spawns < REUSE_SPAWNS && Date.now() - started < REUSE_BUDGET_MS) {
    const before = Date.now();
    const result = childProcess.spawnSync(file, args, { stdio: 'ignore', windowsHide: true });
    const after = Date.now();
    spawns += 1;
    const pid = result.pid;
    if (!Number.isInteger(pid) || pid <= 0) continue;
    if (lastExit.has(pid)) {
      gaps.push(before - lastExit.get(pid));
      spawnGaps.push(spawns - lastIndex.get(pid));
    }
    lastExit.set(pid, after);
    lastIndex.set(pid, spawns);
  }
  const within = (limit) => gaps.filter((gap) => gap <= limit).length;
  return {
    spawns,
    elapsed_ms: Date.now() - started,
    distinct_pids: lastExit.size,
    reuses: gaps.length,
    gap_ms: stats(gaps),
    gap_spawns: stats(spawnGaps),
    reused_within_ms: { 100: within(100), 500: within(500), 1000: within(1000), 2000: within(2000), 5000: within(5000) },
  };
}

function pidReuseParallel(concurrency, budgetMs) {
  const file = WIN ? cmd : '/usr/bin/true';
  const args = WIN ? ['/d', '/c', 'exit 0'] : [];
  const script = `
    const cp = require('node:child_process');
    const [file, argsJson, concurrency, budget] = process.argv.slice(1);
    const args = JSON.parse(argsJson);
    const lastExit = new Map();
    const gaps = [];
    let spawns = 0;
    const started = Date.now();
    function one() {
      if (Date.now() - started > Number(budget)) return Promise.resolve();
      return new Promise((resolve) => {
        const before = Date.now();
        const child = cp.spawn(file, args, { stdio: 'ignore', windowsHide: true });
        const pid = child.pid;
        spawns += 1;
        if (lastExit.has(pid)) gaps.push(before - lastExit.get(pid));
        child.on('exit', () => { lastExit.set(pid, Date.now()); resolve(); });
        child.on('error', () => resolve());
      }).then(one);
    }
    Promise.all(Array.from({ length: Number(concurrency) }, one)).then(() => {
      process.stdout.write(JSON.stringify({ spawns, distinct: lastExit.size, gaps }));
    });
  `;
  const output = childProcess.execFileSync(process.execPath, ['-e', script, file, JSON.stringify(args), String(concurrency), String(budgetMs)], {
    encoding: 'utf8',
    timeout: budgetMs + 60000,
    windowsHide: true,
    maxBuffer: 64 * 1024 * 1024,
  });
  const parsed = JSON.parse(output);
  const within = (limit) => parsed.gaps.filter((gap) => gap <= limit).length;
  return {
    concurrency,
    spawns: parsed.spawns,
    distinct_pids: parsed.distinct,
    reuses: parsed.gaps.length,
    gap_ms: stats(parsed.gaps),
    reused_within_ms: { 100: within(100), 500: within(500), 1000: within(1000), 2000: within(2000), 5000: within(5000) },
  };
}

async function exlockBeacon() {
  if (!WIN) return { skipped: 'not win32' };
  const beacon = path.join(OUT_DIR, 'beacon.lock');
  const flag = 0x10000000;
  const source = [
    'const fs = require("node:fs");',
    `const fd = fs.openSync(process.argv[1], fs.constants.O_RDWR | fs.constants.O_CREAT | ${flag});`,
    'process.stdout.write("held\\n");',
    'setInterval(() => { void fd; }, 1e6);',
  ].join('\n');
  const { child, line, stderr } = await spawnReady(source, [beacon]);
  const attempt = (label, fn) => {
    try {
      fs.closeSync(fn());
      return { label, result: 'opened' };
    } catch (error) {
      return { label, result: error.code || error.message };
    }
  };
  const whileHeld = [
    attempt('open-read', () => fs.openSync(beacon, 'r')),
    attempt('open-exlock', () => fs.openSync(beacon, fs.constants.O_RDWR | flag)),
  ];
  const killedAt = Date.now();
  child.kill();
  let afterKill = null;
  let openedAfterMs = null;
  while (Date.now() - killedAt < 10000) {
    afterKill = attempt('open-read-after-kill', () => fs.openSync(beacon, 'r'));
    if (afterKill.result === 'opened') {
      openedAfterMs = Date.now() - killedAt;
      break;
    }
    await delay(5);
  }
  return {
    exported_constant: fs.constants.UV_FS_O_EXLOCK === undefined ? null : fs.constants.UV_FS_O_EXLOCK,
    holder_ready: String(line).trim(),
    holder_stderr: String(stderr).slice(0, 300),
    while_held: whileHeld,
    after_kill: afterKill,
    opened_after_kill_ms: openedAfterMs,
  };
}

function systemProcesses() {
  if (!WIN) return { skipped: 'not win32' };
  const listing = run(path.join(system32, 'tasklist.exe'), ['/FO', 'CSV', '/NH']);
  const wanted = ['System', 'smss.exe', 'csrss.exe', 'wininit.exe', 'services.exe', 'lsass.exe', 'svchost.exe', 'MsMpEng.exe'];
  const found = new Map();
  for (const lineText of listing.split(/\r?\n/)) {
    const cells = lineText.split('","').map((cell) => cell.replace(/^"|"$/g, ''));
    if (cells.length < 2) continue;
    const [name, pidText] = cells;
    if (wanted.includes(name) && !found.has(name)) found.set(name, Number(pidText));
  }
  const readers = candidates.filter((entry) => entry.available && ['ps51-dotnet', 'ps51-getprocess', 'ps51-cim'].includes(entry.id));
  const rows = [];
  for (const [name, pid] of found) {
    const row = { name, pid };
    for (const reader of readers) {
      const sample = timed(() => reader.run(pid));
      row[reader.id] = sample.error === null
        ? `ok ${String(sample.result).trim().slice(0, 24)}`
        : `fail: ${String(sample.stderr || sample.error).replace(/\s+/g, ' ').slice(0, 140)}`;
    }
    rows.push(row);
  }
  return rows;
}

function errorPath() {
  const reader = exactReader();
  if (!reader) return null;
  const sample = timed(() => reader.run(WIN ? 999999996 : 99999));
  return {
    reader: reader.id,
    ms: Math.round(sample.ms),
    error: sample.error,
    status: sample.status === undefined ? null : sample.status,
    stdout: sample.result,
    stderr: String(sample.stderr || '').replace(/\s+/g, ' ').slice(0, 160),
  };
}

async function underLoad() {
  const reader = exactReader();
  if (!reader) return null;
  const burners = Array.from({ length: Number(process.env.PROBE_BURNERS || os.cpus().length) }, () => childProcess.spawn(process.execPath, ['-e', 'for (;;) {}'], { stdio: 'ignore', windowsHide: true }));
  const target = startTarget();
  await delay(1500);
  try {
    return {
      burners: burners.length,
      reader: measure(reader, target.pid, 8),
      node: measure(baselines[0], target.pid, 8),
    };
  } finally {
    target.kill();
    for (const burner of burners) burner.kill();
  }
}

function languageMode() {
  if (!WIN || !exists(powershell)) return null;
  const sample = timed(() => run(powershell, psArgs('$ExecutionContext.SessionState.LanguageMode')));
  return sample.error === null ? String(sample.result).trim() : `error: ${sample.error}`;
}

function kill0Cost(pid) {
  const rounds = 2000;
  const started = performance.now();
  for (let index = 0; index < rounds; index += 1) {
    try {
      process.kill(pid, 0);
    } catch {
      continue;
    }
  }
  return Math.round(((performance.now() - started) / rounds) * 1000) / 1000;
}

async function section(name, fn) {
  const started = Date.now();
  try {
    const value = await fn();
    process.stderr.write(`[probe] ${name} done in ${Date.now() - started} ms\n`);
    return value;
  } catch (error) {
    process.stderr.write(`[probe] ${name} failed: ${error && error.stack}\n`);
    return { error: String(error && error.message).slice(0, 300) };
  }
}

async function main() {
  const report = {
    label: LABEL,
    node: process.version,
    platform: process.platform,
    arch: process.arch,
    os_release: os.release(),
    image_os: process.env.ImageOS || null,
    image_version: process.env.ImageVersion || null,
    cpus: os.cpus().length,
    cpu_model: (os.cpus()[0] || {}).model || null,
    rounds: ROUNDS,
    available: Object.fromEntries(candidates.map((entry) => [entry.id, Boolean(entry.available)])),
    pwsh,
    msys_ps: msysPs,
  };

  const target = startTarget();
  await delay(500);
  report.target_pid = target.pid;
  report.language_mode = await section('language-mode', languageMode);
  report.kill0_us = await section('kill0', () => kill0Cost(target.pid));
  report.baselines = await section('baselines', () => baselines.filter((entry) => entry.available).map((entry) => measure(entry, target.pid, ROUNDS + 1)));
  report.helpers = await section('helpers', () => candidates.filter((entry) => entry.available).map((entry) => measure(entry, target.pid, ROUNDS + 1)));
  target.kill();
  report.error_path = await section('error-path', errorPath);
  report.clock_ordering = await section('clock-ordering', () => clockOrdering(12));
  report.exlock_beacon = await section('exlock-beacon', exlockBeacon);
  report.system_processes = await section('system-processes', systemProcesses);
  report.under_load = await section('under-load', underLoad);
  report.pid_reuse_sequential = await section('pid-reuse-sequential', pidReuseSequential);
  report.pid_reuse_parallel = await section('pid-reuse-parallel', () => pidReuseParallel(8, PARALLEL_BUDGET_MS));

  fs.writeFileSync(path.join(OUT_DIR, `result-${LABEL}.json`), `${JSON.stringify(report, null, 2)}\n`);

  const lines = [];
  lines.push(`## win32 start-time probe: ${LABEL}`);
  lines.push('');
  lines.push(`node ${report.node}, ${report.platform} ${report.os_release}, image ${report.image_os} ${report.image_version}, ${report.cpus} CPUs (${report.cpu_model}), language mode ${report.language_mode}`);
  lines.push('');
  lines.push('| id | cold ms | warm p50 | warm p90 | warm max | failures | over 1 s | parsed |');
  lines.push('|---|---|---|---|---|---|---|---|');
  const tableRows = [
    ...(Array.isArray(report.baselines) ? report.baselines : []),
    ...(Array.isArray(report.helpers) ? report.helpers : []),
  ];
  for (const row of tableRows) {
    const warm = row.warm || {};
    const parsed = Number.isFinite(row.parsed_ms) ? new Date(row.parsed_ms).toISOString() : '';
    lines.push(`| ${row.id} | ${row.cold_ms} | ${warm.p50} | ${warm.p90} | ${warm.max} | ${row.failures} | ${row.over_1000ms} | ${parsed} |`);
  }
  lines.push('');
  lines.push(`kill(pid, 0): ${report.kill0_us} us per call`);
  lines.push('');
  lines.push('```json');
  const ordering = report.clock_ordering || {};
  const load = report.under_load || {};
  lines.push(JSON.stringify({
    failures: tableRows.filter((row) => row.failures > 0).map((row) => ({ id: row.id, error: row.first_error, stderr: row.first_stderr })),
    error_path: report.error_path,
    clock_ordering: {
      reader: ordering.reader,
      created_minus_spawned: ordering.created_minus_spawned,
      time_origin_minus_created: ordering.time_origin_minus_created,
      now_minus_created: ordering.now_minus_created,
      cim_minus_exact: ordering.cim_minus_exact,
      negative_now_minus_created: ordering.negative_now_minus_created,
      negative_time_origin_minus_created: ordering.negative_time_origin_minus_created,
      error: ordering.error,
    },
    exlock_beacon: report.exlock_beacon,
    system_processes: report.system_processes,
    under_load: {
      burners: load.burners,
      reader_cold: load.reader && load.reader.cold_ms,
      reader_warm: load.reader && load.reader.warm,
      node_warm: load.node && load.node.warm,
      error: load.error,
    },
    pid_reuse_sequential: report.pid_reuse_sequential,
    pid_reuse_parallel: report.pid_reuse_parallel,
  }, null, 2));
  lines.push('```');
  const summary = `${lines.join('\n')}\n`;
  process.stdout.write(summary);
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, summary);
}

main().then(() => process.exit(0), (error) => {
  process.stderr.write(`${error && error.stack}\n`);
  process.exit(1);
});
