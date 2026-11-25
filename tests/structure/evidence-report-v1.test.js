'use strict';

const assert = require('node:assert/strict');
const childProcess = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const test = require('node:test');

const ISOLATED_HOME = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'erp-git-home-')));
process.env.HOME = ISOLATED_HOME;
process.env.XDG_CONFIG_HOME = path.join(ISOLATED_HOME, '.config');
process.env.GIT_CONFIG_NOSYSTEM = '1';

const ROOT = path.join(__dirname, '..', '..');
const LIB = path.join(ROOT, 'hooks', 'lib', 'evidence-report-v1.js');
const er = require(LIB);
const av = require(path.join(ROOT, 'hooks', 'lib', 'acceptance-verify-v1.js'));
const evr = require(path.join(ROOT, 'hooks', 'lib', 'evidence-run-v1.js'));
const CORE = path.join(ROOT, 'hooks', 'lib', 'session-control-core-v1.js');
const core = require(CORE);
const CORPUS = path.join(ROOT, 'tests', 'fixtures', 'evidence-report', 'v1', 'cases');

const SESSION = `scv1_${'a'.repeat(64)}`;
const OTHER_SESSION = `scv1_${'b'.repeat(64)}`;
const STEM = '2026-11-09-0100_build-sample';
const FAKE_TOKEN = `ghp_${'Q7mZ'.repeat(9)}`;
const ALLOW = ['zensu', 'secret', 'allow'].join('-');
const SPLIT_KEY = ['api', 'token'].join('_');
const SPLIT_VALUE = ['Q2x9Lm3N', 'p8Rt5Vw1', 'Yz7k'].join('');
const NOT_ON_WINDOWS = process.platform === 'win32' ? 'symlinks, hard links and FIFOs are not created portably on Windows' : false;
const FEATURE = 'feature: The settings page saves the chosen locale\nAC-001: The locale persists after a reload\nAC-002: The API answers 200\n';
const FIELDS = 'title: Save the locale\nexpected: The page shows the new locale\nobserved: The page shows the new locale\n';

function tempDir(label) {
  return fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), `erp-${label}-`)));
}

function git(cwd, ...args) {
  return childProcess.execFileSync('git', args, { cwd, env: evr.gitEnvironment(), stdio: ['ignore', 'pipe', 'pipe'], encoding: 'utf8' });
}

function repo(options = {}) {
  const root = tempDir(options.label || 'repo');
  git(root, 'init', '-q');
  git(root, 'config', 'user.email', 't@example.invalid');
  git(root, 'config', 'user.name', 'tester');
  git(root, 'config', 'commit.gpgsign', 'false');
  fs.writeFileSync(path.join(root, '.gitignore'), options.ignore || '.zensu/\n');
  fs.writeFileSync(path.join(root, 'a.txt'), 'one\n');
  git(root, 'add', '-A');
  git(root, 'commit', '-q', '-m', 'init');
  if (options.remote) git(root, 'remote', 'add', 'origin', options.remote);
  return root;
}

function crc32(buffer) {
  let crc = 0xffffffff;
  for (let index = 0; index < buffer.length; index += 1) {
    let value = (crc ^ buffer[index]) & 0xff;
    for (let bit = 0; bit < 8; bit += 1) value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
    crc = (crc >>> 8) ^ value;
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function pngChunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'latin1'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}

function png(width, height, seed = 1, noise = false) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 2;
  const raw = noise ? crypto.randomBytes((width * 3 + 1) * height) : Buffer.alloc((width * 3 + 1) * height, seed);
  for (let row = 0; row < height; row += 1) raw[row * (width * 3 + 1)] = 0;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk('IHDR', header),
    pngChunk('IDAT', zlib.deflateSync(raw)),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

function riff(chunks) {
  const body = Buffer.concat([Buffer.from('WEBP', 'latin1'), ...chunks.map(([fourcc, data]) => {
    const head = Buffer.alloc(8);
    head.write(fourcc, 0, 'latin1');
    head.writeUInt32LE(data.length, 4);
    return Buffer.concat([head, data, data.length % 2 ? Buffer.alloc(1) : Buffer.alloc(0)]);
  })]);
  const head = Buffer.alloc(8);
  head.write('RIFF', 0, 'latin1');
  head.writeUInt32LE(body.length, 4);
  return Buffer.concat([head, body]);
}

const NO_STAND_IN_TOOLS = NOT_ON_WINDOWS && 'a stand-in tool is a script with an interpreter line, which Windows does not start';
const ENCODER_FLAGS = ['-quiet', '-lossless', '-exact', '-z', '6', '-metadata', 'icc'];
const LIBPNG_FILTERS_PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAwAAAAKCAIAAAAPTiitAAAAtUlEQVQYlWO06bnffe3fHUZtuaOHTk19Hpe7Kk7F7rP0XWW9oB4vE6PZbuKblBiZmZnZOTjxIyYGIgALr5AQKzMHGxsbCzs7CysXMxs7EwvLf0b2f4zMf/8x//rD+O/3f2ZiTGJI8HaeF3H7VbrmnlP+xkXl5/8u4GOfwlr28vUbpaIZgZcupvh/2EJFh6vpm7KwcbGzs7GxsbKwsDOzc7GzszCzsLOxcbGxs7Cws7OxcBHlcAA4RzDIlwVv0gAAAABJRU5ErkJggg==', 'base64');
const LIBPNG_FILTERS_RGBA = '68476c89762a2d65c7e2a64e3f29c7ef0543c0830954d9ea96d20d70cae6a6f4';
const STAND_IN_TOOL = [
  `#!${process.execPath}`,
  "'use strict';",
  "const fs = require('node:fs');",
  "const plan = JSON.parse(fs.readFileSync(`${__filename}.json`, 'utf8'));",
  'const args = process.argv.slice(2);',
  "fs.appendFileSync(plan.log, `${JSON.stringify({ tool: plan.tool, program: process.argv[1], args, env: process.env, cwd: process.cwd() })}\\n`);",
  'if (plan.sleepMs) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, plan.sleepMs);',
  'if (plan.exit) process.exit(plan.exit);',
  "if (plan.output) fs.copyFileSync(plan.output, args[args.indexOf('-o') + 1]);",
  '',
].join('\n');

function hex(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function sampleBytes(length, seed) {
  const bytes = Buffer.alloc(length);
  let state = seed >>> 0;
  for (let index = 0; index < length; index += 1) {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    bytes[index] = state >>> 24;
  }
  return bytes;
}

function filteredRow(type, row, previous, step) {
  const filtered = Buffer.alloc(row.length);
  for (let index = 0; index < row.length; index += 1) {
    const left = index >= step ? row[index - step] : 0;
    const up = previous ? previous[index] : 0;
    const corner = previous && index >= step ? previous[index - step] : 0;
    let predicted = 0;
    if (type === 1) predicted = left;
    if (type === 2) predicted = up;
    if (type === 3) predicted = Math.floor((left + up) / 2);
    if (type === 4) {
      const estimate = left + up - corner;
      const distances = [[Math.abs(estimate - left), left], [Math.abs(estimate - up), up], [Math.abs(estimate - corner), corner]];
      predicted = distances.reduce((best, candidate) => (candidate[0] < best[0] ? candidate : best))[1];
    }
    filtered[index] = (row[index] - predicted + 256) % 256;
  }
  return filtered;
}

function pngOf(spec) {
  const channels = spec.channels || 3;
  const filters = spec.filters || [0];
  const stride = spec.width * channels;
  const lines = [];
  let previous = null;
  for (let line = 0; line < spec.height; line += 1) {
    const row = spec.pixels.subarray(line * stride, (line + 1) * stride);
    const type = filters[line % filters.length];
    lines.push(Buffer.from([type]), filteredRow(type, row, previous, channels));
    previous = row;
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(spec.width, 0);
  header.writeUInt32BE(spec.height, 4);
  header[8] = spec.depth || 8;
  header[9] = spec.colour === undefined ? (channels === 3 ? 2 : 6) : spec.colour;
  header[12] = spec.interlace || 0;
  const data = spec.idat === undefined ? [zlib.deflateSync(Buffer.concat(lines))] : [].concat(spec.idat);
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk('IHDR', header),
    ...(spec.extra || []).map(([type, bytes]) => pngChunk(type, bytes)),
    ...data.map((bytes) => pngChunk('IDAT', bytes)),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

function rgbaOf(pixels, channels) {
  if (channels === 4) return Buffer.from(pixels);
  const rgba = Buffer.alloc((pixels.length / 3) * 4, 0xff);
  for (let source = 0, target = 0; source < pixels.length; source += 3, target += 4) pixels.copy(rgba, target, source, source + 3);
  return rgba;
}

function pamOf(width, height, rgba) {
  return Buffer.concat([Buffer.from(`P7\nWIDTH ${width}\nHEIGHT ${height}\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n`, 'latin1'), rgba]);
}

function profileChunk(profile, name = 'Display P3') {
  return Buffer.concat([Buffer.from(`${name}\u0000\u0000`, 'latin1'), zlib.deflateSync(profile)]);
}

function losslessWebp(width, height, options = {}) {
  const image = Buffer.alloc(5 + (options.pad || 3), 0x55);
  image[0] = 0x2f;
  image.writeUInt32LE(((width - 1) | ((height - 1) << 14)) >>> 0, 1);
  const flags = (options.profiles ? 0x20 : 0) | (options.exif ? 0x08 : 0) | (options.xmp ? 0x04 : 0);
  if (flags === 0) return riff([['VP8L', image]]);
  const extended = Buffer.alloc(10);
  extended[0] = flags;
  extended.writeUIntLE(width - 1, 4, 3);
  extended.writeUIntLE(height - 1, 7, 3);
  return riff([
    ['VP8X', extended],
    ...(options.profiles || []).map((profile) => ['ICCP', profile]),
    ['VP8L', image],
    ...(options.exif ? [['EXIF', Buffer.from('capture tool')]] : []),
    ...(options.xmp ? [['XMP ', Buffer.from('<x:xmpmeta/>')]] : []),
  ]);
}

function standInTools(plans = {}, directory = tempDir('tools')) {
  fs.mkdirSync(directory, { recursive: true });
  fs.chmodSync(directory, 0o755);
  const log = path.join(directory, 'calls.jsonl');
  const plan = (tool, value = {}) => fs.writeFileSync(path.join(directory, `${tool}.json`), JSON.stringify({ tool, log, ...value }));
  for (const tool of ['cwebp', 'dwebp']) {
    if (plans[tool] === null) continue;
    fs.writeFileSync(path.join(directory, tool), STAND_IN_TOOL, { mode: 0o755 });
    plan(tool, plans[tool]);
  }
  const calls = () => (fs.existsSync(log) ? fs.readFileSync(log, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line)) : []);
  const answer = (name, bytes) => {
    const target = path.join(directory, name);
    fs.writeFileSync(target, bytes);
    return target;
  };
  return { directory, plan, calls, answer };
}

function verifiedTools(width, height, pixels, channels, webpOptions = {}, directory = undefined) {
  const tools = standInTools({}, directory);
  const webp = losslessWebp(width, height, webpOptions);
  tools.plan('cwebp', { output: tools.answer('answer.webp', webp) });
  tools.plan('dwebp', { output: tools.answer('answer.pam', pamOf(width, height, rgbaOf(pixels, channels))) });
  return { ...tools, webp };
}

function scratchOf(fx) {
  return path.join(fx.data, 'evidence-report', 'v1', 'scratch');
}

function privateScratch(fx) {
  return fs.existsSync(scratchOf(fx)) ? fs.readdirSync(scratchOf(fx)).filter((name) => name.startsWith('webp-')) : [];
}

function bindingOf(fx, id) {
  return JSON.parse(fs.readFileSync(path.join(repositoryDirectory(fx), `${id}.binding.json`), 'utf8'));
}

function corpusFile(caseName, extension) {
  const directory = path.join(CORPUS, caseName, 'files');
  const name = fs.readdirSync(directory).find((entry) => entry.endsWith(`.${extension}`));
  return fs.readFileSync(path.join(directory, name));
}

function fixture(options = {}) {
  const root = options.root || repo(options);
  const runDir = path.join(root, '.zensu', 'verify-feature-runs', options.run || 'r1');
  fs.mkdirSync(runDir, { recursive: true });
  return { root, runDir, data: options.data || tempDir('data'), home: options.home || tempDir('home'), receiptPath: options.receiptPath || '', logPath: options.logPath || '' };
}

function callOptions(fx, args, stdinText, overrides = {}) {
  return {
    pluginData: fx.data,
    sessionKey: SESSION,
    projectRoot: fx.root,
    host: 'claude-code',
    home: fx.home,
    pluginVersion: '0.36.0',
    args: new Map(Object.entries(args)),
    stdinText,
    config: {},
    chain: { receiptPath: fx.receiptPath, editLandingEscaped: false, workTree: '', workTreeFault: null, bashPath: 'bash' },
    ...overrides,
  };
}

const VERB_CALLS = { begin: er.begin, add: er.add, step: er.step, render: er.render, list: er.list, export: er.exportReport };

function call(fx, verb, args = {}, stdinText = '', overrides = {}) {
  try {
    return VERB_CALLS[verb](callOptions(fx, args, stdinText, overrides));
  } catch (error) {
    if (error instanceof er.ReportError) return { code: error.exitCode, errors: [error.message] };
    throw error;
  }
}

function ok(result) {
  assert.equal(result.code, 0, JSON.stringify(result.errors || result.lines));
  return result;
}

function refused(result, pattern, code = 1) {
  assert.equal(result.code, code, JSON.stringify(result));
  assert.match((result.errors || []).join('\n'), pattern);
  return result;
}

function begin(fx, extra = {}, stdinText = FEATURE, overrides = {}) {
  return ok(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser,api', ...extra }, stdinText, overrides));
}

function runFile(fx, name, bytes) {
  const target = path.join(fx.runDir, name);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, bytes);
  return target;
}

function addImage(fx, id, name = 'shot.png', bytes = png(4, 3), caption = 'The settings page after a reload') {
  return ok(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, name, bytes) }, caption));
}

function step(fx, id, args = {}, fields = FIELDS) {
  return call(fx, 'step', { report: id, priority: 'P0', driver: 'browser', result: 'pass', ...args }, fields);
}

function manifestOf(bundle) {
  return JSON.parse(fs.readFileSync(path.join(bundle, 'manifest.json'), 'utf8'));
}

function repositoryDirectory(fx, overrides = {}) {
  return path.join(overrides.store || path.join(fx.data, 'evidence-report', 'v1'), er.repositoryKey(fx.root));
}

function lockOf(directory, id) {
  return { lockDirectory: directory, resourcePath: path.join(directory, `${id}.binding.json`) };
}

function idle(fx, id) {
  const when = new Date(Date.now() - er.LIMITS.openReportMs - 24 * 60 * 60 * 1000);
  fs.utimesSync(path.join(repositoryDirectory(fx), `${id}.binding.json`), when, when);
}

function footprint(started, fx) {
  const directory = repositoryDirectory(fx);
  const files = path.join(directory, started.id, 'files');
  const stored = fs.readdirSync(files).reduce((sum, name) => sum + fs.statSync(path.join(files, name)).size, 0);
  return stored + fs.statSync(path.join(directory, `${started.id}.binding.json`)).size;
}

function corpusCases() {
  return fs.readdirSync(CORPUS).sort().map((name) => ({ name, directory: path.join(CORPUS, name), spec: JSON.parse(fs.readFileSync(path.join(CORPUS, name, 'case.json'), 'utf8')) }));
}

const CASE_KEYS = Object.freeze(['description', 'inScope', 'limits', 'expect']);

function caseFaults(name, spec) {
  const faults = Object.keys(spec).filter((key) => !CASE_KEYS.includes(key)).map((key) => `${name}: case.json carries ${key}, which the corpus does not define`);
  if (spec.limits === undefined) return faults;
  const { limits } = spec;
  if (limits === null || typeof limits !== 'object' || Array.isArray(limits)) return [...faults, `${name}: limits is no object`];
  for (const key of Object.keys(limits).filter((item) => item !== 'maxManifestBytes')) faults.push(`${name}: limits carries ${key}, but a case may lower only maxManifestBytes`);
  if ('maxManifestBytes' in limits && !(Number.isSafeInteger(limits.maxManifestBytes) && limits.maxManifestBytes > 0)) faults.push(`${name}: limits.maxManifestBytes is no positive integer`);
  return faults;
}

function planText(rows) {
  const body = rows.map(([id, text]) => `| ${id} | ${text} | spec |`).join('\n');
  return `# Plan\n\n## Requirements\n| ID | Requirement | Source |\n|----|-------------|--------|\n${body}\n\n## Steps\n`;
}

function chainFixture(options = {}) {
  const fx = fixture(options);
  fs.mkdirSync(path.join(fx.root, '.zensu', 'logs'), { recursive: true });
  fs.mkdirSync(path.join(fx.root, '.zensu', 'plans'), { recursive: true });
  fs.mkdirSync(path.join(fx.root, '.zensu', 'state'), { recursive: true });
  fx.logPath = path.join(fx.root, '.zensu', 'logs', `${STEM}.log`);
  fs.writeFileSync(fx.logPath, 'BUILD STARTED\n');
  fs.writeFileSync(path.join(fx.root, '.zensu', 'plans', `${STEM}.md`), planText([
    ['AC-001', 'The dashboard lists every project'],
    ['AC-002', 'The export downloads a CSV file'],
    ['AC-003', 'Projects are sorted by name'],
    ['AC-004', '(deprecated) The legacy grid view renders'],
  ]));
  fx.receiptPath = path.join(fx.root, '.zensu', 'state', 'edit-landing-test.json');
  fs.writeFileSync(fx.receiptPath, JSON.stringify({ schema: 'edit-landing-v2', session: 'x', log: `.zensu/logs/${STEM}.log`, clean: true }));
  return fx;
}

function attest(fx, ac, verdict, evidenceText) {
  const result = av.record({ pluginData: fx.data, sessionKey: SESSION, projectRoot: fx.root, receiptPath: fx.receiptPath, logPath: fx.logPath, bashPath: 'bash', ac, verdict, driver: 'browser', evidenceText });
  assert.equal(result.code, 0, result.error);
  return result.record;
}

function digest(text) {
  return `sha256:${crypto.createHash('sha256').update(Buffer.from(text, 'utf8')).digest('hex')}`;
}

test('report ids are well formed and sort by creation time', () => {
  const first = er.newReportId(1790000000000);
  const second = er.newReportId(1790000000001);
  assert.match(first, /^vr1_1790000000000_[0-9a-f]{12}$/);
  assert.match(first, er.ID_RE);
  assert.ok(first < second);
  assert.throws(() => er.newReportId(-1), /clock value/);
  assert.throws(() => er.newReportId(1.5), /clock value/);
});

test('the conformance corpus renders or refuses every case as expected', () => {
  const cases = corpusCases();
  assert.ok(cases.length >= 37, `the corpus holds ${cases.length} cases`);
  assert.deepEqual(caseFaults('probe', { description: 'x', inScope: [], expect: {}, limits: { maxFileBytes: 1, maxManifestBytes: 0 }, extra: true }), [
    'probe: case.json carries extra, which the corpus does not define',
    'probe: limits carries maxFileBytes, but a case may lower only maxManifestBytes',
    'probe: limits.maxManifestBytes is no positive integer',
  ]);
  assert.deepEqual(caseFaults('probe', { description: 'x', inScope: [], expect: {}, limits: [] }), ['probe: limits is no object']);
  const mismatches = [];
  for (const entry of cases) {
    mismatches.push(...caseFaults(entry.name, entry.spec));
    const result = er.renderDirectory(entry.directory, { inScope: entry.spec.inScope, limits: entry.spec.limits });
    if (entry.spec.expect.rendering) {
      if (result.faults) mismatches.push(`${entry.name}: refused ${JSON.stringify(result.faults.map((fault) => fault.code))}`);
      else if (digest(result.html) !== entry.spec.expect.rendering) mismatches.push(`${entry.name}: rendering digest ${digest(result.html)}`);
    } else {
      const got = (result.faults || []).map((fault) => `${fault.code}@${fault.at}`).sort();
      const want = entry.spec.expect.refusal.map((fault) => `${fault.code}@${fault.at}`).sort();
      if (JSON.stringify(got) !== JSON.stringify(want)) mismatches.push(`${entry.name}: ${JSON.stringify(got)} instead of ${JSON.stringify(want)}`);
      for (const fault of result.faults || []) {
        if (!fault.message || !fault.remedy) mismatches.push(`${entry.name}: ${fault.code} names no message or no remedy`);
      }
    }
  }
  assert.deepEqual(mismatches, []);
});

test('the corpus names every fault code the module exports, and the module raises no code it does not export', () => {
  const codes = new Set();
  for (const entry of corpusCases()) {
    for (const fault of entry.spec.expect.refusal || []) codes.add(fault.code);
  }
  assert.ok(Object.isFrozen(er.FAULT_CODES));
  for (const code of er.FAULT_CODES) assert.ok(codes.has(code), `the corpus lacks a case for ${code}`);
  for (const code of codes) assert.ok(er.FAULT_CODES.includes(code), `the corpus names ${code}, which the module does not export`);
  const source = fs.readFileSync(LIB, 'utf8');
  const raised = new Set([...source.matchAll(/addFault\(faults, '([a-z-]+\.[a-z-]+)'/g), ...source.matchAll(/\bcode: '([a-z-]+\.[a-z-]+)'/g)].map((match) => match[1]));
  assert.ok(raised.size >= er.FAULT_CODES.length);
  assert.deepEqual([...raised].filter((code) => !er.FAULT_CODES.includes(code)), []);
  assert.deepEqual(er.FAULT_CODES.filter((code) => !raised.has(code)), []);
  const hosts = new Set(corpusCases().filter((entry) => entry.spec.expect.rendering).map((entry) => JSON.parse(fs.readFileSync(path.join(entry.directory, 'manifest.json'), 'utf8')).run.host));
  assert.ok(hosts.size >= 2, 'the corpus renders reports of more than one host');
});

test('the manifest validator refuses an unknown or a missing key on every object', () => {
  const base = JSON.parse(fs.readFileSync(path.join(CORPUS, 'render-chain-partial', 'manifest.json'), 'utf8'));
  const matrix = JSON.parse(fs.readFileSync(path.join(CORPUS, 'render-matrix-pass', 'manifest.json'), 'utf8'));
  const failing = JSON.parse(fs.readFileSync(path.join(CORPUS, 'render-fail', 'manifest.json'), 'utf8'));
  const webp = Object.keys(base.files)[0];
  const png4 = Object.keys(matrix.files).find((sha) => matrix.files[sha].type === 'image/png');
  const objects = [
    [base, ''], [base, 'run'], [base, 'run.chain'], [base, 'target'], [base, 'coverage'], [base, 'coverage.criteria[0]'],
    [base, 'coverage.criteria[0].zensu'], [base, 'steps[0]'], [base, 'evidence.e1'], [base, 'evidence.e2'],
    [base, `files.${webp}`], [base, `files.${webp}.viewport`], [base, 'sections'], [matrix, 'sections.consent[0]'],
    [matrix, 'evidence.e2'], [matrix, 'evidence.e3'], [matrix, 'evidence.e4'], [matrix, `files.${png4}`], [failing, 'evidence.e2'],
  ];
  function resolve(object, at) {
    if (at === '') return object;
    return at.split('.').reduce((current, part) => {
      const match = /^([^[]+)(?:\[([0-9]+)\])?$/.exec(part);
      const next = current[match[1]];
      return match[2] === undefined ? next : next[Number(match[2])];
    }, object);
  }
  for (const [source, at] of objects) {
    const added = structuredClone(source);
    resolve(added, at).surplus = 1;
    const addedFaults = er.validateManifest(added).map((fault) => `${fault.code}@${fault.at}`);
    assert.ok(addedFaults.includes(`schema.unknown-key@${at ? `${at}.` : ''}surplus`), `${at || 'top level'}: ${JSON.stringify(addedFaults)}`);
    const removed = structuredClone(source);
    const target = resolve(removed, at);
    const key = Object.keys(target).sort()[0];
    delete target[key];
    const removedFaults = er.validateManifest(removed).map((fault) => `${fault.code}@${fault.at}`);
    assert.ok(removedFaults.includes(`schema.missing-key@${at ? `${at}.` : ''}${key}`), `${at || 'top level'} without ${key}: ${JSON.stringify(removedFaults)}`);
  }
  assert.deepEqual(er.validateManifest([]).map((fault) => fault.code), ['schema.type']);
});

test('the manifest validator refuses malformed values', () => {
  const base = JSON.parse(fs.readFileSync(path.join(CORPUS, 'render-matrix-pass', 'manifest.json'), 'utf8'));
  const cases = [
    ['id', (m) => { m.id = 'vr1_1'; }],
    ['created_at', (m) => { m.created_at = '2026-11-09 10:00'; }],
    ['verdict', (m) => { m.verdict = 'pass'; }],
    ['run.host', (m) => { m.run.host = 'Claude Code'; }],
    ['run.mode', (m) => { m.run.mode = 'cloud'; }],
    ['run.drivers[0]', (m) => { m.run.drivers = ['telepathy']; }],
    ['run.drivers[1]', (m) => { m.run.drivers = ['browser', 'browser']; }],
    ['run.recipe', (m) => { m.run.recipe = '../outside.yaml'; }],
    ['run.feature', (m) => { m.run.feature = 'two\nlines'; }],
    ['target.head', (m) => { m.target.head = 'HEAD'; }],
    ['target.begin_tree', (m) => { m.target.begin_tree = 'HEAD'; }],
    ['run.feature', (m) => { m.run.feature = `left${String.fromCharCode(0x200e)}right`; }],
    ['target.origin', (m) => { m.target.origin = 'http://localhost:3000'; }],
    ['coverage.source', (m) => { m.coverage.source = 'acceptance-records'; }],
    ['coverage.criteria[0].state', (m) => { m.coverage.criteria[0].state = 'green'; }],
    ['coverage.criteria[1].id', (m) => { m.coverage.criteria[1].id = 'AC-001'; }],
    ['coverage.criteria[0].record', (m) => { m.coverage.criteria[0].record = 'av1_1794200000000_aaaaaaaaaaaa'; }],
    ['steps[0].n', (m) => { m.steps[0].n = 2; }],
    ['steps[0].priority', (m) => { m.steps[0].priority = 'P3'; }],
    ['steps[0].criteria[0]', (m) => { m.steps[0].criteria = ['FR-001']; }],
    ['evidence.e1.plane', (m) => { m.evidence.e1.plane = 'audio'; }],
    ['evidence.e3.path', (m) => { m.evidence.e3.path = '/api?token=1'; }],
    ['evidence.e3.status', (m) => { m.evidence.e3.status = 99; }],
    ['evidence.e4.source', (m) => { m.evidence.e4.source = 'kernel'; }],
    ['sections.console', (m) => { m.sections.console = 'unknown'; }],
    ['sections.consent[0].decided_by', (m) => { m.sections.consent[0].decided_by = 'guessed'; }],
    ['sections.limitations[1]', (m) => { m.sections.limitations.push(m.sections.limitations[0]); }],
  ];
  for (const [at, mutate] of cases) {
    const manifest = structuredClone(base);
    mutate(manifest);
    const faults = er.validateManifest(manifest);
    assert.ok(faults.some((fault) => fault.at === at && fault.code.startsWith('schema.')), `${at}: ${JSON.stringify(faults)}`);
  }
  const big = structuredClone(base);
  big.files = Object.fromEntries(Array.from({ length: 3 }, (unused, index) => [crypto.createHash('sha256').update(String(index)).digest('hex'), base.files[Object.keys(base.files)[0]]]));
  assert.ok(er.validateManifest(big, { maxFiles: 2 }).some((fault) => fault.code === 'schema.limit' && fault.at === 'files'));
  const tooLarge = tempDir('large');
  fs.writeFileSync(path.join(tooLarge, 'manifest.json'), JSON.stringify(base));
  assert.deepEqual(er.renderDirectory(tooLarge, { limits: { maxManifestBytes: 64 } }).faults.map((fault) => fault.code), ['manifest.too-large']);
});

test('rendering the same manifest twice yields identical bytes under any time zone and locale', () => {
  const directory = path.join(CORPUS, 'render-chain-partial');
  const first = er.renderDirectory(directory, {}).html;
  const second = er.renderDirectory(directory, {}).html;
  assert.equal(first, second);
  const expected = JSON.parse(fs.readFileSync(path.join(directory, 'case.json'), 'utf8')).expect.rendering;
  const script = `process.stdout.write(require(${JSON.stringify(LIB)}).renderDirectory(${JSON.stringify(directory)}, {}).html)`;
  const env = { ...process.env, TZ: 'Pacific/Chatham', LANG: 'tr_TR.UTF-8', LC_ALL: 'tr_TR.UTF-8' };
  const child = childProcess.execFileSync(process.execPath, ['-e', script], { env, encoding: 'utf8' });
  assert.equal(digest(child), expected);
  assert.equal(digest(first), expected);
});

test('the rendered page carries no script, no external URL and only images inside the bundle', () => {
  for (const entry of corpusCases().filter((item) => item.spec.expect.rendering)) {
    for (const mode of ['bundle', 'export']) {
      const result = er.renderDirectory(entry.directory, { mode });
      const html = result.html;
      assert.doesNotMatch(html, /<script/i, entry.name);
      assert.doesNotMatch(html, /url\(|@import|javascript:/i, entry.name);
      for (const tag of html.match(/<[a-z][^>]*>/gi)) {
        assert.doesNotMatch(tag, /\son[a-z]+\s*=/i, `${entry.name}: ${tag}`);
        assert.doesNotMatch(tag, /https?:/i, `${entry.name}: ${tag}`);
      }
      for (const [, attribute, value] of html.matchAll(/\s(src|href)="([^"]*)"/g)) {
        if (mode === 'bundle') {
          assert.match(value, /^files\/[0-9a-f]{64}\.(png|webp)$/, `${entry.name}: ${attribute}=${value}`);
          assert.ok(fs.existsSync(path.join(entry.directory, value)), `${entry.name}: ${value} lies inside the bundle`);
        } else {
          assert.equal(attribute, 'src', `${entry.name}: the export links nothing`);
          const match = /^data:(image\/(?:png|webp));base64,(.+)$/.exec(value);
          assert.ok(match, `${entry.name}: ${value.slice(0, 40)}`);
          const sha = crypto.createHash('sha256').update(Buffer.from(match[2], 'base64')).digest('hex');
          assert.ok(result.manifest.files[sha], `${entry.name}: the inlined image is a file of the bundle`);
        }
      }
      assert.match(html, /<meta name="referrer" content="no-referrer">/);
    }
  }
});

test('every fixed heading and label of the report is English', () => {
  const html = er.renderDirectory(path.join(CORPUS, 'render-matrix-pass'), {}).html;
  assert.ok([...html].every((character) => character.charCodeAt(0) < 128), 'a report with English free text is plain ASCII');
  for (const heading of ['<html lang="en">', '<h1>Evidence report</h1>', '<h2>Coverage</h2>', '<h2>Steps</h2>', '<h2>Signals</h2>', '<h2>Consent</h2>', '<h2>Limitations</h2>', '<h2>Resources</h2>', '<strong>Expected:</strong>', '<strong>Observed:</strong>']) {
    assert.ok(html.includes(heading), heading);
  }
  const empty = er.renderDirectory(path.join(CORPUS, 'render-stopped-in-setup'), {}).html;
  for (const line of ['<p>No step was recorded.</p>', '<p>No signal was recorded.</p>', '<p>No consent record.</p>', 'Console: not checked']) {
    assert.ok(empty.includes(line), line);
  }
});

test('begin, add, step and render write a bundle that survives the deletion of the run directory', () => {
  const fx = fixture({ remote: 'https://github.com/example/demo.git' });
  const started = begin(fx);
  assert.match(started.id, er.ID_RE);
  addImage(fx, started.id);
  ok(call(fx, 'add', { report: started.id, kind: 'text', file: runFile(fx, 'console.txt', 'console: one warning\n') }, 'The console log of the save'));
  ok(call(fx, 'add', { report: started.id, kind: 'request', method: 'PUT', path: '/api/settings', status: '200' }));
  ok(call(fx, 'add', { report: started.id, kind: 'signal', source: 'console', class: 'warning' }, 'The locale picker uses a deprecated API'));
  ok(step(fx, started.id, { criteria: 'AC-001', evidence: 'e1,e2' }));
  ok(step(fx, started.id, { priority: 'P1', driver: 'api', criteria: 'AC-002', evidence: 'e3' }));
  fs.rmSync(fx.runDir, { recursive: true, force: true });
  const rendered = ok(call(fx, 'render', { report: started.id, verdict: 'PASS', console: 'issues', network: 'clean' }, 'limitation: No mobile viewport was checked\nresource: A local dev server on port 3000\nconsent: http://localhost:3000 /settings asked\n'));
  assert.match(rendered.lines[rendered.lines.length - 1], /^Evidence report: .+index\.html$/);
  const manifest = manifestOf(started.bundle);
  assert.equal(manifest.verdict, 'PASS');
  assert.equal(manifest.run.host, 'claude-code');
  assert.equal(manifest.target.repository, 'example/demo');
  assert.deepEqual(manifest.coverage.criteria.map((criterion) => [criterion.id, criterion.state, criterion.driver, criterion.steps]), [['AC-001', 'pass', 'browser', [1]], ['AC-002', 'pass', 'api', [2]]]);
  assert.deepEqual(Object.keys(manifest.evidence), ['e1', 'e2', 'e3', 'e4']);
  for (const entry of Object.values(manifest.files)) assert.ok(fs.statSync(path.join(started.bundle, entry.name)).isFile());
  const everything = [fs.readFileSync(path.join(started.bundle, 'manifest.json'), 'utf8'), fs.readFileSync(path.join(started.bundle, 'index.html'), 'utf8')].join('\n');
  assert.ok(!everything.includes(fx.runDir), 'the bundle names no path inside the run directory');
  assert.ok(!everything.includes('verify-feature-runs'));
  assert.deepEqual(er.checkManifest(manifest, er.bundleReader(started.bundle), { inScope: ['AC-001', 'AC-002'] }), []);
});

test('add accepts only a regular file inside the run directory, named by an absolute normalized path', () => {
  const fx = fixture();
  const { id } = begin(fx);
  const inside = runFile(fx, 'shot.png', png(4, 3));
  const outside = path.join(fx.root, 'outside.png');
  fs.writeFileSync(outside, png(4, 3, 2));
  refused(call(fx, 'add', { report: id, kind: 'image', file: outside }, 'caption'), /lies outside the run directory/);
  fs.mkdirSync(path.join(fx.runDir, 'folder'));
  refused(call(fx, 'add', { report: id, kind: 'image', file: path.join(fx.runDir, 'folder') }, 'caption'), /not a regular file/);
  refused(call(fx, 'add', { report: id, kind: 'image', file: `${fx.runDir}/folder/../shot.png` }, 'caption'), /normalized path/, 2);
  refused(call(fx, 'add', { report: id, kind: 'image', file: 'shot.png' }, 'caption'), /absolute path/, 2);
  refused(call(fx, 'add', { report: id, kind: 'image', file: path.join(fx.runDir, 'missing.png') }, 'caption'), /does not exist/);
  ok(call(fx, 'add', { report: id, kind: 'image', file: inside }, 'caption'));
});

test('add refuses a symlink, a hard link, a file reached through a linked directory and a FIFO', { skip: NOT_ON_WINDOWS }, () => {
  const fx = fixture();
  const { id } = begin(fx);
  const inside = runFile(fx, 'shot.png', png(4, 3));
  const link = path.join(fx.runDir, 'link.png');
  fs.symlinkSync(inside, link);
  refused(call(fx, 'add', { report: id, kind: 'image', file: link }, 'caption'), /is a symlink/);
  const hard = path.join(fx.runDir, 'hard.png');
  fs.linkSync(runFile(fx, 'linked.png', png(4, 3, 3)), hard);
  refused(call(fx, 'add', { report: id, kind: 'image', file: hard }, 'caption'), /more than one link/);
  const away = tempDir('away');
  fs.writeFileSync(path.join(away, 'shot.png'), png(4, 3, 4));
  fs.symlinkSync(away, path.join(fx.runDir, 'linked-dir'));
  refused(call(fx, 'add', { report: id, kind: 'image', file: path.join(fx.runDir, 'linked-dir', 'shot.png') }, 'caption'), /runs through a symlink/);
  const fifo = path.join(fx.runDir, 'pipe.png');
  if (childProcess.spawnSync('mkfifo', [fifo]).status === 0) {
    refused(call(fx, 'add', { report: id, kind: 'image', file: fifo }, 'caption'), /not a regular file/);
  }
});

test('begin accepts only a run directory inside the work tree that git ignores, outside .git and apart from the store', (t) => {
  const fx = fixture();
  const outsideTree = [`the run directory must lie inside the project's work tree ${fx.root}`];
  assert.deepEqual(refused(call(fx, 'begin', { 'run-dir': tempDir('elsewhere'), drivers: 'browser' }, FEATURE), /^the run directory must lie inside the project's work tree /).errors, outsideTree);
  assert.deepEqual(refused(call(fx, 'begin', { 'run-dir': path.join(fx.root, 'missing'), drivers: 'browser' }, FEATURE), /does not exist/).errors, [`the run directory ${path.join(fx.root, 'missing')} does not exist`]);
  assert.deepEqual(refused(call(fx, 'begin', { 'run-dir': fx.root, drivers: 'browser' }, FEATURE), /^the run directory must lie inside the project's work tree /).errors, outsideTree);
  const source = path.join(fx.root, 'src');
  fs.mkdirSync(source);
  refused(call(fx, 'begin', { 'run-dir': source, drivers: 'browser' }, FEATURE), /git does not ignore the run directory .+, so its captures could be committed and every capture would move the tree fingerprint; have git ignore src\/, for example with the line \/src\/ in/);
  fs.writeFileSync(path.join(source, 'app.js'), 'export {};\n');
  git(fx.root, 'add', 'src/app.js');
  git(fx.root, 'commit', '-q', '-m', 'add a tracked source file');
  refused(call(fx, 'begin', { 'run-dir': source, drivers: 'browser' }, FEATURE), /^git does not ignore the run directory .+, so its captures could be committed and every capture would move the tree fingerprint; create it under \.zensu\/verify-feature-runs\/ at the top of the work tree, which git ignores$/);
  const sourceShots = path.join(source, 'shots');
  fs.mkdirSync(sourceShots);
  refused(call(fx, 'begin', { 'run-dir': sourceShots, drivers: 'browser' }, FEATURE), /; have git ignore src\/shots\/, for example with the line \/src\/shots\/ in the repository's \.gitignore$/);
  const captureRun = path.join(fx.root, 'captures', 'r1');
  fs.mkdirSync(captureRun, { recursive: true });
  refused(call(fx, 'begin', { 'run-dir': captureRun, drivers: 'browser' }, FEATURE), /; have git ignore captures\/, for example with the line \/captures\/ in the repository's \.gitignore$/);
  fs.writeFileSync(path.join(fx.root, 'captures', 'notes.md'), 'kept beside the run\n');
  refused(call(fx, 'begin', { 'run-dir': captureRun, drivers: 'browser' }, FEATURE), /; have git ignore captures\/r1\/, for example with the line \/captures\/r1\/ in the repository's \.gitignore$/);
  const bracket = path.join(fx.root, 'shots[1]');
  fs.mkdirSync(bracket);
  refused(call(fx, 'begin', { 'run-dir': bracket, drivers: 'browser' }, FEATURE), /; have git ignore shots\[1\]\/, for example with the line \/shots\\\[1\]\/ in the repository's \.gitignore$/);
  fs.appendFileSync(path.join(fx.root, '.gitignore'), '/shots\\[1]/\n');
  ok(call(fx, 'begin', { 'run-dir': bracket, drivers: 'browser' }, FEATURE));
  if (process.platform !== 'win32') {
    const tabbed = path.join(fx.root, 'tab\there');
    fs.mkdirSync(tabbed);
    refused(call(fx, 'begin', { 'run-dir': tabbed, drivers: 'browser' }, FEATURE), /^git does not ignore the run directory .+, so its captures could be committed and every capture would move the tree fingerprint; create it under \.zensu\/verify-feature-runs\/ at the top of the work tree, which git ignores$/);
    const colon = path.join(fx.root, ':shots');
    fs.mkdirSync(colon);
    fs.appendFileSync(path.join(fx.root, '.gitignore'), '/shots/\n');
    refused(call(fx, 'begin', { 'run-dir': colon, drivers: 'browser' }, FEATURE), /; have git ignore :shots\/, for example with the line \/:shots\/ in the repository's \.gitignore$/);
    fs.appendFileSync(path.join(fx.root, '.gitignore'), '/:shots/\n');
    ok(call(fx, 'begin', { 'run-dir': colon, drivers: 'browser' }, FEATURE));
  }
  const beginRow = fs.readFileSync(path.join(ROOT, 'docs', 'configuration.md'), 'utf8').split('\n').find((line) => line.startsWith('| `--report-begin` |'));
  assert.ok(beginRow.includes("which must be a physical directory inside the project's work tree, or inside the project root for a project outside git, that lies outside `.git` and that the work tree holding it, if any, ignores, so no capture can be committed or move the tree fingerprint."), beginRow);
  assert.ok(beginRow.includes("The refusal suggests an ignore line anchored at the top of the work tree that holds the run directory, with `\\`, `*`, `?` and `[` escaped: for the run directory's parent when it lies below that top, neither is nor holds the project root, is not `.zensu` at the top of that work tree or of the project root, and holds nothing git tracks and, unless it is `.zensu/verify-feature-runs/` at the top of that work tree or of the project root, no untracked, unignored file outside the run directory, else for the run directory itself when it neither is nor holds the project root, is not that `.zensu`, and holds nothing git tracks. When neither qualifies or the spelling holds a control character, which gets no line, and for a run directory inside `.git` or at the top of a work tree, it asks for a run directory under `.zensu/verify-feature-runs/` at the top of the project's work tree and says whether git ignores that directory (or, when its probe fails with anything but exit status 1, that this could not be determined and why), or, for a project outside git, under `.zensu/verify-feature-runs/` in the project root, which lies outside git. When `.zensu` or `.zensu/verify-feature-runs/` there is a symbolic link, which no run directory may run through, or is not a directory, it says so instead and asks for a directory in its place or for a run directory elsewhere, and a run directory at or below that entry that does not exist or runs through the link gets the same remedy after its refusal. Inside git, the replacement needs the line `/.zensu/verify-feature-runs/` unless git already ignores that directory, and elsewhere means another directory of the work tree that git ignores; for a project outside git, elsewhere means another directory of the project root that lies outside every git work tree. No refusal asks git to ignore all of `.zensu`, because a repository may commit `.zensu/plans/` and `.zensu/logs/`."), beginRow);
  refused(call(fx, 'begin', { 'run-dir': path.join(fx.root, '.git'), drivers: 'browser' }, FEATURE), /^the run directory .+ lies inside \.git; create it under \.zensu\/verify-feature-runs\/ at the top of the work tree, which git ignores$/);
  refused(call(fx, 'begin', { 'run-dir': path.join(fx.root, '.git', 'objects'), drivers: 'browser' }, FEATURE), /lies inside \.git/);
  if (process.platform !== 'win32') {
    const linkedRoot = repo({ label: 'linked' });
    fs.symlinkSync(tempDir('linked-target'), path.join(linkedRoot, '.zensu'));
    const linked = fixture({ root: linkedRoot });
    const throughLink = "; \\.zensu\\/verify-feature-runs\\/ cannot hold it, because \\.zensu at the top of the work tree is a symbolic link; replace that link with a directory and, unless git already ignores \\.zensu\\/verify-feature-runs\\/, add the line \\/\\.zensu\\/verify-feature-runs\\/ to the repository's \\.gitignore, or create the run directory in another directory of the work tree that git ignores$";
    refused(call(linked, 'begin', { 'run-dir': linked.runDir, drivers: 'browser' }, FEATURE), new RegExp(`^the run directory .+ runs through a symlink; pass its physical path${throughLink}`));
    refused(call(linked, 'begin', { 'run-dir': fs.realpathSync.native(linked.runDir), drivers: 'browser' }, FEATURE), /^the run directory must lie inside the project's work tree /);
    const danglingRoot = repo({ label: 'dangling' });
    fs.symlinkSync(path.join(tempDir('gone'), 'missing'), path.join(danglingRoot, '.zensu'));
    refused(call({ ...linked, root: danglingRoot }, 'begin', { 'run-dir': path.join(danglingRoot, '.zensu', 'verify-feature-runs', 'r1'), drivers: 'browser' }, FEATURE), new RegExp(`^the run directory .+ does not exist${throughLink}`));
    refused(call(linked, 'begin', { 'run-dir': path.join(linkedRoot, '.git'), drivers: 'browser' }, FEATURE), new RegExp(`^the run directory .+ lies inside \\.git${throughLink}`));
    const linkedNested = path.join(linkedRoot, 'nested');
    fs.mkdirSync(linkedNested);
    git(linkedNested, 'init', '-q');
    refused(call(linked, 'begin', { 'run-dir': linkedNested, drivers: 'browser' }, FEATURE), new RegExp(`^the run directory .+ is the top of a git work tree, which that work tree cannot ignore${throughLink}`));
    const linkedSource = path.join(linkedRoot, 'src');
    fs.mkdirSync(linkedSource);
    fs.writeFileSync(path.join(linkedSource, 'app.js'), 'export {};\n');
    git(linkedRoot, 'add', 'src/app.js');
    refused(call(linked, 'begin', { 'run-dir': linkedSource, drivers: 'browser' }, FEATURE), new RegExp(`^git does not ignore the run directory .+, so its captures could be committed and every capture would move the tree fingerprint${throughLink}`));
    const deepRoot = repo({ label: 'deep' });
    fs.mkdirSync(path.join(deepRoot, '.zensu'));
    fs.symlinkSync(tempDir('deep-target'), path.join(deepRoot, '.zensu', 'verify-feature-runs'));
    refused(call(fixture({ root: deepRoot }), 'begin', { 'run-dir': path.join(deepRoot, '.git'), drivers: 'browser' }, FEATURE), /^the run directory .+ lies inside \.git; \.zensu\/verify-feature-runs\/ cannot hold it, because \.zensu\/verify-feature-runs at the top of the work tree is a symbolic link; replace that link with a directory and, unless git already ignores \.zensu\/verify-feature-runs\/, add the line \/\.zensu\/verify-feature-runs\/ to the repository's \.gitignore, or create the run directory in another directory of the work tree that git ignores$/);
    const looseRoot = tempDir('loose');
    fs.symlinkSync(tempDir('loose-target'), path.join(looseRoot, '.zensu'));
    const looseInner = path.join(looseRoot, 'app');
    fs.mkdirSync(looseInner);
    git(looseInner, 'init', '-q');
    const loose = fixture({ root: looseRoot });
    const looseLink = '; \\.zensu\\/verify-feature-runs\\/ cannot hold it, because \\.zensu in the project root is a symbolic link; replace that link with a directory, or create the run directory in another directory of the project root that lies outside every git work tree$';
    refused(call(loose, 'begin', { 'run-dir': loose.runDir, drivers: 'browser' }, FEATURE), new RegExp(`^the run directory .+ runs through a symlink; pass its physical path${looseLink}`));
    refused(call(loose, 'begin', { 'run-dir': path.join(looseInner, '.git'), drivers: 'browser' }, FEATURE), new RegExp(`^the run directory .+ lies inside \\.git${looseLink}`));
    refused(call(loose, 'begin', { 'run-dir': looseInner, drivers: 'browser' }, FEATURE), new RegExp(`^the run directory .+ is the top of a git work tree, which that work tree cannot ignore${looseLink}`));
    const looseSource = path.join(looseInner, 'src');
    fs.mkdirSync(looseSource);
    fs.writeFileSync(path.join(looseSource, 'app.js'), 'export {};\n');
    git(looseInner, 'add', 'src/app.js');
    refused(call(loose, 'begin', { 'run-dir': looseSource, drivers: 'browser' }, FEATURE), new RegExp(`^git does not ignore the run directory .+, so its captures could be committed${looseLink}`));
  }
  const notDirectory = (entry) => `; .zensu/verify-feature-runs/ cannot hold it, because ${entry} at the top of the work tree is not a directory; replace it with a directory and, unless git already ignores .zensu/verify-feature-runs/, add the line /.zensu/verify-feature-runs/ to the repository's .gitignore, or create the run directory in another directory of the work tree that git ignores`;
  const plain = fixture({ root: repo({ label: 'plain' }) });
  fs.rmSync(path.join(plain.root, '.zensu'), { recursive: true });
  fs.writeFileSync(path.join(plain.root, '.zensu'), 'not a directory\n');
  assert.deepEqual(refused(call(plain, 'begin', { 'run-dir': plain.runDir, drivers: 'browser' }, FEATURE), /does not exist/).errors, [`the run directory ${plain.runDir} does not exist${notDirectory('.zensu')}`]);
  assert.deepEqual(refused(call(plain, 'begin', { 'run-dir': path.join(plain.root, '.git'), drivers: 'browser' }, FEATURE), /is not a directory/).errors, [`the run directory ${path.join(plain.root, '.git')} lies inside .git${notDirectory('.zensu')}`]);
  const plainSource = path.join(plain.root, 'src');
  fs.mkdirSync(plainSource);
  fs.writeFileSync(path.join(plainSource, 'app.js'), 'export {};\n');
  git(plain.root, 'add', 'src/app.js');
  assert.deepEqual(refused(call(plain, 'begin', { 'run-dir': plainSource, drivers: 'browser' }, FEATURE), /is not a directory/).errors, [`git does not ignore the run directory ${plainSource}, so its captures could be committed and every capture would move the tree fingerprint${notDirectory('.zensu')}`]);
  const flat = fixture({ root: repo({ label: 'flat' }) });
  fs.rmSync(path.dirname(flat.runDir), { recursive: true });
  fs.writeFileSync(path.dirname(flat.runDir), 'not a directory\n');
  assert.deepEqual(refused(call(flat, 'begin', { 'run-dir': flat.runDir, drivers: 'browser' }, FEATURE), /does not exist/).errors, [`the run directory ${flat.runDir} does not exist${notDirectory('.zensu/verify-feature-runs')}`]);
  const flatOther = path.join(flat.root, '.zensu', 'other', 'r1');
  assert.deepEqual(refused(call(flat, 'begin', { 'run-dir': flatOther, drivers: 'browser' }, FEATURE), /does not exist/).errors, [`the run directory ${flatOther} does not exist`]);
  assert.deepEqual(refused(call(flat, 'begin', { 'run-dir': path.join(flat.root, '.git'), drivers: 'browser' }, FEATURE), /is not a directory/).errors, [`the run directory ${path.join(flat.root, '.git')} lies inside .git${notDirectory('.zensu/verify-feature-runs')}`]);
  const plainLoose = fixture({ root: tempDir('plain-loose') });
  fs.rmSync(path.join(plainLoose.root, '.zensu'), { recursive: true });
  fs.writeFileSync(path.join(plainLoose.root, '.zensu'), 'not a directory\n');
  const plainInner = path.join(plainLoose.root, 'app');
  fs.mkdirSync(plainInner);
  git(plainInner, 'init', '-q');
  const looseNotDirectory = '; .zensu/verify-feature-runs/ cannot hold it, because .zensu in the project root is not a directory; replace it with a directory, or create the run directory in another directory of the project root that lies outside every git work tree';
  assert.deepEqual(refused(call(plainLoose, 'begin', { 'run-dir': path.join(plainInner, '.git'), drivers: 'browser' }, FEATURE), /is not a directory/).errors, [`the run directory ${path.join(plainInner, '.git')} lies inside .git${looseNotDirectory}`]);
  assert.deepEqual(refused(call(plainLoose, 'begin', { 'run-dir': plainInner, drivers: 'browser' }, FEATURE), /is not a directory/).errors, [`the run directory ${plainInner} is the top of a git work tree, which that work tree cannot ignore${looseNotDirectory}`]);
  assert.deepEqual(refused(call(plainLoose, 'begin', { 'run-dir': plainLoose.runDir, drivers: 'browser' }, FEATURE), /does not exist/).errors, [`the run directory ${plainLoose.runDir} does not exist${looseNotDirectory}`]);
  const bare = fixture({ root: repo({ label: 'bare', ignore: 'node_modules/\n' }) });
  const bareRunRoot = path.dirname(bare.runDir);
  assert.deepEqual(refused(call(bare, 'begin', { 'run-dir': bareRunRoot, drivers: 'browser' }, FEATURE), /does not ignore/).errors, [`git does not ignore the run directory ${bareRunRoot}, so its captures could be committed; have git ignore .zensu/verify-feature-runs/, for example with the line /.zensu/verify-feature-runs/ in the repository's .gitignore`]);
  const bareChild = path.join(bare.root, '.zensu', 'shots');
  fs.mkdirSync(bareChild);
  assert.deepEqual(refused(call(bare, 'begin', { 'run-dir': bareChild, drivers: 'browser' }, FEATURE), /does not ignore/).errors, [`git does not ignore the run directory ${bareChild}, so its captures could be committed; have git ignore .zensu/shots/, for example with the line /.zensu/shots/ in the repository's .gitignore`]);
  const bareZensu = path.join(bare.root, '.zensu');
  assert.deepEqual(refused(call(bare, 'begin', { 'run-dir': bareZensu, drivers: 'browser' }, FEATURE), /does not ignore/).errors, [`git does not ignore the run directory ${bareZensu}, so its captures could be committed; create it under .zensu/verify-feature-runs/ at the top of the work tree and have git ignore that directory, for example with the line /.zensu/verify-feature-runs/ in the repository's .gitignore`]);
  const monoTop = repo({ label: 'mono-zensu', ignore: 'node_modules/\n' });
  const site = fixture({ root: path.join(monoTop, 'apps', 'site') });
  const notIgnored = (run, remedy) => [`git does not ignore the run directory ${run}, so its captures could be committed; ${remedy}`];
  const siteShots = path.join(site.root, '.zensu', 'shots');
  fs.mkdirSync(siteShots);
  assert.deepEqual(refused(call(site, 'begin', { 'run-dir': siteShots, drivers: 'browser' }, FEATURE), /does not ignore/).errors, notIgnored(siteShots, "have git ignore apps/site/.zensu/shots/, for example with the line /apps/site/.zensu/shots/ in the repository's .gitignore"));
  const siteRunRoot = path.dirname(site.runDir);
  assert.deepEqual(refused(call(site, 'begin', { 'run-dir': siteRunRoot, drivers: 'browser' }, FEATURE), /does not ignore/).errors, notIgnored(siteRunRoot, "have git ignore apps/site/.zensu/verify-feature-runs/, for example with the line /apps/site/.zensu/verify-feature-runs/ in the repository's .gitignore"));
  const siteZensu = path.join(site.root, '.zensu');
  assert.deepEqual(refused(call(site, 'begin', { 'run-dir': siteZensu, drivers: 'browser' }, FEATURE), /does not ignore/).errors, notIgnored(siteZensu, "create it under .zensu/verify-feature-runs/ at the top of the work tree and have git ignore that directory, for example with the line /.zensu/verify-feature-runs/ in the repository's .gitignore"));
  const topShots = path.join(monoTop, '.zensu', 'shots');
  fs.mkdirSync(topShots, { recursive: true });
  assert.deepEqual(refused(call(site, 'begin', { 'run-dir': topShots, drivers: 'browser' }, FEATURE), /does not ignore/).errors, notIgnored(topShots, "have git ignore .zensu/shots/, for example with the line /.zensu/shots/ in the repository's .gitignore"));
  const gitRead = evr.git;
  const slowProbe = t.mock.method(evr, 'git', (root, args, options) => (args[0] === 'check-ignore' && args.includes('./.zensu/verify-feature-runs/') ? { ok: false, code: 'ETIMEDOUT', reason: 'git timed out' } : gitRead(root, args, options)));
  assert.deepEqual(refused(call(fx, 'begin', { 'run-dir': path.join(fx.root, '.git'), drivers: 'browser' }, FEATURE), /could not be determined \(git timed out\)$/).errors, [`the run directory ${path.join(fx.root, '.git')} lies inside .git; create it under .zensu/verify-feature-runs/ at the top of the work tree; whether git ignores that directory could not be determined (git timed out)`]);
  slowProbe.mock.restore();
  const runProbe = t.mock.method(evr, 'git', (root, args, options) => (args[0] === 'check-ignore' && args.includes('./.zensu/verify-feature-runs/r1/') ? { ok: false, status: 128, reason: 'git check-ignore failed: fatal: probe refused' } : gitRead(root, args, options)));
  assert.deepEqual(refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser' }, FEATURE), /could not be determined/, 2).errors, ['whether git ignores the run directory could not be determined (git check-ignore failed: fatal: probe refused)']);
  runProbe.mock.restore();
  const store = path.join(fx.root, 'reports');
  fs.writeFileSync(path.join(fx.root, '.gitignore'), '.zensu/\nreports/\n');
  refused(call(fx, 'begin', { 'run-dir': path.join(store), drivers: 'browser' }, FEATURE, { config: { user: { dir: store } } }), /does not exist|must not overlap the report store/);
  fs.mkdirSync(path.join(store, 'run'), { recursive: true });
  refused(call(fx, 'begin', { 'run-dir': path.join(store, 'run'), drivers: 'browser' }, FEATURE, { config: { user: { dir: store } } }), /must not overlap the report store/);
  ok(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser' }, FEATURE));
});

test('the run directory is judged by the work tree that holds it, and the refusal names its stable parent', () => {
  const fx = fixture();
  fs.writeFileSync(path.join(fx.root, '.gitignore'), '.zensu/\n.claude/worktrees/\n');
  const nested = path.join(fx.root, '.claude', 'worktrees', 'wt');
  git(fx.root, 'worktree', 'add', '-q', nested, '-b', 'wt');
  const shots = path.join(nested, 'shots');
  fs.mkdirSync(shots);
  refused(call(fx, 'begin', { 'run-dir': shots, drivers: 'browser' }, FEATURE), /^git does not ignore the run directory .+, so its captures could be committed; have git ignore shots\/, for example with the line \/shots\/ in the repository's \.gitignore$/);
  refused(call(fx, 'begin', { 'run-dir': nested, drivers: 'browser' }, FEATURE), /^the run directory .+ is the top of a git work tree, which that work tree cannot ignore; create it under \.zensu\/verify-feature-runs\/ at the top of the work tree, which git ignores$/);
  const outer = fixture();
  const pkg = path.join(outer.root, 'pkg');
  fs.mkdirSync(pkg);
  const sub = fixture({ root: pkg });
  const logs = path.join(outer.root, 'logs');
  fs.mkdirSync(logs);
  refused(call(sub, 'begin', { 'run-dir': logs, drivers: 'browser' }, FEATURE), /^git does not ignore the run directory .+, so its captures could be committed; have git ignore logs\//);
  refused(call(sub, 'begin', { 'run-dir': pkg, drivers: 'browser' }, FEATURE), /^git does not ignore the run directory .+, so its captures could be committed and every capture would move the tree fingerprint; create it under \.zensu\/verify-feature-runs\/ at the top of the work tree, which git ignores$/);
  const web = path.join(outer.root, 'apps', 'web');
  fs.mkdirSync(web, { recursive: true });
  const deep = fixture({ root: web });
  refused(call(deep, 'begin', { 'run-dir': path.join(outer.root, 'apps'), drivers: 'browser' }, FEATURE), /^git does not ignore the run directory .+, so its captures could be committed; create it under \.zensu\/verify-feature-runs\/ at the top of the work tree, which git ignores$/);
  const namesake = path.join(outer.root, 'web');
  fs.mkdirSync(namesake);
  refused(call(deep, 'begin', { 'run-dir': namesake, drivers: 'browser' }, FEATURE), /^git does not ignore the run directory .+, so its captures could be committed; have git ignore web\/, for example with the line \/web\/ in the repository's \.gitignore$/);
  fs.appendFileSync(path.join(outer.root, '.gitignore'), '/web/\n');
  ok(call(deep, 'begin', { 'run-dir': namesake, drivers: 'browser' }, FEATURE));
  assert.equal(childProcess.spawnSync('git', ['check-ignore', '-q', '--', 'apps/web/'], { cwd: outer.root, env: evr.gitEnvironment() }).status, 1);
  const pictures = path.join(pkg, 'pictures');
  fs.mkdirSync(pictures);
  refused(call(sub, 'begin', { 'run-dir': pictures, drivers: 'browser' }, FEATURE), /, so its captures could be committed and every capture would move the tree fingerprint; have git ignore pkg\/pictures\/, for example with the line \/pkg\/pictures\/ in the repository's \.gitignore$/);
  const beside = path.join(outer.root, 'shared', 'runs');
  fs.mkdirSync(beside, { recursive: true });
  refused(call(sub, 'begin', { 'run-dir': beside, drivers: 'browser' }, FEATURE), /, so its captures could be committed; have git ignore shared\/, for example with the line \/shared\/ in the repository's \.gitignore$/);
  ok(call(sub, 'begin', { 'run-dir': sub.runDir, drivers: 'browser' }, FEATURE));
  const kept = path.join(nested, '.zensu', 'verify-feature-runs', 'r1');
  fs.mkdirSync(kept, { recursive: true });
  ok(call(fx, 'begin', { 'run-dir': kept, drivers: 'browser' }, FEATURE));
  const plain = fixture({ root: tempDir('plain-holder') });
  const inner = path.join(plain.root, 'app');
  fs.mkdirSync(inner);
  git(inner, 'init', '-q');
  fs.writeFileSync(path.join(inner, '.gitignore'), '.zensu/\n');
  const captures = path.join(inner, 'captures');
  fs.mkdirSync(captures);
  refused(call(plain, 'begin', { 'run-dir': captures, drivers: 'api' }, FEATURE), /git does not ignore the run directory .+ have git ignore captures\//);
  const innerSource = path.join(inner, 'src');
  fs.mkdirSync(innerSource);
  fs.writeFileSync(path.join(innerSource, 'app.js'), 'export {};\n');
  git(inner, 'add', 'src/app.js');
  refused(call(plain, 'begin', { 'run-dir': innerSource, drivers: 'api' }, FEATURE), /^git does not ignore the run directory .+, so its captures could be committed; create it under \.zensu\/verify-feature-runs\/ in the project root, which lies outside git$/);
  refused(call(plain, 'begin', { 'run-dir': inner, drivers: 'api' }, FEATURE), /^the run directory .+ is the top of a git work tree, which that work tree cannot ignore; create it under \.zensu\/verify-feature-runs\/ in the project root, which lies outside git$/);
  refused(call(plain, 'begin', { 'run-dir': path.join(inner, '.git'), drivers: 'api' }, FEATURE), /^the run directory .+ lies inside \.git; create it under \.zensu\/verify-feature-runs\/ in the project root, which lies outside git$/);
  refused(call(plain, 'begin', { 'run-dir': tempDir('elsewhere'), drivers: 'api' }, FEATURE), /^the run directory must lie inside the project root .+, which lies outside git$/);
  ok(call(plain, 'begin', { 'run-dir': plain.runDir, drivers: 'api' }, FEATURE));
  const trail = fixture({ ignore: '.zensu/state/\n.zensu/reviews/\n' });
  refused(call(trail, 'begin', { 'run-dir': trail.runDir, drivers: 'browser' }, FEATURE), /^git does not ignore the run directory .+, so its captures could be committed; have git ignore \.zensu\/verify-feature-runs\/, for example with the line \/\.zensu\/verify-feature-runs\/ in the repository's \.gitignore$/);
  fs.appendFileSync(path.join(trail.root, '.gitignore'), '.zensu/verify-feature-runs/\n');
  ok(call(trail, 'begin', { 'run-dir': trail.runDir, drivers: 'browser' }, FEATURE));
  const mono = fixture({ ignore: 'node_modules/\n' });
  const site = path.join(mono.root, 'apps', 'site');
  fs.mkdirSync(site, { recursive: true });
  const app = fixture({ root: site });
  const leaf = path.join(mono.root, '.zensu', 'verify-feature-runs', 'k3x9');
  fs.mkdirSync(leaf, { recursive: true });
  fs.writeFileSync(path.join(mono.runDir, 'resources.json'), '{}\n');
  refused(call(app, 'begin', { 'run-dir': leaf, drivers: 'browser' }, FEATURE), /^git does not ignore the run directory .+, so its captures could be committed; have git ignore \.zensu\/verify-feature-runs\/, for example with the line \/\.zensu\/verify-feature-runs\/ in the repository's \.gitignore$/);
  refused(call(app, 'begin', { 'run-dir': site, drivers: 'browser' }, FEATURE), /^git does not ignore the run directory .+, so its captures could be committed and every capture would move the tree fingerprint; create it under \.zensu\/verify-feature-runs\/ at the top of the work tree and have git ignore that directory, for example with the line \/\.zensu\/verify-feature-runs\/ in the repository's \.gitignore$/);
  const appLeaf = path.join(site, '.zensu', 'verify-feature-runs', 'k4y2');
  fs.mkdirSync(appLeaf, { recursive: true });
  fs.writeFileSync(path.join(app.runDir, 'resources.json'), '{}\n');
  refused(call(app, 'begin', { 'run-dir': appLeaf, drivers: 'browser' }, FEATURE), /^git does not ignore the run directory .+, so its captures could be committed; have git ignore apps\/site\/\.zensu\/verify-feature-runs\/, for example with the line \/apps\/site\/\.zensu\/verify-feature-runs\/ in the repository's \.gitignore$/);
});

test('add, step and render refuse a report begun in another worktree of the same clone, while export stays open', () => {
  const fx = fixture();
  const { id } = begin(fx);
  const sibling = path.join(tempDir('sibling'), 'wt');
  git(fx.root, 'worktree', 'add', '-q', sibling, '-b', 'sibling');
  const moved = { ...fx, root: fs.realpathSync.native(sibling) };
  const request = { report: id, kind: 'request', method: 'GET', path: '/', status: '200' };
  refused(call(moved, 'add', request), /^report vr1_[^ ]+ was begun in the project root .+, but this session's project root is .+; begin a new report there$/);
  refused(step(moved, id), /was begun in the project root/);
  refused(call(moved, 'render', { report: id, verdict: 'PARTIAL' }), /was begun in the project root/);
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL' }));
  ok(call(moved, 'export', { report: id }));
});

test('begin refuses a run directory named through a symlink', { skip: NOT_ON_WINDOWS }, () => {
  const fx = fixture();
  const link = path.join(fx.root, 'run-link');
  fs.symlinkSync(fx.runDir, link);
  refused(call(fx, 'begin', { 'run-dir': link, drivers: 'browser' }, FEATURE), /is a symlink/);
});

test('add sniffs every file type from its content', () => {
  const pngBytes = png(5, 2);
  assert.deepEqual(er.sniff(pngBytes), { type: 'image/png', width: 5, height: 2 });
  assert.deepEqual(er.sniff(corpusFile('render-chain-partial', 'webp')), { type: 'image/webp', width: 6, height: 4 });
  assert.match(er.sniff(corpusFile('refuse-lossy-webp', 'webp')).error, /lossy WebP/);
  const animated = riff([['VP8X', Buffer.from([0x02, 0, 0, 0, 5, 0, 0, 3, 0, 0])], ['ANIM', Buffer.alloc(6)]]);
  assert.match(er.sniff(animated).error, /animated WebP/);
  const truncated = corpusFile('render-chain-partial', 'webp').subarray(0, 40);
  assert.match(er.sniff(truncated).error, /container size/);
  assert.match(er.sniff(pngBytes.subarray(0, 16)).error, /IHDR/);
  assert.deepEqual(er.sniff(Buffer.from('one\ttwo\r\nthree\n')).type, 'text/plain');
  assert.match(er.sniff(Buffer.from([0xff, 0xfe, 0x00, 0x41])).error, /not a PNG, a lossless WebP or UTF-8 text/);
  assert.match(er.sniff(Buffer.from(`a${String.fromCharCode(7)}b`)).error, /control characters/);
  assert.match(er.sniff(Buffer.from(`a${String.fromCharCode(0x202e)}b`)).error, /control characters/);
  assert.match(er.sniff(Buffer.from('  <svg onload="x"></svg>')).error, /markup/);
  assert.match(er.sniff(Buffer.alloc(0)).error, /empty/);
  const fx = fixture();
  const { id } = begin(fx);
  ok(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, 'named.txt', pngBytes) }, 'A PNG whatever its name'));
  refused(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, 'text.png', 'plain text') }, 'caption'), /--kind image needs a PNG or a lossless WebP file/);
  refused(call(fx, 'add', { report: id, kind: 'text', file: runFile(fx, 'image.txt', png(2, 2, 9)) }, 'caption'), /--kind text needs a UTF-8 text file/);
  refused(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, 'lossy.webp', corpusFile('refuse-lossy-webp', 'webp')) }, 'caption'), /lossy WebP/);
  refused(call(fx, 'add', { report: id, kind: 'text', file: runFile(fx, 'page.html', '<html></html>') }, 'caption'), /markup/);
  const manifestFiles = JSON.parse(fs.readFileSync(path.join(repositoryDirectory(fx), `${id}.binding.json`), 'utf8')).files;
  assert.deepEqual(Object.values(manifestFiles).map((entry) => entry.name.split('.').pop()), ['png']);
});

test('a PNG is walked to IEND and a PNG or WebP drops its metadata chunks before it is stored', () => {
  const plain = png(5, 2);
  const withChunk = (type, data) => Buffer.concat([plain.subarray(0, 33), pngChunk(type, data), plain.subarray(33)]);
  const tagged = withChunk('tEXt', Buffer.from('Software\u0000Example capture tool', 'latin1'));
  const sniffed = er.sniff(tagged);
  assert.deepEqual([sniffed.type, sniffed.width, sniffed.height, sniffed.dropped], ['image/png', 5, 2, ['tEXt']]);
  assert.deepEqual(sniffed.clean(), plain);
  assert.deepEqual(er.sniff(withChunk('iDOT', Buffer.alloc(4))).dropped, ['iDOT']);
  assert.deepEqual(er.sniff(withChunk('eXIf', Buffer.from('MM'))).dropped, ['eXIf']);
  assert.match(er.sniff(Buffer.concat([plain, Buffer.from('appended text')])).error, /bytes after its IEND chunk/);
  assert.match(er.sniff(plain.subarray(0, plain.length - 12)).error, /no IEND chunk/);
  assert.match(er.sniff(plain.subarray(0, plain.length - 20)).error, /truncated|no IEND chunk/);
  assert.match(er.sniff(withChunk('acTL', Buffer.alloc(8))).error, /animated PNG/);
  assert.match(er.sniff(withChunk('ZZZZ', Buffer.alloc(1))).error, /unknown critical chunk ZZZZ/);
  const lossless = corpusFile('render-chain-partial', 'webp');
  assert.equal(lossless.toString('latin1', 12, 16), 'VP8L');
  const vp8l = lossless.subarray(20, 20 + lossless.readUInt32LE(16));
  const extended = riff([['VP8X', Buffer.from([0x0c, 0, 0, 0, 5, 0, 0, 3, 0, 0])], ['VP8L', vp8l], ['EXIF', Buffer.from('Exif data')], ['XMP ', Buffer.from('<x:xmpmeta/>')]]);
  const webp = er.sniff(extended);
  assert.deepEqual(webp.dropped, ['EXIF', 'XMP ']);
  const cleaned = webp.clean();
  assert.deepEqual(er.sniff(cleaned), { type: 'image/webp', width: 6, height: 4 });
  assert.equal(cleaned[20] & 0x0c, 0);
  const fx = fixture();
  const { id, bundle } = begin(fx);
  const added = ok(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, 'tagged.png', tagged) }, 'A capture whose tool wrote a text chunk'));
  assert.match(added.lines[0], /dropped the metadata chunks tEXt$/);
  const binding = JSON.parse(fs.readFileSync(path.join(repositoryDirectory(fx), `${id}.binding.json`), 'utf8'));
  const [sha, entry] = Object.entries(binding.files)[0];
  assert.equal(entry.source_sha256, crypto.createHash('sha256').update(tagged).digest('hex'));
  assert.deepEqual(fs.readFileSync(path.join(bundle, entry.name)), plain);
  assert.equal(sha, crypto.createHash('sha256').update(plain).digest('hex'));
  refused(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, 'trailing.png', Buffer.concat([plain, Buffer.from('appended text')])) }, 'A capture with a tail'), /bytes after its IEND chunk/);
  ok(step(fx, id, { criteria: 'AC-001', evidence: 'e1' }));
  ok(step(fx, id, { priority: 'P1', driver: 'api', criteria: 'AC-002' }));
  ok(call(fx, 'render', { report: id, verdict: 'PASS' }));
});

test('add checks the fixed protocol caps of 50 MiB per file and 2000 files per report', () => {
  assert.equal(er.LIMITS.maxFileBytes, 50 * 1024 * 1024);
  assert.equal(er.LIMITS.maxFiles, 2000);
  const fx = fixture();
  const { id } = begin(fx);
  const limits = { maxFileBytes: 200, maxFiles: 2, maxTextFileBytes: 16 };
  refused(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, 'big.png', png(40, 40, 1, true)) }, 'caption', { limits }), /above the cap of 200 bytes per file/);
  refused(call(fx, 'add', { report: id, kind: 'text', file: runFile(fx, 'long.txt', 'x'.repeat(20)) }, 'caption', { limits }), /at most 16 bytes/);
  const first = runFile(fx, 'one.png', png(2, 2, 1));
  ok(call(fx, 'add', { report: id, kind: 'image', file: first }, 'First', { limits }));
  ok(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, 'two.png', png(2, 2, 2)) }, 'Second', { limits }));
  refused(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, 'three.png', png(2, 2, 3)) }, 'Third', { limits }), /already holds 2 files, the cap per report/);
  ok(call(fx, 'add', { report: id, kind: 'image', file: first }, 'The first file again', { limits }));
  const binding = JSON.parse(fs.readFileSync(path.join(repositoryDirectory(fx), `${id}.binding.json`), 'utf8'));
  assert.equal(Object.keys(binding.files).length, 2);
  assert.equal(Object.keys(binding.evidence).length, 3);
});

test('the file, text and pixel caps hold at their edges', () => {
  const fx = fixture();
  const { id } = begin(fx);
  const image = png(4, 3, 7);
  const file = runFile(fx, 'edge.png', image);
  refused(call(fx, 'add', { report: id, kind: 'image', file }, 'One byte over the cap', { limits: { maxFileBytes: image.length - 1 } }), new RegExp(`above the cap of ${image.length - 1} bytes per file`));
  ok(call(fx, 'add', { report: id, kind: 'image', file }, 'Exactly at the cap', { limits: { maxFileBytes: image.length } }));
  refused(call(fx, 'add', { report: id, kind: 'text', file: runFile(fx, 'seventeen.txt', 'abcdefghijklmnopq') }, 'Seventeen bytes', { limits: { maxTextFileBytes: 16 } }), /at most 16 bytes/);
  ok(call(fx, 'add', { report: id, kind: 'text', file: runFile(fx, 'sixteen.txt', 'abcdefghijklmnop') }, 'Sixteen bytes', { limits: { maxTextFileBytes: 16 } }));
  const pixels = runFile(fx, 'pixels.png', png(4, 3, 8));
  const fresh = begin(fx);
  refused(call(fx, 'add', { report: fresh.id, kind: 'image', file: pixels }, 'Twelve pixels', { limits: { maxPixels: 11 } }), /more than 11 pixels/);
  ok(call(fx, 'add', { report: fresh.id, kind: 'image', file: pixels }, 'Twelve pixels', { limits: { maxPixels: 12 } }));
});

test('add refuses a file that would take the report past evidence.report.maxBytes', () => {
  const fx = fixture();
  const { id } = begin(fx);
  const first = png(4, 3, 1);
  const second = png(4, 3, 2);
  const cap = first.length + second.length - 1;
  ok(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, 'one.png', first) }, 'First', { config: { user: { maxBytes: cap } } }));
  refused(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, 'two.png', second) }, 'Second', { config: { user: { maxBytes: cap } } }), new RegExp(`would hold ${first.length + second.length} bytes of files, above evidence\\.report\\.maxBytes of ${cap}; raise evidence\\.report\\.maxBytes in the user configuration`));
  ok(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, 'again.png', first) }, 'The first file again', { config: { user: { maxBytes: cap } } }));
  ok(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, 'two.png', second) }, 'Second', { config: { user: { maxBytes: cap + 1 } } }));
});

test('every text field passes the secret screen and the path redaction', () => {
  const fx = fixture();
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser' }, `feature: Use ${FAKE_TOKEN} to log in\n`), /secret pattern/);
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser' }, `feature: A feature\nAC-001: Log in with ${FAKE_TOKEN}\n`), /secret pattern/);
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser' }, `feature: A feature ${ALLOW}\n`), /marker/);
  const { id, bundle } = begin(fx);
  const image = runFile(fx, 'shot.png', png(4, 3));
  refused(call(fx, 'add', { report: id, kind: 'image', file: image }, `The token ${FAKE_TOKEN} is shown`), /secret pattern/);
  refused(call(fx, 'add', { report: id, kind: 'image', file: image }, `Shown ${ALLOW}`), /marker/);
  refused(call(fx, 'add', { report: id, kind: 'image', file: image }, ''), /caption on stdin is empty/);
  refused(call(fx, 'add', { report: id, kind: 'signal', source: 'console', class: 'error' }, `Bearer ${FAKE_TOKEN}`), /secret pattern/);
  ok(call(fx, 'add', { report: id, kind: 'image', file: image }, `Opened ${fx.root}/src/settings.tsx in the editor`));
  ok(step(fx, id, { criteria: 'AC-001', evidence: 'e1' }, `title: Read ${fx.home}/notes.txt\nexpected: The notes\nobserved: The notes at ${fx.root}/docs\n`));
  refused(step(fx, id, { criteria: 'AC-002' }, `title: A\nexpected: B\nobserved: The key ${FAKE_TOKEN}\n`), /secret pattern/);
  refused(call(fx, 'render', { report: id, verdict: 'PARTIAL' }, `limitation: The key ${FAKE_TOKEN} leaked\n`), /secret pattern/);
  refused(call(fx, 'render', { report: id, verdict: 'PARTIAL' }, `consent: http://localhost:3000 /invite/${FAKE_TOKEN} asked\n`), /route of a consent line matches a secret pattern/);
  refused(call(fx, 'render', { report: id, verdict: 'PARTIAL' }, `consent: http://localhost:3000 /x${ALLOW} asked\n`), /route of a consent line carries the .+ marker/);
  refused(step(fx, id, { criteria: 'AC-002' }, `title: A\nexpected: B\nobserved: ${SPLIT_KEY} =\n${SPLIT_VALUE}\n`), /observed text matches a secret pattern/);
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL' }, `limitation: Checked from ${fx.home}/work only\n`));
  const text = fs.readFileSync(path.join(bundle, 'manifest.json'), 'utf8') + fs.readFileSync(path.join(bundle, 'index.html'), 'utf8');
  assert.ok(!text.includes(fx.root), 'the project root is redacted');
  assert.ok(!text.includes(fx.home), 'the home directory is redacted');
  const manifest = manifestOf(bundle);
  assert.equal(manifest.evidence.e1.caption, 'Opened <project>/src/settings.tsx in the editor');
  assert.equal(manifest.steps[0].title, 'Read ~/notes.txt');
  assert.equal(manifest.sections.limitations[0], 'Checked from ~/work only');
});

test('free text enters only through stdin, never through an argument', () => {
  const freeText = ['caption', 'title', 'feature', 'expected', 'observed', 'message', 'limitation', 'resource', 'note', 'text', 'criterion'];
  for (const [verb, keys] of Object.entries(er.VERB_ARGUMENTS)) {
    for (const key of keys) assert.ok(!freeText.includes(key), `--report-${verb} takes --${key}`);
  }
  const fx = fixture();
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser', feature: 'x' }, FEATURE), /--feature is not an argument of --report-begin/, 2);
  const { id } = begin(fx);
  refused(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, 'a.png', png(2, 2)), caption: 'x' }, 'caption'), /--caption is not an argument of --report-add/, 2);
  refused(call(fx, 'step', { report: id, priority: 'P0', driver: 'browser', result: 'pass', title: 'x' }, FIELDS), /--title is not an argument of --report-step/, 2);
});

test('a text evidence file is screened and redacted before it is stored', () => {
  const fx = fixture();
  const { id } = begin(fx);
  const added = ok(call(fx, 'add', { report: id, kind: 'text', file: runFile(fx, 'log.txt', `GET ${fx.root}/api answered 200\nhome ${fx.home}/x\n`) }, 'The request log'));
  const binding = JSON.parse(fs.readFileSync(path.join(repositoryDirectory(fx), `${id}.binding.json`), 'utf8'));
  const [sha, entry] = Object.entries(binding.files)[0];
  const stored = fs.readFileSync(path.join(repositoryDirectory(fx), id, entry.name));
  assert.equal(stored.toString('utf8'), 'GET <project>/api answered 200\nhome ~/x\n');
  assert.equal(crypto.createHash('sha256').update(stored).digest('hex'), sha);
  assert.match(added.lines[0], /e1 added/);
  refused(call(fx, 'add', { report: id, kind: 'text', file: runFile(fx, 'secret.txt', `token=${FAKE_TOKEN}\n`) }, 'A log'), /secret pattern/);
  refused(call(fx, 'add', { report: id, kind: 'text', file: runFile(fx, 'allow.txt', `value ${ALLOW}\n`) }, 'A log'), /marker/);
  refused(call(fx, 'add', { report: id, kind: 'text', file: runFile(fx, 'lint.txt', `${fx.root}/src/a.ts\n  1:1 error\n`) }, 'The lint output'), /after the path redaction the text file is refused: the text is markup/);
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL' }));
});

test('the default store lies outside every git work tree and a store inside one is refused unless git ignores it', (t) => {
  const fx = fixture();
  begin(fx);
  const store = path.join(fx.root, 'reports');
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser' }, FEATURE, { config: { user: { dir: store } } }), /inside the git work tree .+ does not report it ignored/);
  fs.writeFileSync(path.join(fx.root, '.gitignore'), '.zensu/\nreports/\n');
  const accepted = ok(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser' }, FEATURE, { config: { user: { dir: store } } }));
  assert.equal(path.dirname(accepted.bundle), path.join(fs.realpathSync.native(store), er.STORE_VERSION, er.repositoryKey(fx.root)), 'a configured store holds the same versioned layout as the default one');
  assert.deepEqual(fs.readdirSync(store), [er.STORE_VERSION]);
  assert.equal(ok(call(fx, 'list', {}, '', { config: { user: { dir: store } } })).reports[0].id, accepted.id);
  const storeTop = path.join(fs.realpathSync.native(store), er.STORE_VERSION);
  const gitRead = evr.git;
  const storeProbe = t.mock.method(evr, 'git', (root, args, options) => (args[0] === 'check-ignore' && args.includes(`./reports/${er.STORE_VERSION}/`) ? { ok: false, code: 'ENOENT', reason: 'git unavailable (ENOENT)' } : gitRead(root, args, options)));
  assert.deepEqual(refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser' }, FEATURE, { config: { user: { dir: store } } }), /could not be determined/, 2).errors, ['whether git ignores the store could not be determined (git unavailable (ENOENT))']);
  storeProbe.mock.restore();
  const topRead = evr.workTreeTop;
  const storeTree = t.mock.method(evr, 'workTreeTop', (directory, limits) => (er.samePath(directory, storeTop) ? { top: null, reason: 'git timed out' } : topRead(directory, limits)));
  assert.deepEqual(refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser' }, FEATURE, { config: { user: { dir: store } } }), /could not be determined/, 2).errors, [`whether the store ${storeTop} lies in a git work tree could not be determined (git timed out)`]);
  storeTree.mock.restore();
  ok(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser' }, FEATURE, { config: { user: { dir: store } } }));
  const tracked = repo({ label: 'data-in-repo' });
  const data = path.join(tracked, 'plugin-data');
  fs.mkdirSync(data);
  const inside = fixture({ data });
  refused(call(inside, 'begin', { 'run-dir': inside.runDir, drivers: 'browser' }, FEATURE), /does not report it ignored/);
  assert.equal(er.storePlacement(tempDir('outside')).ok, true);
  assert.equal(er.storePlacement(tracked).ok, false);
  if (process.platform !== 'win32') {
    const colonStore = path.join(tracked, ':store');
    fs.mkdirSync(colonStore);
    fs.appendFileSync(path.join(tracked, '.gitignore'), '/store/\n');
    assert.equal(er.storePlacement(colonStore).ok, false);
    fs.appendFileSync(path.join(tracked, '.gitignore'), '/:store/\n');
    assert.equal(er.storePlacement(colonStore).ok, true);
  }
});

test('retention keeps the newest reports per repository and deletes the oldest first', () => {
  const fx = fixture();
  const ids = [];
  for (let index = 0; index < 4; index += 1) {
    const started = begin(fx, {}, FEATURE, { config: { user: { keep: 2 } }, now: () => 1790000000000 + index });
    idle(fx, started.id);
    ids.push(started.id);
    if (index >= 2) assert.ok(started.lines.some((line) => /retention removed 1 older report/.test(line)), started.lines.join('\n'));
  }
  const remaining = fs.readdirSync(repositoryDirectory(fx)).sort();
  assert.deepEqual(remaining, [ids[2], `${ids[2]}.binding.json`, ids[3], `${ids[3]}.binding.json`]);
});

test('retention holds the store under maxBytes across repositories, sparing the new report and a locked one', () => {
  const data = tempDir('shared-data');
  const first = fixture({ data, label: 'first' });
  const second = fixture({ data, label: 'second' });
  const reports = [];
  let clock = 1790000000000;
  for (const fx of [first, first, second]) {
    const started = begin(fx, {}, FEATURE, { now: () => clock });
    clock += 1;
    addImage(fx, started.id, `noise-${clock}.png`, png(100, 70, 1, true));
    idle(fx, started.id);
    reports.push(started);
  }
  assert.ok(footprint(reports[0], first) > 4096);
  const cap = footprint(reports[1], first) + footprint(reports[2], second) + 4096;
  const latest = begin(second, {}, FEATURE, { config: { user: { maxBytes: cap } }, now: () => clock });
  clock += 1;
  assert.ok(!fs.existsSync(path.join(repositoryDirectory(first), reports[0].id)), 'the oldest report is deleted first');
  assert.ok(fs.existsSync(path.join(repositoryDirectory(first), reports[1].id)));
  assert.ok(fs.existsSync(path.join(repositoryDirectory(second), reports[2].id)));
  assert.ok(fs.existsSync(latest.bundle));
  idle(second, latest.id);
  const holder = core.acquireExternalProcessLock({ ...lockOf(repositoryDirectory(first), reports[1].id), ownerPid: process.pid });
  const reachable = footprint(reports[1], first) + footprint(latest, second) + 256;
  const newest = begin(first, {}, FEATURE, { config: { user: { maxBytes: reachable } }, now: () => clock });
  core.releaseExternalProcessLock({ ...lockOf(repositoryDirectory(first), reports[1].id), ownerPid: process.pid, token: holder.token });
  clock += 1;
  assert.ok(fs.existsSync(newest.bundle), 'the report being written survives');
  assert.ok(fs.existsSync(path.join(repositoryDirectory(first), reports[1].id)), 'a locked report survives');
  assert.ok(!fs.existsSync(path.join(repositoryDirectory(second), reports[2].id)));
  assert.ok(!fs.existsSync(latest.bundle));
  idle(first, newest.id);
  const removable = begin(second, {}, FEATURE, { now: () => clock });
  clock += 1;
  idle(second, removable.id);
  const capped = begin(first, {}, FEATURE, { config: { user: { maxBytes: 1 } }, now: () => clock });
  assert.ok(fs.existsSync(removable.bundle), 'when the reports it must keep exceed the cap, the size pass deletes nothing');
  assert.ok(capped.lines.some((line) => /^zensu evidence report: retention deleted nothing for the size cap, because the reports it must keep \(this one, reports still being built and locked reports\) hold [0-9]+ bytes, above evidence\.report\.maxBytes of 1$/.test(line)), capped.lines.join('\n'));
});

test('retention ignores entries it does not own', () => {
  const fx = fixture();
  const first = begin(fx, {}, FEATURE, { now: () => 1790000000000 });
  const directory = repositoryDirectory(fx);
  fs.mkdirSync(path.join(directory, 'notes'));
  fs.writeFileSync(path.join(directory, 'vr1_1780000000000_0123456789ab'), 'not a report');
  fs.mkdirSync(path.join(path.dirname(directory), 'unrelated'));
  idle(fx, first.id);
  begin(fx, {}, FEATURE, { config: { user: { keep: 1 } }, now: () => 1790000000001 });
  assert.ok(!fs.existsSync(first.bundle));
  assert.ok(fs.existsSync(path.join(directory, 'notes')));
  assert.equal(fs.readFileSync(path.join(directory, 'vr1_1780000000000_0123456789ab'), 'utf8'), 'not a report');
  assert.ok(fs.existsSync(path.join(path.dirname(directory), 'unrelated')));
  assert.deepEqual(er.sweep(tempDir('empty-store'), { keep: 1, maxBytes: 1 }).removed, []);
});

test('retention never follows a symlink', { skip: NOT_ON_WINDOWS }, () => {
  const fx = fixture();
  const first = begin(fx, {}, FEATURE, { now: () => 1790000000000 });
  const directory = repositoryDirectory(fx);
  const outside = tempDir('precious');
  fs.writeFileSync(path.join(outside, 'keep.txt'), 'keep');
  fs.symlinkSync(outside, path.join(directory, 'vr1_1780000000000_0123456789ab'));
  const foreign = tempDir('foreign-repository');
  fs.mkdirSync(path.join(foreign, 'vr1_1780000000000_0123456789ab'));
  fs.symlinkSync(foreign, path.join(path.dirname(directory), 'linked-0123456789'));
  idle(fx, first.id);
  begin(fx, {}, FEATURE, { config: { user: { keep: 1, maxBytes: 1 } }, now: () => 1790000000001 });
  assert.ok(!fs.existsSync(first.bundle));
  assert.ok(fs.existsSync(path.join(outside, 'keep.txt')));
  assert.ok(fs.lstatSync(path.join(directory, 'vr1_1780000000000_0123456789ab')).isSymbolicLink());
  assert.ok(fs.existsSync(path.join(foreign, 'vr1_1780000000000_0123456789ab')), 'a linked repository directory is never entered');
});

test('retention trims only the calling repository and spares a report another call is still building', () => {
  const data = tempDir('shared-keep');
  const first = fixture({ data, label: 'keep-first' });
  const second = fixture({ data, label: 'keep-second' });
  const others = [0, 1].map((index) => begin(first, {}, FEATURE, { now: () => 1790000000000 + index }));
  for (const started of others) idle(first, started.id);
  const open = begin(second, {}, FEATURE, { now: () => 1790000000002 });
  const third = begin(second, {}, FEATURE, { config: { user: { keep: 1 } }, now: () => 1790000000003 });
  for (const started of others) assert.ok(fs.existsSync(started.bundle), 'the keep of one repository never trims another');
  assert.ok(fs.existsSync(open.bundle), 'an unrendered report touched within the window is still being built');
  addImage(second, open.id);
  ok(call(second, 'render', { report: open.id, verdict: 'PARTIAL' }));
  const fourth = begin(second, {}, FEATURE, { config: { user: { keep: 1 } }, now: () => 1790000000004 });
  assert.ok(!fs.existsSync(open.bundle), 'a rendered report beyond keep is deleted');
  const stale = begin(second, {}, FEATURE, { now: () => 1790000000005 });
  idle(second, stale.id);
  const building = begin(second, {}, FEATURE, { now: () => 1790000000006 });
  const mustKeep = [third, fourth, building, building].reduce((sum, started) => sum + footprint(started, second), 0);
  begin(second, {}, FEATURE, { config: { user: { keep: 1, maxBytes: mustKeep + 512 } }, now: () => 1790000000007 });
  assert.ok(!fs.existsSync(stale.bundle), 'an unrendered report idle beyond the window is deleted');
  assert.ok(fs.existsSync(building.bundle), 'the size pass spares a report still being built');
  for (const started of others) assert.ok(!fs.existsSync(started.bundle), 'the store-wide cap applies to every repository');
  const held = begin(second, {}, FEATURE, { now: () => 1790000000008 });
  idle(second, held.id);
  fs.mkdirSync(core.inspectExternalProcessLock(lockOf(repositoryDirectory(second), held.id)).lockFile);
  begin(second, {}, FEATURE, { config: { user: { keep: 1 } }, now: () => 1790000000009 });
  assert.ok(fs.existsSync(held.bundle), 'a lock that cannot be taken keeps its report');
});

test('a run directory and an evidence file named with forward slashes are read in their native spelling', () => {
  assert.equal(er.nativeSpelling('C:/work/app/.zensu/run', 'win32'), path.win32.normalize('C:/work/app/.zensu/run'));
  assert.equal(er.nativeSpelling('/work/app/.zensu/run', 'linux'), '/work/app/.zensu/run');
  assert.equal(er.samePath(path.win32.normalize('C:/Work/App'), path.win32.normalize('c:/work/app'), 'win32'), true);
  assert.equal(er.samePath('/Work/App', '/work/app', 'linux'), false);
  const links = tempDir('links');
  const physical = path.join(links, 'physical');
  fs.mkdirSync(physical);
  assert.equal(er.linkFree(physical, 'win32'), true);
  assert.equal(er.linkFree(physical), true);
  if (process.platform !== 'win32') {
    fs.symlinkSync(physical, path.join(links, 'alias'));
    assert.equal(er.linkFree(path.join(links, 'alias'), 'win32'), false);
    assert.equal(er.linkFree(path.join(links, 'alias')), false);
  }
  if (process.platform !== 'win32') return;
  const fx = fixture();
  const forward = (value) => value.split(path.sep).join('/');
  const started = ok(call(fx, 'begin', { 'run-dir': forward(fx.runDir), drivers: 'browser' }, FEATURE));
  ok(call(fx, 'add', { report: started.id, kind: 'image', file: forward(runFile(fx, 'slash.png', png(2, 2))) }, 'A screenshot named with forward slashes'));
});

test('matrix mode lists the supplied criteria with the states their rows imply', () => {
  const fx = fixture();
  const { id, bundle } = begin(fx, {}, 'feature: Matrix states\nAC-001: Passes\nAC-002: Fails\nAC-003: Partly\nAC-004: Unchecked\n');
  addImage(fx, id);
  ok(step(fx, id, { criteria: 'AC-001', evidence: 'e1' }));
  ok(step(fx, id, { priority: 'P1', criteria: 'AC-002,AC-003', result: 'fail' }));
  ok(step(fx, id, { priority: 'P2', driver: 'api', criteria: 'AC-003', result: 'pass' }));
  ok(step(fx, id, { priority: 'P2', driver: 'cli', criteria: 'AC-001', result: 'skip' }));
  refused(call(fx, 'render', { report: id, verdict: 'PARTIAL' }), /verdict\.contradiction/);
  ok(call(fx, 'render', { report: id, verdict: 'FAIL' }));
  const states = manifestOf(bundle).coverage.criteria.map((criterion) => [criterion.id, criterion.state, criterion.driver, criterion.steps]);
  assert.deepEqual(states, [['AC-001', 'partial', 'browser', [1, 4]], ['AC-002', 'fail', 'browser', [2]], ['AC-003', 'fail', 'browser', [2, 3]], ['AC-004', 'missing', null, []]]);
});

test('chain mode folds the acceptance states of the chain at render', () => {
  const fx = chainFixture();
  const passed = attest(fx, 'AC-001', 'pass', 'Opened the dashboard; all four projects are listed');
  attest(fx, 'AC-002', 'partial', 'Only the desktop export was checked');
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser', log: fx.logPath }, FEATURE), /chain mode takes its criteria from the plan/);
  const { id, bundle } = begin(fx, { drivers: 'browser', log: fx.logPath }, 'feature: The dashboard lists projects\n');
  addImage(fx, id, 'dashboard.png');
  ok(step(fx, id, { criteria: 'AC-001', evidence: 'e1' }));
  refused(call(fx, 'render', { report: id, verdict: 'PARTIAL' }), /is in chain mode; pass --log/);
  refused(call(fx, 'render', { report: id, verdict: 'PASS', log: fx.logPath }), /verdict\.contradiction/);
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL', log: fx.logPath }));
  const manifest = manifestOf(bundle);
  assert.deepEqual(manifest.run.chain, { stem: STEM, plan: `.zensu/plans/${STEM}.md` });
  assert.equal(manifest.coverage.source, 'acceptance-records');
  const rows = Object.fromEntries(manifest.coverage.criteria.map((criterion) => [criterion.id, criterion]));
  assert.equal(rows['AC-001'].state, 'pass');
  assert.equal(rows['AC-001'].record, passed.id);
  assert.equal(rows['AC-001'].driver, 'browser');
  assert.deepEqual(rows['AC-001'].steps, [1]);
  assert.equal(rows['AC-002'].state, 'partial');
  assert.equal(rows['AC-003'].state, 'missing');
  assert.equal(rows['AC-004'].state, 'deprecated');
  assert.match(rows['AC-001'].note, /all four projects are listed/);
});

test('chain mode refuses a run log of another chain and a missing receipt', () => {
  const fx = chainFixture();
  const otherLog = path.join(fx.root, '.zensu', 'logs', '2026-11-09-0200_build-other.log');
  fs.writeFileSync(otherLog, 'BUILD STARTED\n');
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser', log: otherLog }, 'feature: Another chain\n'), /edit-landing receipt records/);
  const bare = fixture();
  bare.logPath = fx.logPath;
  refused(call(bare, 'begin', { 'run-dir': bare.runDir, drivers: 'browser', log: fx.logPath }, 'feature: No receipt\n'), /--log|edit-landing receipt/);
  const { id } = begin(fx, { drivers: 'browser', log: fx.logPath }, 'feature: The dashboard lists projects\n');
  refused(call(fx, 'render', { report: id, verdict: 'PARTIAL', log: fx.logPath }, '', { chain: { receiptPath: fx.receiptPath, editLandingEscaped: false, workTree: '', workTreeFault: 'the bound work tree is gone', bashPath: 'bash' } }), /work tree could not be determined, so the acceptance states cannot be read: the bound work tree is gone/, 2);
});

test('step refuses a criterion begin did not list and an evidence id the report does not hold', () => {
  const fx = fixture();
  const { id } = begin(fx);
  refused(step(fx, id, { criteria: 'AC-009' }), /--criteria names AC-009, which --report-begin did not list/);
  refused(step(fx, id, { evidence: 'e9' }), /--evidence names e9, which this report does not hold/);
  refused(step(fx, id, { priority: 'P3' }), /--priority must be one of P0, P1, P2/, 2);
  refused(step(fx, id, { driver: 'telepathy' }), /--driver must be one of/, 2);
  refused(step(fx, id, { result: 'maybe' }), /--result must be one of pass, fail, skip/, 2);
  refused(step(fx, id, { criteria: 'AC-001,AC-001' }), /more than once/, 2);
  refused(step(fx, id, {}, 'title: Only a title\n'), /stdin must give 'expected: <text>'/);
  refused(step(fx, id, {}, 'loose text first\ntitle: x\n'), /stdin must open with a field line/);
  ok(step(fx, id, { criteria: 'AC-002,AC-001', authenticated: '1' }));
  const binding = JSON.parse(fs.readFileSync(path.join(repositoryDirectory(fx), `${id}.binding.json`), 'utf8'));
  assert.deepEqual(binding.steps[0].criteria, ['AC-001', 'AC-002']);
  assert.equal(binding.run.authenticated, true);
});

test('render refuses a verdict that contradicts the states or a file the bundle lost, naming each fault and its remedy', () => {
  const fx = fixture();
  const { id, bundle } = begin(fx);
  addImage(fx, id);
  ok(step(fx, id, { criteria: 'AC-001', evidence: 'e1', result: 'fail' }));
  ok(step(fx, id, { priority: 'P1', driver: 'api', criteria: 'AC-002' }));
  const contradiction = refused(call(fx, 'render', { report: id, verdict: 'PASS' }), /^REPORT REFUSED — verdict\.contradiction at verdict: .+AC-001.+ \| remedy: state FAIL/m);
  assert.equal(contradiction.errors.length, 1);
  const stored = fs.readdirSync(path.join(bundle, 'files'))[0];
  const keep = fs.readFileSync(path.join(bundle, 'files', stored));
  fs.unlinkSync(path.join(bundle, 'files', stored));
  refused(call(fx, 'render', { report: id, verdict: 'FAIL' }), /file\.missing .+ \| remedy: add the evidence file again with --report-add/);
  fs.writeFileSync(path.join(bundle, 'files', stored), Buffer.concat([keep, Buffer.from([0])]));
  refused(call(fx, 'render', { report: id, verdict: 'FAIL' }), /file\.digest/);
  fs.writeFileSync(path.join(bundle, 'files', stored), keep);
  assert.ok(!fs.existsSync(path.join(bundle, 'manifest.json')), 'a refused render writes nothing');
  ok(call(fx, 'render', { report: id, verdict: 'FAIL' }));
  assert.equal(manifestOf(bundle).verdict, 'FAIL');
});

test('render refuses a pass through a UI driver without an image and names both remedies', () => {
  const fx = fixture();
  const { id, bundle } = begin(fx);
  addImage(fx, id);
  ok(step(fx, id, { criteria: 'AC-001' }));
  ok(step(fx, id, { priority: 'P1', driver: 'api', criteria: 'AC-002' }));
  const result = refused(call(fx, 'render', { report: id, verdict: 'PASS' }), /criterion\.no-image/);
  assert.match(result.errors[0], /link an image already in the report to a step that names AC-001, or record AC-001 partial/);
  ok(step(fx, id, { priority: 'P2', criteria: 'AC-001', evidence: 'e1' }));
  ok(call(fx, 'render', { report: id, verdict: 'PASS' }));
  assert.deepEqual(manifestOf(bundle).coverage.criteria[0].steps, [1, 3]);
  const other = fixture();
  const second = begin(other);
  ok(step(other, second.id, { criteria: 'AC-001' }));
  ok(step(other, second.id, { priority: 'P1', criteria: 'AC-001', result: 'skip' }));
  ok(step(other, second.id, { priority: 'P1', driver: 'api', criteria: 'AC-002' }));
  ok(call(other, 'render', { report: second.id, verdict: 'PARTIAL' }));
  assert.equal(manifestOf(second.bundle).coverage.criteria[0].state, 'partial');
});

test('the target identity is measured again at render and a changed tree becomes a limitation', () => {
  const fx = fixture();
  const { id, bundle } = begin(fx);
  const binding = JSON.parse(fs.readFileSync(path.join(repositoryDirectory(fx), `${id}.binding.json`), 'utf8'));
  assert.equal(binding.target.dirty, false);
  assert.match(binding.target.head, /^[0-9a-f]{40}$/);
  assert.match(binding.target.tree, /^[0-9a-f]{40}$/);
  assert.equal(binding.target.begin_tree, binding.target.tree);
  fs.writeFileSync(path.join(fx.root, 'a.txt'), 'changed\n');
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL' }));
  const manifest = manifestOf(bundle);
  assert.equal(manifest.target.dirty, true);
  assert.notEqual(manifest.target.tree, binding.target.tree);
  assert.equal(manifest.target.begin_tree, binding.target.tree);
  assert.ok(manifest.sections.limitations.some((line) => line.startsWith('The working tree changed during the run:')));
});

test('a rendered report is immutable and a report belongs to the session that began it', () => {
  const fx = fixture();
  const { id } = begin(fx);
  refused(call(fx, 'add', { report: id, kind: 'request', method: 'GET', path: '/', status: '200' }, '', { sessionKey: OTHER_SESSION }), /belongs to another session/);
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL' }));
  refused(call(fx, 'add', { report: id, kind: 'request', method: 'GET', path: '/', status: '200' }), /rendered and immutable/);
  refused(step(fx, id), /rendered and immutable/);
  refused(call(fx, 'render', { report: id, verdict: 'PARTIAL' }), /already rendered/);
  refused(call(fx, 'add', { report: 'vr1_1790000000000_0123456789ab', kind: 'request', method: 'GET', path: '/', status: '200' }), /no report vr1_1790000000000_0123456789ab exists/);
  refused(call(fx, 'add', { report: '../escape', kind: 'request' }), /--report must name a report id/, 2);
  ok(call(fx, 'export', { report: id }, '', { sessionKey: OTHER_SESSION }));
});

test('list shows rendered, unrendered and invalid reports newest first', () => {
  const fx = fixture();
  const rendered = begin(fx, {}, FEATURE, { now: () => 1790000000000 });
  ok(call(fx, 'render', { report: rendered.id, verdict: 'PARTIAL' }));
  const open = begin(fx, {}, FEATURE, { now: () => 1790000000001 });
  const broken = begin(fx, {}, FEATURE, { now: () => 1790000000002 });
  fs.writeFileSync(path.join(repositoryDirectory(fx), `${broken.id}.binding.json`), '{"schema":');
  const listed = ok(call(fx, 'list'));
  assert.deepEqual(listed.reports.map((report) => [report.id, report.state, report.verdict]), [[broken.id, 'invalid', '-'], [open.id, 'unrendered', '-'], [rendered.id, 'rendered', 'PARTIAL']]);
  assert.match(listed.lines[2], /index\.html$/);
  const limited = ok(call(fx, 'list', { limit: '1' }));
  assert.equal(limited.reports.length, 1);
  assert.match(limited.lines[1], /2 older report\(s\) not listed/);
  refused(call(fx, 'list', { limit: '0' }), /--limit must be an integer/, 2);
  assert.match(ok(call(fixture(), 'list')).lines[0], /no report for this repository/);
});

test('export writes a self-contained page and refuses an unrendered report or one over the export cap', () => {
  const fx = fixture();
  const { id, bundle } = begin(fx);
  addImage(fx, id);
  ok(step(fx, id, { criteria: 'AC-001', evidence: 'e1' }));
  refused(call(fx, 'export', { report: id }), /is not rendered; run --report-render first/);
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL' }));
  refused(call(fx, 'export', { report: id }, '', { limits: { maxExportBytes: 10 } }), /above the export cap of 10/);
  const exported = ok(call(fx, 'export', { report: id }));
  assert.equal(exported.target, path.join(bundle, 'export.html'));
  const html = fs.readFileSync(exported.target, 'utf8');
  assert.match(html, /<img src="data:image\/png;base64,/);
  assert.doesNotMatch(html, /<a\s/);
  assert.doesNotMatch(html, /src="files\//);
});

test('every write is atomic and an output path that is not a regular file is refused', () => {
  const fx = fixture();
  const { id, bundle } = begin(fx);
  addImage(fx, id);
  const directory = repositoryDirectory(fx);
  fs.mkdirSync(path.join(bundle, 'index.html'));
  refused(call(fx, 'render', { report: id, verdict: 'PARTIAL' }), /index\.html is not a regular file, so it is not replaced/, 2);
  fs.rmdirSync(path.join(bundle, 'index.html'));
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL' }));
  const leftovers = [...fs.readdirSync(directory), ...fs.readdirSync(bundle), ...fs.readdirSync(path.join(bundle, 'files'))].filter((name) => name.endsWith('.tmp') || name.endsWith('.lock'));
  assert.deepEqual(leftovers, []);
});

test('a symlinked bundle, binding or output file is refused', { skip: NOT_ON_WINDOWS }, () => {
  const fx = fixture();
  const { id, bundle } = begin(fx);
  addImage(fx, id);
  const directory = repositoryDirectory(fx);
  const decoy = path.join(tempDir('decoy'), 'index.html');
  fs.writeFileSync(decoy, 'decoy');
  fs.symlinkSync(decoy, path.join(bundle, 'index.html'));
  refused(call(fx, 'render', { report: id, verdict: 'PARTIAL' }), /is not a regular file, so it is not replaced/, 2);
  assert.equal(fs.readFileSync(decoy, 'utf8'), 'decoy');
  const second = begin(fx);
  const bindingPath = path.join(directory, `${second.id}.binding.json`);
  const moved = path.join(tempDir('binding'), 'binding.json');
  fs.renameSync(bindingPath, moved);
  fs.symlinkSync(moved, bindingPath);
  refused(call(fx, 'add', { report: second.id, kind: 'request', method: 'GET', path: '/', status: '200' }), /^the report lock cannot be taken \(session-control-v1: external process lock resource is unsafe\)$/, 2);
  const third = begin(fx);
  const real = path.join(tempDir('bundle'), 'moved');
  fs.renameSync(third.bundle, real);
  fs.symlinkSync(real, third.bundle);
  refused(call(fx, 'add', { report: third.id, kind: 'request', method: 'GET', path: '/', status: '200' }), /is not a real directory/, 2);
});

test('a report lock another live call holds makes a verb wait and refuse, and the lock of a process that exited is taken over', () => {
  const fx = fixture();
  const { id } = begin(fx);
  const target = lockOf(repositoryDirectory(fx), id);
  const request = { report: id, kind: 'request', method: 'GET', path: '/', status: '200' };
  const held = core.acquireExternalProcessLock({ ...target, ownerPid: process.pid });
  const started = Date.now();
  refused(call(fx, 'add', request, '', { limits: { lockAttempts: 3 } }), /^another call holds this report's lock; run the verb again once it has finished$/, 2);
  assert.ok(Date.now() - started >= 80, 'the verb waited for the lock');
  core.releaseExternalProcessLock({ ...target, ownerPid: process.pid, token: held.token });
  ok(call(fx, 'add', request));
  assert.equal(core.inspectExternalProcessLock(target).lock.state, 'absent', 'the verb releases its lock');
  const script = `require(${JSON.stringify(CORE)}).acquireExternalProcessLock({ lockDirectory: ${JSON.stringify(target.lockDirectory)}, resourcePath: ${JSON.stringify(target.resourcePath)}, ownerPid: process.pid })`;
  const keeper = childProcess.spawnSync(process.execPath, ['-e', script], { encoding: 'utf8' });
  assert.equal(keeper.status, 0, keeper.stderr);
  assert.equal(core.inspectExternalProcessLock(target).lock.alive, false, 'the holder exited without releasing its lock');
  ok(call(fx, 'add', request));
  assert.equal(core.inspectExternalProcessLock(target).lock.state, 'absent', 'the lock of a process that exited is taken over and released');
});

test('the config keys are read permissively and every value not used is disclosed', () => {
  assert.deepEqual(er.normalizeConfig(undefined), { enabled: true, dir: null, keep: 30, maxBytes: 2147483648, webp: 'auto', disclosures: [] });
  assert.equal(er.normalizeConfig({ user: { enabled: false } }).enabled, false);
  assert.equal(er.normalizeConfig({ user: { enabled: 'false' } }).enabled, true);
  const relative = er.normalizeConfig({ user: { dir: 'reports' } });
  assert.equal(relative.dir, null);
  assert.match(relative.disclosures[0], /evidence\.report\.dir is not an absolute path/);
  const bad = er.normalizeConfig({ user: { keep: 0, maxBytes: -1 } });
  assert.equal(bad.keep, 30);
  assert.equal(bad.maxBytes, 2147483648);
  assert.equal(bad.disclosures.length, 2);
  assert.deepEqual(er.normalizeConfig({ user: { keep: 5, maxBytes: 1000 } }), { enabled: true, dir: null, keep: 5, maxBytes: 1000, webp: 'auto', disclosures: [] });
  const layered = er.normalizeConfig({ user: { maxBytes: 5000, dir: '/srv/user-reports' }, project: { keep: 2, maxBytes: 1, dir: '/srv/project-reports', enabled: false } });
  assert.deepEqual([layered.enabled, layered.dir, layered.keep, layered.maxBytes, layered.disclosures.length], [false, path.resolve('/srv/user-reports'), 2, 5000, 2]);
  const projectOnly = er.normalizeConfig({ project: { maxBytes: 7 } });
  assert.deepEqual([projectOnly.maxBytes, projectOnly.disclosures.length], [2147483648, 1]);
  assert.deepEqual(er.normalizeConfig({ user: { dir: '/srv/same' }, project: { dir: '/srv/same' } }).disclosures, []);
  assert.equal(er.normalizeConfig({ user: { enabled: true }, project: { enabled: false } }).enabled, false);
  assert.match(er.normalizeConfig({ user: { maxBytes: 5000 }, project: { maxBytes: 1 } }).disclosures[0], /maxBytes caps the whole store, so it is read from the user configuration only/);
  const projectDir = er.normalizeConfig({ project: { dir: '/srv/project-reports' } });
  assert.equal(projectDir.dir, null);
  assert.match(projectDir.disclosures[0], /^zensu evidence report: evidence\.report\.dir decides where every contributor's evidence is written, so it is read from the user configuration only and the project configuration's value is ignored$/);
  const switchedOff = er.normalizeConfig({ user: { enabled: false }, project: { enabled: true } });
  assert.equal(switchedOff.enabled, false);
  assert.match(switchedOff.disclosures[0], /^zensu evidence report: the user configuration switched evidence reports off, and a project configuration can switch them off but never on$/);
  const fx = fixture();
  const disabled = call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser' }, FEATURE, { config: { user: { enabled: false } } });
  assert.equal(disabled.code, 3);
  assert.match(disabled.lines.join('\n'), /evidence\.report\.enabled is false/);
  assert.ok(!fs.existsSync(path.join(fx.data, 'evidence-report')));
  const disclosed = begin(fx, {}, FEATURE, { config: { user: { keep: 'many' } } });
  assert.match(disclosed.lines[0], /^zensu evidence report: evidence\.report\.keep must be an integer/);
});

test('begin validates its mode, drivers, origin and recipe', () => {
  const fx = fixture();
  refused(call(fx, 'begin', { 'run-dir': fx.runDir }, FEATURE), /--drivers must name/, 2);
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser,telepathy' }, FEATURE), /"telepathy", which is not one of/, 2);
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser', mode: 'cloud' }, FEATURE), /--mode must be one of local, remote/, 2);
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser', mode: 'remote' }, FEATURE), /--origin must name the remote origin/, 2);
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser', origin: 'https://preview.example.com' }, FEATURE), /--origin belongs to remote mode/, 2);
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser', recipe: '../outside.yaml' }, FEATURE), /--recipe must be a path relative/, 2);
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser' }, 'AC-001: no feature\n'), /'feature: <text>'/);
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser' }, 'feature: x\nAC-001: a\nAC-001: b\n'), /lists AC-001 more than once/);
  const remote = begin(fx, { mode: 'remote', origin: 'https://preview.example.com', drivers: 'api,browser', attach: '1', recipe: '.zensu/runtime.yaml' });
  const binding = JSON.parse(fs.readFileSync(path.join(repositoryDirectory(fx), `${remote.id}.binding.json`), 'utf8'));
  assert.equal(binding.target.origin, 'https://preview.example.com');
  assert.deepEqual(binding.run.drivers, ['browser', 'api']);
  assert.equal(binding.run.attach, true);
  assert.equal(binding.run.recipe, '.zensu/runtime.yaml');
});

test('the core module reads no host environment variable and every host fact enters as an argument', () => {
  const source = fs.readFileSync(LIB, 'utf8');
  assert.doesNotMatch(source, /CLAUDE_/);
  assert.equal((source.match(/process\.env/g) || []).length, 1);
  assert.match(source, /async function main\(argv, env = process\.env\)/);
  const required = [...source.matchAll(/require\('([^']+)'\)/g)].map((match) => match[1]).sort();
  assert.deepEqual(required, ['./acceptance-verify-v1.js', './evidence-run-v1.js', './secret-patterns.js', './session-control-core-v1.js', './zensu-artifact-redact-v1.js', 'node:child_process', 'node:crypto', 'node:fs', 'node:path', 'node:zlib']);
  const seen = new Set();
  const env = new Proxy({ ZENSU_ERP_HOST: 'kiro' }, { get(target, key) { seen.add(String(key)); return target[key]; } });
  const options = er.transportOptions(env);
  assert.equal(options.host, 'kiro');
  for (const key of seen) assert.match(key, /^ZENSU_ERP_[A-Z_]+$/);
  assert.ok(seen.has('ZENSU_ERP_TOOL_PATH'));
  assert.equal(er.transportOptions({ ZENSU_ERP_TOOL_PATH: '/opt/tools:/usr/bin' }).toolPath, '/opt/tools:/usr/bin');
  assert.equal(er.transportOptions({}).toolPath, '');
});

test('the core module makes no network request, starts only the two WebP tools through one runner without a shell, and runs git through the evidence runner', () => {
  const source = fs.readFileSync(LIB, 'utf8');
  assert.doesNotMatch(source, /require\('node:(?:http|https|http2|net|tls|dns|dgram)'\)/);
  assert.doesNotMatch(source, /\bfetch\(|execFileSync|execSync|\bspawn\(|\bfork\(|shell: true/);
  assert.match(source, /^const childProcess = require\('node:child_process'\);$/m);
  assert.equal((source.match(/childProcess\./g) || []).length, 1);
  assert.match(source, /childProcess\.spawnSync\(tool, args, \{\n    cwd: directory,\n    env: emptyEnvironment\(\),\n    shell: false,\n    stdio: 'ignore',\n    timeout: limits\.toolMs,\n    killSignal: 'SIGKILL',\n    windowsHide: true,\n  \}\)/);
  assert.deepEqual([...source.matchAll(/runTool\(tools\.(encoder|decoder), /g)].map((match) => match[1]), ['encoder', 'decoder']);
  assert.equal((source.match(/\brunTool\(/g) || []).length, 3);
  assert.match(source, /evidenceRun\.git\(/);
  assert.doesNotMatch(source, /not a git repository/);
  assert.equal(evr.outsideWorkTree({ code: 'ENOENT' }), true);
  assert.equal(evr.outsideWorkTree({ reason: 'git rev-parse failed: fatal: not a git repository (or any of the parent directories): .git' }), true);
  assert.equal(evr.outsideWorkTree({ reason: 'git timed out' }), false);
});

test('the manifest driver enum is frozen in the core and matches the acceptance drivers', () => {
  assert.ok(Object.isFrozen(er.DRIVERS));
  assert.deepEqual([...er.DRIVERS], ['browser', 'mobile', 'desktop', 'api', 'cli', 'async', 'iac', 'custom', 'library']);
  assert.deepEqual([...er.DRIVERS], [...av.DRIVERS], 'a driver the acceptance module adds needs a manifest schema decision before a report accepts it');
  assert.doesNotMatch(fs.readFileSync(LIB, 'utf8'), /=\s*acceptance\.DRIVERS/);
});

test('a report from any host validates and carries no Zensu dependency', () => {
  const fx = fixture();
  const started = begin(fx, {}, FEATURE, { host: 'kiro' });
  ok(call(fx, 'render', { report: started.id, verdict: 'PARTIAL' }, '', { host: 'kiro' }));
  const manifest = manifestOf(started.bundle);
  assert.equal(manifest.run.host, 'kiro');
  assert.ok(manifest.coverage.criteria.every((criterion) => criterion.zensu === null));
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser' }, FEATURE, { host: 'Claude Code' }), /no valid host/, 2);
  const remote = JSON.parse(fs.readFileSync(path.join(CORPUS, 'render-remote-other-host', 'manifest.json'), 'utf8'));
  for (const host of ['codex', 'zensu-antigravity', 'kiro']) {
    remote.run.host = host;
    assert.deepEqual(er.validateManifest(remote), []);
  }
});

test('the repository key is shared by the worktrees of one clone and differs between clones', () => {
  const first = repo({ label: 'clone-one' });
  const worktree = path.join(tempDir('worktrees'), 'feature');
  git(first, 'worktree', 'add', '-q', '-b', 'feature', worktree);
  assert.equal(er.repositoryKey(first), er.repositoryKey(fs.realpathSync(worktree)));
  const second = repo({ label: 'clone-two' });
  assert.notEqual(er.repositoryKey(first), er.repositoryKey(second));
  assert.match(er.repositoryKey(first), /^erp-clone-one-[A-Za-z0-9]+-[0-9a-f]{10}$/);
  assert.match(er.repositoryKey(tempDir('plain folder!')), /^erp-plain-folder-[A-Za-z0-9-]*-[0-9a-f]{10}$/);
});

test('a remote URL is reduced to its repository path without credentials', () => {
  const cases = [
    ['https://github.com/example/demo.git', 'example/demo'],
    [`https://user:${FAKE_TOKEN}@github.com/example/demo`, 'example/demo'],
    ['git@github.com:example/demo.git', 'example/demo'],
    ['ssh://git@gitlab.example.com:2222/group/sub/demo.git', 'group/sub/demo'],
    ['https://github.com/example', null],
    ['/srv/git/demo.git', null],
    ['file:///srv/git/demo.git', null],
    ['C:/repos/demo', null],
    ['', null],
  ];
  for (const [url, expected] of cases) assert.equal(er.repositoryFromRemote(url), expected, url);
});

test('the field parser reads field lines from stdin and continues free lines', () => {
  const spec = { single: ['feature'], repeat: [], criteria: true };
  const parsed = er.parseFields('\nfeature: The first line\ncontinues here\n\nAC-001: One\nAC-002a: Two\nnote: still AC-002a\n', spec);
  assert.equal(parsed.single.get('feature'), 'The first line\ncontinues here\n');
  assert.deepEqual(parsed.criteria, [{ id: 'AC-001', text: 'One' }, { id: 'AC-002a', text: 'Two\nnote: still AC-002a\n' }]);
  assert.match(er.parseFields('text first\nfeature: x', spec).error, /stdin must open with a field line/);
  assert.match(er.parseFields('feature: a\nfeature: b', spec).error, /more than once/);
  const repeated = er.parseFields('limitation: a\r\nlimitation: b\nconsent: http://localhost:3000 / asked\n', { single: [], repeat: ['limitation', 'consent'], criteria: false });
  assert.deepEqual(repeated.repeat.get('limitation'), ['a', 'b']);
  assert.deepEqual(er.parseViewport('1440x900@2'), { width: 1440, height: 900, scale: 2 });
  assert.deepEqual(er.parseViewport('390x844'), { width: 390, height: 844, scale: 1 });
  assert.equal(er.parseViewport('1440 x 900'), null);
  assert.equal(er.parseViewport('10x10@99'), null);
});

test('the transport reads its arguments from a NUL-separated file and refuses a repeat or a line break', () => {
  const directory = tempDir('transport');
  fs.writeFileSync(path.join(directory, 'args'), 'report\0vr1_1790000000000_0123456789ab\0kind\0request\0attach\x001\0');
  fs.writeFileSync(path.join(directory, 'stdin'), 'caption text');
  fs.writeFileSync(path.join(directory, 'config.json'), '{"keep":3}');
  fs.writeFileSync(path.join(directory, 'work-tree-fault'), 'gone');
  const options = er.transportOptions({ ZENSU_ERP_DIR: directory, ZENSU_ERP_SESSION_KEY: SESSION, ZENSU_ERP_EDIT_LANDING_ESCAPED: '1' });
  assert.deepEqual([...options.args], [['report', 'vr1_1790000000000_0123456789ab'], ['kind', 'request'], ['attach', '1']]);
  assert.equal(options.stdinText, 'caption text');
  assert.deepEqual(options.config, { keep: 3 });
  assert.equal(options.chain.workTreeFault, 'gone');
  assert.equal(options.chain.editLandingEscaped, true);
  fs.writeFileSync(path.join(directory, 'args'), 'kind\0a\0kind\0b\0');
  assert.throws(() => er.transportOptions({ ZENSU_ERP_DIR: directory }), /--kind is given more than once/);
  fs.writeFileSync(path.join(directory, 'args'), 'kind\0a\nb\0');
  assert.throws(() => er.transportOptions({ ZENSU_ERP_DIR: directory }), /must not hold a line break/);
  fs.writeFileSync(path.join(directory, 'args'), 'kind\0');
  assert.throws(() => er.transportOptions({ ZENSU_ERP_DIR: directory }), /malformed/);
});

test('main prints refusals on stderr under the label and answers the exit code', () => {
  const fx = fixture();
  const directory = tempDir('main');
  fs.writeFileSync(path.join(directory, 'args'), `run-dir\0${fx.runDir}\0drivers\0browser\0`);
  fs.writeFileSync(path.join(directory, 'stdin'), FEATURE);
  const env = {
    PATH: process.env.PATH,
    ZENSU_ERP_DIR: directory,
    ZENSU_ERP_PLUGIN_DATA: fx.data,
    ZENSU_ERP_SESSION_KEY: SESSION,
    ZENSU_ERP_PROJECT_ROOT: fx.root,
    ZENSU_ERP_HOST: 'claude-code',
    ZENSU_ERP_HOME: fx.home,
    ZENSU_ERP_PLUGIN_MANIFEST: path.join(ROOT, '.claude-plugin', 'plugin.json'),
    ZENSU_ERP_LABEL: 'zensu-log.sh --report-begin',
  };
  const script = `require(${JSON.stringify(LIB)}).main([process.argv[1]]).then((code) => { process.exitCode = code; })`;
  const run = (verb, extra = {}) => childProcess.spawnSync(process.execPath, ['-e', script, verb], { env: { ...env, ...extra }, encoding: 'utf8' });
  const started = run('begin');
  assert.equal(started.status, 0, started.stderr);
  assert.match(started.stdout, /^zensu evidence report: begun vr1_[0-9]{13}_[0-9a-f]{12} \| local \| drivers browser \| criteria AC-001, AC-002$/m);
  const version = JSON.parse(fs.readFileSync(path.join(ROOT, '.claude-plugin', 'plugin.json'), 'utf8')).version;
  const id = /begun (vr1_[0-9_a-f]+)/.exec(started.stdout)[1];
  const binding = JSON.parse(fs.readFileSync(path.join(repositoryDirectory(fx), `${id}.binding.json`), 'utf8'));
  assert.equal(binding.plugin_version, version);
  fs.writeFileSync(path.join(directory, 'args'), 'drivers\0browser\0');
  const failed = run('begin');
  assert.equal(failed.status, 2);
  assert.match(failed.stderr, /^zensu-log\.sh --report-begin: --run-dir must name the run directory by an absolute path$/m);
  const usage = run('publish');
  assert.equal(usage.status, 2);
  assert.match(usage.stderr, /usage: evidence-report-v1\.js begin\|add\|step\|render\|list\|export/);
  fs.writeFileSync(path.join(directory, 'args'), '');
  const listed = run('list');
  assert.equal(listed.status, 0, listed.stderr);
  assert.match(listed.stdout, new RegExp(`^${id} \\| unrendered \\| - \\| `, 'm'));
});

test('a lock entry the core lock cannot read is refused at once instead of spinning', () => {
  const fx = fixture();
  const { id } = begin(fx);
  const { lockFile } = core.inspectExternalProcessLock(lockOf(repositoryDirectory(fx), id));
  fs.mkdirSync(lockFile);
  const request = { report: id, kind: 'request', method: 'GET', path: '/api/items', status: '200' };
  const started = Date.now();
  refused(call(fx, 'add', request), /^the report lock cannot be taken \(session-control-v1: not a regular file: .+\)$/, 2);
  assert.ok(Date.now() - started < 2000, 'the refusal does not wait for every attempt');
  fs.rmdirSync(lockFile);
  ok(call(fx, 'add', request));
});

test('a retention delete that fails is reported and does not abort --report-begin', (t) => {
  const fx = fixture();
  const first = begin(fx, {}, FEATURE, { now: () => 1790000000000 });
  ok(call(fx, 'render', { report: first.id, verdict: 'PARTIAL' }));
  const realRemove = fs.rmSync;
  const failing = t.mock.method(fs, 'rmSync', (target, ...rest) => {
    if (String(target) !== first.bundle) return realRemove.call(fs, target, ...rest);
    const error = new Error('resource busy');
    error.code = 'EBUSY';
    throw error;
  });
  let second;
  try {
    second = begin(fx, {}, FEATURE, { config: { user: { keep: 1 } }, now: () => 1790000000001 });
  } finally {
    failing.mock.restore();
  }
  const notice = second.lines.find((line) => line.includes('retention could not delete 1 report(s): '));
  assert.ok(notice && notice.includes(`/${first.id} (EBUSY)`), second.lines.join('\n'));
  assert.ok(fs.existsSync(first.bundle), 'the report whose delete failed stays');
  assert.ok(fs.existsSync(second.bundle), 'the new report is kept');
  const third = begin(fx, {}, FEATURE, { config: { user: { keep: 1 } }, now: () => 1790000000002 });
  assert.ok(!fs.existsSync(first.bundle), 'a later begin deletes it once the delete succeeds');
  assert.ok(fs.existsSync(third.bundle));
});

test('the transport refuses an oversized or unreadable file instead of reading it as empty', () => {
  const directory = tempDir('transport');
  const refusal = (pattern, code) => (error) => error instanceof er.ReportError && error.exitCode === code && pattern.test(error.message);
  assert.equal(er.transportOptions({ ZENSU_ERP_DIR: directory }).stdinText, '');
  fs.writeFileSync(path.join(directory, 'stdin'), 'x'.repeat(er.LIMITS.maxStdinBytes + 2));
  assert.throws(() => er.transportOptions({ ZENSU_ERP_DIR: directory }), refusal(/stdin exceeds 65536 bytes/, 1));
  fs.rmSync(path.join(directory, 'stdin'));
  fs.mkdirSync(path.join(directory, 'stdin'));
  assert.throws(() => er.transportOptions({ ZENSU_ERP_DIR: directory }), refusal(/the transport file stdin cannot be read \(not a regular file\)/, 2));
  fs.rmdirSync(path.join(directory, 'stdin'));
  fs.mkdirSync(path.join(directory, 'args'));
  assert.throws(() => er.transportOptions({ ZENSU_ERP_DIR: directory }), refusal(/the transport file args cannot be read/, 2));
});

test('the --recipe and --class values pass the secret screen', () => {
  const fx = fixture();
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'api', recipe: `.zensu/${FAKE_TOKEN}.yaml` }, FEATURE), /--recipe matches a secret pattern/);
  const { id } = begin(fx, { recipe: '.zensu/runtime.yaml' });
  refused(call(fx, 'add', { report: id, kind: 'signal', source: 'console', class: FAKE_TOKEN }, 'A console error appeared'), /--class matches a secret pattern/);
  ok(call(fx, 'add', { report: id, kind: 'signal', source: 'console', class: 'error' }, 'A console error appeared'));
});

test('chain mode lists the plan criteria at begin and step refuses one the plan does not list', () => {
  const fx = chainFixture();
  const { id } = begin(fx, { drivers: 'browser', log: fx.logPath }, 'feature: The dashboard lists projects\n');
  const binding = JSON.parse(fs.readFileSync(path.join(repositoryDirectory(fx), `${id}.binding.json`), 'utf8'));
  assert.deepEqual(binding.criteria.map((criterion) => criterion.id), ['AC-001', 'AC-002', 'AC-003', 'AC-004']);
  refused(step(fx, id, { criteria: 'AC-009' }), /--criteria names AC-009, which the chain's plan .+ did not list at --report-begin/);
  ok(step(fx, id, { criteria: 'AC-003' }));
});

test('chain mode reports a dropped criterion with its newest verdict, which blocks PASS', () => {
  const fx = chainFixture();
  attest(fx, 'AC-001', 'pass', 'Opened the dashboard; all four projects are listed');
  attest(fx, 'AC-002', 'pass', 'Downloaded the CSV export');
  attest(fx, 'AC-003', 'fail', 'The projects were not sorted by name');
  fs.writeFileSync(path.join(fx.root, '.zensu', 'plans', `${STEM}.md`), planText([
    ['AC-001', 'The dashboard lists every project'],
    ['AC-002', 'The export downloads a CSV file'],
    ['AC-003', '(deprecated) Projects are sorted by name'],
    ['AC-004', '(deprecated) The legacy grid view renders'],
  ]));
  const { id, bundle } = begin(fx, { drivers: 'browser', log: fx.logPath }, 'feature: The dashboard lists projects\n');
  addImage(fx, id, 'dashboard.png');
  ok(step(fx, id, { criteria: 'AC-001,AC-002', evidence: 'e1' }));
  refused(call(fx, 'render', { report: id, verdict: 'PASS', log: fx.logPath }), /verdict\.contradiction/);
  refused(call(fx, 'render', { report: id, verdict: 'PARTIAL', log: fx.logPath }), /verdict\.contradiction/);
  ok(call(fx, 'render', { report: id, verdict: 'FAIL', log: fx.logPath }));
  const rows = Object.fromEntries(manifestOf(bundle).coverage.criteria.map((criterion) => [criterion.id, criterion]));
  assert.equal(rows['AC-003'].state, 'fail');
  assert.match(rows['AC-003'].note, /deprecated while its newest verdict is fail/);
  assert.equal(rows['AC-004'].state, 'deprecated');
});

test('chain mode carries the acceptance disclosures into the output and the limitations', () => {
  const fx = chainFixture();
  const escaped = { chain: { receiptPath: '', editLandingEscaped: true, workTree: '', workTreeFault: null, bashPath: 'bash' } };
  const started = ok(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser', log: fx.logPath }, 'feature: The dashboard lists projects\n', escaped));
  assert.ok(started.lines.some((line) => line.startsWith('ACCEPTANCE STEM UNCHECKED')), started.lines.join('\n'));
  const rendered = ok(call(fx, 'render', { report: started.id, verdict: 'PARTIAL', log: fx.logPath }, '', escaped));
  assert.ok(rendered.lines.some((line) => line.startsWith('ACCEPTANCE STEM UNCHECKED')), rendered.lines.join('\n'));
  assert.ok(manifestOf(started.bundle).sections.limitations.some((line) => line.startsWith('ACCEPTANCE STEM UNCHECKED')));
});

test('chain mode measures the target in the chain work tree through the acceptance fingerprint', (t) => {
  const fx = chainFixture({ ignore: '.zensu/\n.claude/\n' });
  const workTree = path.join(fx.root, '.claude', 'worktrees', 'bound');
  git(fx.root, 'worktree', 'add', '-q', '-b', 'bound-branch', workTree);
  git(workTree, 'commit', '-q', '--allow-empty', '-m', 'work tree commit');
  const bound = { chain: { receiptPath: fx.receiptPath, editLandingEscaped: false, workTree, workTreeFault: null, bashPath: 'bash' } };
  const started = ok(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser', log: fx.logPath }, 'feature: The dashboard lists projects\n', bound));
  ok(call(fx, 'render', { report: started.id, verdict: 'PARTIAL', log: fx.logPath }, '', bound));
  const { target } = manifestOf(started.bundle);
  assert.equal(target.branch, 'bound-branch');
  assert.equal(target.head, git(workTree, 'rev-parse', 'HEAD').trim());
  assert.notEqual(target.head, git(fx.root, 'rev-parse', 'HEAD').trim());
  assert.equal(target.tree, av.chainTree({ projectRoot: fx.root, workTree }, tempDir('chain-tree')).tree.tree);
  const shots = path.join(workTree, 'shots');
  fs.mkdirSync(shots);
  refused(call(fx, 'begin', { 'run-dir': shots, drivers: 'browser', log: fx.logPath }, 'feature: The dashboard lists projects\n', bound), /, so its captures could be committed and every capture would move the tree fingerprint; have git ignore shots\//);
  refused(call(fx, 'begin', { 'run-dir': shots, drivers: 'browser' }, FEATURE), /, so its captures could be committed; have git ignore shots\//);
  const respelled = t.mock.method(evr, 'fingerprintRoot', () => `${workTree}${path.sep}`);
  refused(call(fx, 'begin', { 'run-dir': shots, drivers: 'browser', log: fx.logPath }, 'feature: The dashboard lists projects\n', bound), /, so its captures could be committed and every capture would move the tree fingerprint; have git ignore shots\//);
  respelled.mock.restore();
  attest(fx, 'AC-001', 'pass', 'Opened the dashboard; all four projects are listed');
  const later = ok(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser', log: fx.logPath }, 'feature: The dashboard lists projects\n', bound));
  addImage(fx, later.id, 'dashboard.png');
  ok(step(fx, later.id, { criteria: 'AC-001', evidence: 'e1' }));
  fs.writeFileSync(path.join(workTree, 'notes.txt'), 'written in the work tree during the run\n');
  const realFingerprint = evr.computeFingerprint;
  const limited = t.mock.method(evr, 'computeFingerprint', (projectRoot, treeRoot, scratch, limits) => realFingerprint(projectRoot, treeRoot, scratch, { ...(limits || evr.LIMITS), untrackedMaxFiles: 0 }));
  ok(call(fx, 'render', { report: later.id, verdict: 'PARTIAL', log: fx.logPath }, '', bound));
  limited.mock.restore();
  const chained = manifestOf(later.bundle).sections.limitations;
  assert.ok(chained.some((line) => line.startsWith('The working tree could not be fingerprinted at --report-render (more than 0 untracked files), so a change since ')), chained.join('\n'));
  assert.ok(chained.includes('The acceptance states could not be compared with the working tree at --report-render (more than 0 untracked files), so each criterion shows its newest record, whatever tree that record was taken on.'), chained.join('\n'));
  fs.writeFileSync(path.join(workTree, '.gitignore'), 'node_modules/\n');
  const stateRuns = path.join(workTree, '.zensu', 'runs', 'r1');
  fs.mkdirSync(stateRuns, { recursive: true });
  refused(call(fx, 'begin', { 'run-dir': stateRuns, drivers: 'browser', log: fx.logPath }, 'feature: The dashboard lists projects\n', bound), /, so its captures could be committed; have git ignore \.zensu\/runs\/, for example with the line \/\.zensu\/runs\/ in the repository's \.gitignore$/);
});

test('the draft check measures the manifest render writes, so the report that took its last item still renders', () => {
  const fx = fixture();
  const tight = { limits: { maxManifestBytes: 9000, renderReserveBytes: 0 } };
  const { id, bundle } = ok(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'api' }, FEATURE, tight));
  let added = 0;
  for (;;) {
    const result = call(fx, 'add', { report: id, kind: 'request', method: 'GET', path: `/api/items/${added}`, status: '200' }, '', tight);
    if (result.code !== 0) {
      refused(result, /would outgrow the manifest cap of 9000 bytes/);
      break;
    }
    added += 1;
    assert.ok(added < 500, 'the draft check never refused');
  }
  assert.ok(added > 10, `only ${added} items fit`);
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL' }, '', tight));
  assert.ok(fs.statSync(path.join(bundle, 'manifest.json')).size <= 9000);
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'api' }, FEATURE, { limits: { maxManifestBytes: 9000, renderReserveBytes: 9000 } }), /would outgrow the manifest cap of 9000 bytes/);
});

test('a usage fault exits 2 and a refusal of a well-formed call exits 1', () => {
  const fx = fixture();
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser', mode: 'sideways' }, FEATURE), /--mode must be one of local, remote/, 2);
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser', caption: 'x' }, FEATURE), /--caption is not an argument of --report-begin/, 2);
  refused(call(fx, 'begin', { 'run-dir': path.join(fx.root, 'absent'), drivers: 'browser' }, FEATURE), /does not exist/, 1);
  const { id } = begin(fx);
  refused(call(fx, 'add', { report: 'vr1_short' }), /--report must name a report id/, 2);
  refused(call(fx, 'add', { report: id, kind: 'sound' }), /--kind must be one of/, 2);
  refused(step(fx, id, { evidence: 'e9' }), /--evidence names e9, which this report does not hold/, 1);
});

test('a git fault other than a missing work tree refuses begin instead of falling back to the project root', () => {
  const root = tempDir('broken-git');
  fs.writeFileSync(path.join(root, '.git'), 'not a gitfile\n');
  const fx = fixture({ root });
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'api' }, FEATURE), /whether the run directory lies in the project's work tree could not be determined \(git rev-parse failed: fatal: invalid gitfile format/, 2);
  fs.rmSync(path.join(root, '.zensu'), { recursive: true });
  fs.writeFileSync(path.join(root, '.zensu'), 'not a directory\n');
  assert.deepEqual(refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'api' }, FEATURE), /does not exist/).errors, [`the run directory ${fx.runDir} does not exist`]);
  if (process.platform !== 'win32') {
    fs.rmSync(path.join(root, '.zensu'));
    const target = tempDir('broken-target');
    fs.mkdirSync(path.join(target, 'verify-feature-runs', 'r1'), { recursive: true });
    fs.symlinkSync(target, path.join(root, '.zensu'));
    assert.deepEqual(refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'api' }, FEATURE), /runs through a symlink/).errors, [`the run directory ${fx.runDir} runs through a symlink; pass its physical path`]);
  }
});

test('add records a completed evidence run of this session and refuses every other run', async () => {
  const fx = fixture();
  const output = () => ({ text: '', write(chunk) { this.text += String(chunk); return true; } });
  const stdout = output();
  const stderr = output();
  const code = await evr.run({ pluginData: fx.data, sessionKey: SESSION, projectRoot: fx.root, cwd: fx.root, scope: 'scoped', command: 'exit 0', show: 'tail', bashPath: 'bash', env: process.env, stdout, stderr });
  assert.equal(code, 0, stderr.text);
  const records = evr.storeLocations(fx.data, SESSION).records;
  const [file] = fs.readdirSync(records).filter((name) => name.endsWith('.json'));
  const runId = file.slice(0, -5);
  const record = JSON.parse(fs.readFileSync(path.join(records, file), 'utf8'));
  const { id, bundle } = begin(fx, { drivers: 'api' });
  const runItem = (report, evidenceRun) => ({ report, kind: 'run', 'evidence-run': evidenceRun });
  refused(call(fx, 'add', runItem(id, runId), 'The suite passed'), /^a run item carries no caption; pass nothing on stdin$/);
  refused(call(fx, 'add', runItem(id, 'er1_bad')), /--evidence-run must name an er1_ evidence-run record/, 2);
  refused(call(fx, 'add', runItem(id, 'er1_1790000000000_0123456789ab')), /^no evidence run er1_1790000000000_0123456789ab exists for this session$/);
  const added = ok(call(fx, 'add', runItem(id, runId)));
  assert.equal(added.lines[0], `zensu evidence report: e1 added to ${id} | run | ${runId} exit 0`);
  const runningId = 'er1_1790000000001_0123456789ab';
  fs.writeFileSync(path.join(records, `${runningId}.json`), JSON.stringify({ ...record, id: runningId, state: 'running', pid: process.pid, started_at: new Date().toISOString(), finished_at: null, exit_code: null, duration_ms: null }));
  refused(call(fx, 'add', runItem(id, runningId)), new RegExp(`^evidence run ${runningId} is running, not completed$`));
  const other = begin(fx, { drivers: 'api' }, FEATURE, { sessionKey: OTHER_SESSION });
  refused(call(fx, 'add', runItem(other.id, runId), '', { sessionKey: OTHER_SESSION }), new RegExp(`^no evidence run ${runId} exists for this session$`));
  fs.copyFileSync(path.join(records, file), path.join(evr.storeLocations(fx.data, OTHER_SESSION).records, file));
  refused(call(fx, 'add', runItem(other.id, runId), '', { sessionKey: OTHER_SESSION }), new RegExp(`^evidence run ${runId} does not validate \\(bound to another session\\)$`));
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL' }));
  assert.deepEqual(manifestOf(bundle).evidence.e1, { kind: 'run', record: runId, command: 'exit 0', exit_code: 0, duration_ms: record.duration_ms });
});

test('begin holds the new report\'s lock from the creation of its directories until its binding is written', (t) => {
  const fx = fixture();
  const realMkdir = fs.mkdirSync;
  const seen = [];
  t.mock.method(fs, 'mkdirSync', (target, ...rest) => {
    const created = realMkdir.call(fs, target, ...rest);
    const name = path.basename(String(target));
    if (er.ID_RE.test(name) && seen.length === 0) {
      const repository = path.dirname(String(target));
      const swept = er.sweep(path.dirname(repository), { repositoryKey: path.basename(repository), keep: 0, maxBytes: 0 });
      seen.push({ removed: swept.removed.length, lock: core.inspectExternalProcessLock(lockOf(repository, name)).lock.state });
    }
    return created;
  });
  const started = begin(fx);
  assert.deepEqual(seen, [{ removed: 0, lock: 'owned' }]);
  assert.ok(fs.existsSync(path.join(started.bundle, 'files')));
  assert.ok(fs.existsSync(path.join(repositoryDirectory(fx), `${started.id}.binding.json`)));
  assert.equal(core.inspectExternalProcessLock(lockOf(repositoryDirectory(fx), started.id)).lock.state, 'absent', 'begin releases the lock once the binding is written');
});

test('begin refuses a chain plan with more criteria than one report holds and names how many fit', () => {
  const fx = chainFixture();
  const planPath = path.join(fx.root, '.zensu', 'plans', `${STEM}.md`);
  const rows = (count) => Array.from({ length: count }, (_, index) => [`AC-${String(index + 1).padStart(3, '0')}`, `Criterion number ${index + 1} holds`]);
  const tight = { limits: { maxManifestBytes: 40000, renderReserveBytes: 0 } };
  const args = { 'run-dir': fx.runDir, drivers: 'browser', log: fx.logPath };
  const reports = () => fs.readdirSync(repositoryDirectory(fx)).filter((name) => name.startsWith('vr1_')).sort();
  fs.writeFileSync(planPath, planText(rows(12)));
  const refusal = refused(call(fx, 'begin', args, 'feature: The dashboard lists projects\n', tight), /^a report of the chain's plan \.zensu\/plans\/[^ ]+\.md would hold 12 criteria, but one report holds at most [0-9]+ of them, because each keeps 6128 bytes of the 40000-byte manifest free for the note --report-render adds; verify this chain without a report$/);
  const fit = Number(/holds at most ([0-9]+) of them/.exec(refusal.errors[0])[1]);
  assert.ok(fit > 0 && fit < 12, `${fit} criteria fit`);
  assert.deepEqual(reports(), [], 'a refused begin creates no report');
  fs.writeFileSync(planPath, planText(rows(fit)));
  const started = ok(call(fx, 'begin', args, 'feature: The dashboard lists projects\n', tight));
  fs.writeFileSync(planPath, planText(rows(fit + 1)));
  refused(call(fx, 'begin', args, 'feature: The dashboard lists projects\n', tight), new RegExp(`would hold ${fit + 1} criteria, but one report holds at most ${fit} of them`));
  assert.deepEqual(reports(), [started.id, `${started.id}.binding.json`]);
});

test('a chain report holding its fitting criteria renders with full multi-byte notes, and a plan that grew since begin is named', () => {
  const fx = chainFixture();
  const planPath = path.join(fx.root, '.zensu', 'plans', `${STEM}.md`);
  const rows = (count) => Array.from({ length: count }, (_, index) => [`AC-${String(index + 1).padStart(3, '0')}`, `Criterion number ${index + 1} holds`]);
  const tight = { limits: { maxManifestBytes: 40000, renderReserveBytes: 0 } };
  const args = { 'run-dir': fx.runDir, drivers: 'browser', log: fx.logPath };
  fs.writeFileSync(planPath, planText(rows(12)));
  const fit = Number(/holds at most ([0-9]+) of them/.exec(refused(call(fx, 'begin', args, 'feature: The dashboard lists projects\n', tight), /holds at most/).errors[0])[1]);
  fs.writeFileSync(planPath, planText(rows(fit)));
  const started = ok(call(fx, 'begin', args, 'feature: The dashboard lists projects\n', tight));
  const note = '一'.repeat(2000);
  for (const [ac] of rows(fit)) attest(fx, ac, 'partial', note);
  ok(call(fx, 'render', { report: started.id, verdict: 'PARTIAL', log: fx.logPath }, '', tight));
  assert.ok(manifestOf(started.bundle).coverage.criteria.every((criterion) => criterion.note === note));
  const grown = ok(call(fx, 'begin', args, 'feature: The dashboard lists projects\n', tight));
  fs.writeFileSync(planPath, planText(rows(fit + 2)));
  for (const [ac] of rows(fit + 2).slice(fit)) attest(fx, ac, 'partial', note);
  const added = rows(fit + 2).slice(fit).map(([ac]) => ac).join(', ');
  refused(call(fx, 'render', { report: grown.id, verdict: 'PARTIAL', log: fx.logPath }, '', tight), new RegExp(`^REPORT REFUSED — manifest\\.too-large: the manifest holds [0-9]+ bytes, above the cap of 40000, because the chain's plan changed since --report-begin \\(${added}\\) \\| remedy: begin a new report on the current plan$`));
});

test('begin counts a criterion dropped from the chain plan whose newest verdict is not a pass, and lists a deprecated one once', () => {
  const fx = chainFixture();
  attest(fx, 'AC-003', 'fail', 'Projects were listed unsorted');
  fs.writeFileSync(path.join(fx.root, '.zensu', 'plans', `${STEM}.md`), planText([['AC-001', 'The dashboard lists every project'], ['AC-002', 'The export downloads a CSV file']]));
  const { id, bundle } = begin(fx, { drivers: 'browser', log: fx.logPath }, 'feature: The dashboard lists projects\n');
  const binding = JSON.parse(fs.readFileSync(path.join(repositoryDirectory(fx), `${id}.binding.json`), 'utf8'));
  assert.deepEqual(binding.criteria.map((criterion) => criterion.id), ['AC-001', 'AC-002', 'AC-003']);
  ok(call(fx, 'render', { report: id, verdict: 'FAIL', log: fx.logPath }));
  assert.deepEqual(manifestOf(bundle).coverage.criteria.map((criterion) => [criterion.id, criterion.state]), [['AC-001', 'missing'], ['AC-002', 'missing'], ['AC-003', 'fail']]);
  const deprecated = chainFixture();
  attest(deprecated, 'AC-003', 'fail', 'Projects were listed unsorted');
  fs.writeFileSync(path.join(deprecated.root, '.zensu', 'plans', `${STEM}.md`), planText([['AC-001', 'The dashboard lists every project'], ['AC-002', 'The export downloads a CSV file'], ['AC-003', '(deprecated) Projects are sorted by name']]));
  const listed = begin(deprecated, { drivers: 'browser', log: deprecated.logPath }, 'feature: The dashboard lists projects\n');
  const ids = JSON.parse(fs.readFileSync(path.join(repositoryDirectory(deprecated), `${listed.id}.binding.json`), 'utf8')).criteria.map((criterion) => criterion.id);
  assert.deepEqual(ids, ['AC-001', 'AC-002', 'AC-003']);
});

test('an add refused at the manifest cap leaves no file in the bundle', () => {
  const fx = fixture();
  const { id, bundle } = begin(fx);
  const file = runFile(fx, 'late.png', png(4, 3, 7));
  refused(call(fx, 'add', { report: id, kind: 'image', file }, 'The page after the last step', { limits: { maxManifestBytes: 2000 } }), /^the report would outgrow the manifest cap of 2000 bytes/);
  assert.deepEqual(fs.readdirSync(path.join(bundle, 'files')), []);
  ok(call(fx, 'add', { report: id, kind: 'image', file }, 'The page after the last step'));
  assert.equal(fs.readdirSync(path.join(bundle, 'files')).length, 1);
});

test('a PASS that rests on no passed criterion and no passed P0 row is refused', () => {
  const fx = fixture();
  const { id, bundle } = begin(fx, { drivers: 'api' }, 'feature: A feature without criteria\n');
  ok(step(fx, id, { priority: 'P1', driver: 'api' }));
  refused(call(fx, 'render', { report: id, verdict: 'PASS' }), /^REPORT REFUSED — verdict\.empty at verdict: the stated verdict PASS rests on no passed criterion and no passed P0 row \| remedy: state PARTIAL, or verify at least one criterion or P0 row first$/);
  ok(step(fx, id, { driver: 'api' }));
  ok(call(fx, 'render', { report: id, verdict: 'PASS' }));
  assert.equal(manifestOf(bundle).verdict, 'PASS');
});

test('a local matrix PASS over a tree that changed during the run is refused and the tree at begin is shown', () => {
  const fx = fixture();
  const { id, bundle } = begin(fx);
  addImage(fx, id);
  ok(step(fx, id, { criteria: 'AC-001,AC-002', evidence: 'e1' }));
  fs.writeFileSync(path.join(fx.root, 'a.txt'), 'changed during the run\n');
  refused(call(fx, 'render', { report: id, verdict: 'PASS' }), /^REPORT REFUSED — verdict\.tree-changed at verdict: the stated verdict PASS rests on rows recorded while the working tree changed \([0-9a-f]{12} at --report-begin, [0-9a-f]{12} at --report-render\) \| remedy: state PARTIAL, or begin a new report and run the matrix again on the current tree$/);
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL' }));
  const { target } = manifestOf(bundle);
  assert.notEqual(target.begin_tree, target.tree);
  assert.ok(fs.readFileSync(path.join(bundle, 'index.html'), 'utf8').includes(`<tr><th>Tree at begin</th><td><code>${target.begin_tree}</code></td></tr>`));
  const steady = fixture();
  const kept = begin(steady);
  addImage(steady, kept.id);
  ok(step(steady, kept.id, { criteria: 'AC-001,AC-002', evidence: 'e1' }));
  ok(call(steady, 'render', { report: kept.id, verdict: 'PASS' }));
  assert.ok(!fs.readFileSync(path.join(kept.bundle, 'index.html'), 'utf8').includes('Tree at begin'));
  const distant = fixture();
  const deployed = begin(distant, { mode: 'remote', origin: 'https://preview.example.com' });
  addImage(distant, deployed.id);
  ok(step(distant, deployed.id, { criteria: 'AC-001,AC-002', evidence: 'e1' }));
  fs.writeFileSync(path.join(distant.root, 'a.txt'), 'changed during the run\n');
  ok(call(distant, 'render', { report: deployed.id, verdict: 'PASS' }));
  const remoteTarget = manifestOf(deployed.bundle).target;
  assert.notEqual(remoteTarget.begin_tree, remoteTarget.tree);
  assert.ok(!manifestOf(deployed.bundle).sections.limitations.some((line) => line.startsWith('The working tree')), manifestOf(deployed.bundle).sections.limitations.join('\n'));
  const plain = fixture({ root: tempDir('plain-project') });
  const unmeasured = begin(plain, { drivers: 'api' });
  ok(call(plain, 'render', { report: unmeasured.id, verdict: 'PARTIAL' }));
  const manifest = manifestOf(unmeasured.bundle);
  assert.equal(manifest.target.tree, null);
  assert.equal(manifest.target.begin_tree, null);
  assert.ok(manifest.sections.limitations.includes('The working tree was not fingerprinted at --report-begin (not a git work tree), so a change during the run cannot be ruled out.'), manifest.sections.limitations.join('\n'));
  assert.ok(!unmeasured.lines.some((line) => line.includes('will refuse a PASS')), unmeasured.lines.join('\n'));
});

test('a local matrix PASS is refused when the tree at begin or at render cannot be fingerprinted inside git, and a PARTIAL says so', (t) => {
  const late = fixture();
  const atBegin = t.mock.method(evr, 'computeTree', () => ({ tree: null, reason: 'git timed out' }));
  const unmeasured = begin(late);
  atBegin.mock.restore();
  addImage(late, unmeasured.id);
  ok(step(late, unmeasured.id, { criteria: 'AC-001,AC-002', evidence: 'e1' }));
  assert.ok(unmeasured.lines.includes('zensu evidence report: the working tree could not be fingerprinted at --report-begin (git timed out), so --report-render will refuse a PASS; make the tree fingerprintable and begin again'), unmeasured.lines.join('\n'));
  const far = fixture();
  const remoteDown = t.mock.method(evr, 'computeTree', () => ({ tree: null, reason: 'git timed out' }));
  const remote = begin(far, { mode: 'remote', origin: 'https://preview.example.com' });
  remoteDown.mock.restore();
  const chained = chainFixture();
  const chainDown = t.mock.method(evr, 'computeTree', () => ({ tree: null, reason: 'git timed out' }));
  const inChain = begin(chained, { drivers: 'browser', log: chained.logPath }, 'feature: The dashboard lists projects\n');
  chainDown.mock.restore();
  for (const [owner, started] of [[far, remote], [chained, inChain]]) {
    assert.equal(JSON.parse(fs.readFileSync(path.join(repositoryDirectory(owner), `${started.id}.binding.json`), 'utf8')).begin_failure, 'git timed out');
    assert.ok(!started.lines.some((line) => line.includes('will refuse a PASS')), started.lines.join('\n'));
  }
  refused(call(late, 'render', { report: unmeasured.id, verdict: 'PASS' }), /^REPORT REFUSED — verdict\.tree-changed at verdict: the stated verdict PASS rests on rows recorded on a tree that could not be fingerprinted at --report-begin \(git timed out\), so the tree [0-9a-f]{12} at --report-render cannot be compared with it/);
  ok(call(late, 'render', { report: unmeasured.id, verdict: 'PARTIAL' }));
  assert.equal(manifestOf(unmeasured.bundle).target.begin_tree, null);
  const beginOnly = 'The working tree was not fingerprinted at --report-begin (git timed out), so a change during the run cannot be ruled out.';
  const outsideOnly = 'The working tree was not fingerprinted at --report-begin (not a git work tree), so a change during the run cannot be ruled out.';
  const bothBlind = 'The working tree was not fingerprinted at --report-begin (git timed out), and could not be fingerprinted at --report-render either (git timed out), so a change during the run cannot be ruled out.';
  assert.ok(manifestOf(unmeasured.bundle).sections.limitations.includes(beginOnly), manifestOf(unmeasured.bundle).sections.limitations.join('\n'));
  const blind = fixture();
  const everywhere = t.mock.method(evr, 'computeTree', () => ({ tree: null, reason: 'git timed out' }));
  const neither = begin(blind);
  addImage(blind, neither.id);
  ok(step(blind, neither.id, { criteria: 'AC-001,AC-002', evidence: 'e1' }));
  refused(call(blind, 'render', { report: neither.id, verdict: 'PASS' }), /^REPORT REFUSED — verdict\.tree-changed at verdict: the stated verdict PASS rests on rows recorded on a tree that could not be fingerprinted at --report-begin \(git timed out\), and the tree at --report-render could not be fingerprinted either \(git timed out\) \| remedy: state PARTIAL, or begin a new report once the working tree can be fingerprinted$/);
  ok(call(blind, 'render', { report: neither.id, verdict: 'PARTIAL' }));
  everywhere.mock.restore();
  const unseen = manifestOf(neither.bundle).target;
  assert.deepEqual([unseen.begin_tree, unseen.tree, typeof unseen.head], [null, null, 'string']);
  assert.ok(manifestOf(neither.bundle).sections.limitations.includes(bothBlind), manifestOf(neither.bundle).sections.limitations.join('\n'));
  const left = fixture();
  const beforeGit = t.mock.method(evr, 'computeTree', () => ({ tree: null, reason: 'git timed out' }));
  const gone = begin(left);
  beforeGit.mock.restore();
  addImage(left, gone.id);
  ok(step(left, gone.id, { criteria: 'AC-001,AC-002', evidence: 'e1' }));
  const gitRead = evr.git;
  const noGit = t.mock.method(evr, 'git', (root, args, options) => (args.includes('--is-inside-work-tree') ? { ok: false, reason: 'git timed out' } : gitRead(root, args, options)));
  refused(call(left, 'render', { report: gone.id, verdict: 'PASS' }), /^REPORT REFUSED — verdict\.tree-changed at verdict: the stated verdict PASS rests on rows recorded on a tree that could not be fingerprinted at --report-begin \(git timed out\), and the tree at --report-render could not be fingerprinted either \(git timed out\) \| remedy: /);
  ok(call(left, 'render', { report: gone.id, verdict: 'PARTIAL' }));
  noGit.mock.restore();
  const away = manifestOf(gone.bundle).target;
  assert.deepEqual([away.repository, away.branch, away.head, away.tree, away.begin_tree, away.dirty], [null, null, null, null, null, null]);
  assert.ok(manifestOf(gone.bundle).sections.limitations.includes(bothBlind), manifestOf(gone.bundle).sections.limitations.join('\n'));
  const lost = fixture();
  const probeDown = t.mock.method(evr, 'git', (root, args, options) => (args.includes('--is-inside-work-tree') ? { ok: false, reason: 'git timed out' } : gitRead(root, args, options)));
  const both = begin(lost);
  addImage(lost, both.id);
  ok(step(lost, both.id, { criteria: 'AC-001,AC-002', evidence: 'e1' }));
  refused(call(lost, 'render', { report: both.id, verdict: 'PASS' }), /could not be fingerprinted at --report-begin \(git timed out\), and the tree at --report-render could not be fingerprinted either \(git timed out\) \| remedy: /);
  ok(call(lost, 'render', { report: both.id, verdict: 'PARTIAL' }));
  probeDown.mock.restore();
  assert.ok(both.lines.some((line) => line.includes('(git timed out), so --report-render will refuse a PASS')), both.lines.join('\n'));
  const lostTarget = manifestOf(both.bundle).target;
  assert.deepEqual([lostTarget.repository, lostTarget.head, lostTarget.tree, lostTarget.begin_tree], [null, null, null, null]);
  assert.equal(JSON.parse(fs.readFileSync(path.join(repositoryDirectory(lost), `${both.id}.binding.json`), 'utf8')).begin_failure, 'git timed out');
  assert.ok(manifestOf(both.bundle).sections.limitations.includes(bothBlind), manifestOf(both.bundle).sections.limitations.join('\n'));
  const pruned = fixture();
  const measuredAtBegin = begin(pruned);
  addImage(pruned, measuredAtBegin.id);
  ok(step(pruned, measuredAtBegin.id, { criteria: 'AC-001,AC-002', evidence: 'e1' }));
  const outsideAnswer = gitRead(tempDir('no-repo'), ['rev-parse', '--is-inside-work-tree']);
  assert.equal(evr.outsideWorkTree(outsideAnswer), true);
  const prunedGit = t.mock.method(evr, 'git', (root, args, options) => (args.includes('--is-inside-work-tree') ? outsideAnswer : gitRead(root, args, options)));
  refused(call(pruned, 'render', { report: measuredAtBegin.id, verdict: 'PASS' }), /not fingerprinted at --report-render: not a git work tree\) \| remedy: /);
  ok(call(pruned, 'render', { report: measuredAtBegin.id, verdict: 'PARTIAL' }));
  prunedGit.mock.restore();
  assert.ok(manifestOf(measuredAtBegin.bundle).sections.limitations.some((line) => line.startsWith('The working tree could not be fingerprinted at --report-render (not a git work tree), so a change since ')), manifestOf(measuredAtBegin.bundle).sections.limitations.join('\n'));
  const flaky = fixture();
  const treeProbeDown = t.mock.method(evr, 'computeTree', () => ({ tree: null, reason: 'not a git work tree' }));
  const insideGit = begin(flaky);
  treeProbeDown.mock.restore();
  assert.ok(insideGit.lines.some((line) => line.includes('(git failed), so --report-render will refuse a PASS')), insideGit.lines.join('\n'));
  const flakyPath = path.join(repositoryDirectory(flaky), `${insideGit.id}.binding.json`);
  assert.deepEqual([JSON.parse(fs.readFileSync(flakyPath, 'utf8')).begin_failure, typeof JSON.parse(fs.readFileSync(flakyPath, 'utf8')).target.head], ['git failed', 'string']);
  addImage(flaky, insideGit.id);
  ok(step(flaky, insideGit.id, { criteria: 'AC-001,AC-002', evidence: 'e1' }));
  fs.writeFileSync(flakyPath, JSON.stringify({ ...JSON.parse(fs.readFileSync(flakyPath, 'utf8')), begin_failure: 'not a git work tree' }));
  const flakyGit = t.mock.method(evr, 'git', (root, args, options) => (args.includes('--is-inside-work-tree') ? { ok: false, reason: 'git timed out' } : gitRead(root, args, options)));
  refused(call(flaky, 'render', { report: insideGit.id, verdict: 'PASS' }), /could not be fingerprinted at --report-begin \(not a git work tree\), and the tree at --report-render could not be fingerprinted either \(git timed out\) \| remedy: /);
  flakyGit.mock.restore();
  const plain = fixture({ root: tempDir('plain-project') });
  const outside = begin(plain, { drivers: 'api' });
  addImage(plain, outside.id);
  ok(step(plain, outside.id, { criteria: 'AC-001,AC-002', evidence: 'e1' }));
  ok(call(plain, 'render', { report: outside.id, verdict: 'PASS' }));
  assert.deepEqual([manifestOf(outside.bundle).verdict, manifestOf(outside.bundle).target.head, manifestOf(outside.bundle).target.tree], ['PASS', null, null]);
  assert.deepEqual(manifestOf(outside.bundle).sections.limitations.filter((line) => line.startsWith('The working tree ')), [outsideOnly]);
  assert.equal(JSON.parse(fs.readFileSync(path.join(repositoryDirectory(plain), `${outside.id}.binding.json`), 'utf8')).begin_failure, 'not a git work tree');
  const fx = fixture();
  const { id, bundle } = begin(fx);
  addImage(fx, id);
  ok(step(fx, id, { criteria: 'AC-001,AC-002', evidence: 'e1' }));
  const atRender = t.mock.method(evr, 'computeTree', () => ({ tree: null, reason: 'git timed out' }));
  refused(call(fx, 'render', { report: id, verdict: 'PASS' }), /^REPORT REFUSED — verdict\.tree-changed at verdict: the stated verdict PASS rests on rows recorded on a tree that could not be checked at --report-render \([0-9a-f]{12} at --report-begin, not fingerprinted at --report-render: git timed out\) \| remedy: state PARTIAL, or render again once the working tree can be fingerprinted$/);
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL' }));
  atRender.mock.restore();
  const manifest = manifestOf(bundle);
  assert.equal(manifest.target.tree, null);
  assert.ok(manifest.sections.limitations.some((line) => /^The working tree could not be fingerprinted at --report-render \(git timed out\), so a change since [0-9a-f]{12} at --report-begin cannot be ruled out\.$/.test(line)), manifest.sections.limitations.join('\n'));
  const realTree = evr.computeTree;
  for (const [lowered, named] of [[{ untrackedMaxFiles: 0 }, 'more than 0 untracked files'], [{ untrackedMaxBytes: 1 }, 'untracked files exceed 0 MiB']]) {
    const each = fixture();
    const report = begin(each);
    addImage(each, report.id);
    ok(step(each, report.id, { criteria: 'AC-001,AC-002', evidence: 'e1' }));
    fs.writeFileSync(path.join(each.root, 'notes.txt'), 'written during the run\n');
    const limited = t.mock.method(evr, 'computeTree', (root, scratch, limits, options) => realTree(root, scratch, { ...limits, ...lowered }, options));
    refused(call(each, 'render', { report: report.id, verdict: 'PASS' }), new RegExp(`not fingerprinted at --report-render: ${named}\\) \\| remedy: `));
    ok(call(each, 'render', { report: report.id, verdict: 'PARTIAL' }));
    limited.mock.restore();
    assert.ok(manifestOf(report.bundle).sections.limitations.some((line) => line.startsWith(`The working tree could not be fingerprinted at --report-render (${named}), so a change since `)), manifestOf(report.bundle).sections.limitations.join('\n'));
  }
  const leaking = fixture();
  const report = begin(leaking);
  addImage(leaking, report.id);
  ok(step(leaking, report.id, { criteria: 'AC-001,AC-002', evidence: 'e1' }));
  const failing = t.mock.method(evr, 'computeTree', () => ({ tree: null, reason: 'git add failed: fatal: cannot read /private/secret-tree/index' }));
  refused(call(leaking, 'render', { report: report.id, verdict: 'PASS' }), /not fingerprinted at --report-render: git failed\) \| remedy: /);
  ok(call(leaking, 'render', { report: report.id, verdict: 'PARTIAL' }));
  failing.mock.restore();
  const written = fs.readFileSync(path.join(report.bundle, 'manifest.json'), 'utf8') + fs.readFileSync(path.join(report.bundle, 'index.html'), 'utf8');
  assert.ok(written.includes('at --report-render (git failed), so a change since'), written);
  assert.ok(!written.includes('secret-tree'));
});

test('a chain report whose tree cannot be fingerprinted at render marks each record tree unverified and says why', (t) => {
  const fx = chainFixture();
  attest(fx, 'AC-001', 'pass', 'Opened the dashboard; all four projects are listed');
  const { id, bundle } = begin(fx, { drivers: 'browser', log: fx.logPath }, 'feature: The dashboard lists projects\n');
  addImage(fx, id, 'dashboard.png');
  ok(step(fx, id, { criteria: 'AC-001', evidence: 'e1' }));
  const timedOut = t.mock.method(evr, 'computeTree', () => ({ tree: null, reason: 'git timed out' }));
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL', log: fx.logPath }));
  timedOut.mock.restore();
  const manifest = manifestOf(bundle);
  const first = manifest.coverage.criteria.find((criterion) => criterion.id === 'AC-001');
  assert.equal(first.state, 'pass');
  assert.match(first.note, /^tree unverified; /);
  assert.ok(manifest.sections.limitations.includes('The acceptance states could not be compared with the working tree at --report-render (git timed out), so each criterion shows its newest record, whatever tree that record was taken on.'), manifest.sections.limitations.join('\n'));
  const leaky = chainFixture();
  attest(leaky, 'AC-001', 'pass', 'Opened the dashboard; all four projects are listed');
  const started = begin(leaky, { drivers: 'browser', log: leaky.logPath }, 'feature: The dashboard lists projects\n');
  addImage(leaky, started.id, 'dashboard.png');
  ok(step(leaky, started.id, { criteria: 'AC-001', evidence: 'e1' }));
  const failing = t.mock.method(evr, 'computeTree', () => ({ tree: null, reason: 'git add failed: fatal: cannot read /private/secret-tree/index' }));
  ok(call(leaky, 'render', { report: started.id, verdict: 'PARTIAL', log: leaky.logPath }));
  failing.mock.restore();
  const written = fs.readFileSync(path.join(started.bundle, 'manifest.json'), 'utf8') + fs.readFileSync(path.join(started.bundle, 'index.html'), 'utf8');
  assert.ok(manifestOf(started.bundle).sections.limitations.includes('The acceptance states could not be compared with the working tree at --report-render (git failed), so each criterion shows its newest record, whatever tree that record was taken on.'), manifestOf(started.bundle).sections.limitations.join('\n'));
  assert.ok(!written.includes('secret-tree'), written);
  const loose = chainFixture({ root: tempDir('chain-outside') });
  attest(loose, 'AC-001', 'pass', 'Opened the dashboard; all four projects are listed');
  const looseReport = begin(loose, { drivers: 'browser', log: loose.logPath }, 'feature: The dashboard lists projects\n');
  addImage(loose, looseReport.id, 'dashboard.png');
  ok(step(loose, looseReport.id, { criteria: 'AC-001', evidence: 'e1' }));
  ok(call(loose, 'render', { report: looseReport.id, verdict: 'PARTIAL', log: loose.logPath }));
  assert.ok(manifestOf(looseReport.bundle).sections.limitations.includes('The acceptance states could not be compared with the working tree at --report-render (not a git work tree), so each criterion shows its newest record, whatever tree that record was taken on.'), manifestOf(looseReport.bundle).sections.limitations.join('\n'));
});

test('a text field holds exactly its cap, and a chain plan row longer than the criterion cap renders clipped', () => {
  const fx = fixture();
  const { id } = begin(fx);
  const file = runFile(fx, 'cap.png', png(4, 3, 9));
  const caps = { limits: { chars: { caption: 12 } } };
  ok(call(fx, 'add', { report: id, kind: 'image', file }, 'x'.repeat(12), caps));
  refused(call(fx, 'add', { report: id, kind: 'image', file }, 'x'.repeat(13), caps), /^the caption on stdin exceeds 12 characters; /);
  const chain = chainFixture();
  const long = Array.from({ length: 70 }, (_, index) => `word${index}`).join(' ');
  assert.ok(long.length > er.LIMITS.chars.criterion);
  fs.writeFileSync(path.join(chain.root, '.zensu', 'plans', `${STEM}.md`), planText([['AC-001', long], ['AC-002', 'The export downloads a CSV file']]));
  const started = begin(chain, { drivers: 'browser', log: chain.logPath }, 'feature: The dashboard lists projects\n');
  const clipped = `${long.slice(0, er.LIMITS.chars.criterion - 1).trimEnd()}\u2026`;
  const binding = JSON.parse(fs.readFileSync(path.join(repositoryDirectory(chain), `${started.id}.binding.json`), 'utf8'));
  assert.equal(binding.criteria[0].text, clipped);
  ok(call(chain, 'render', { report: started.id, verdict: 'PARTIAL', log: chain.logPath }));
  assert.equal(manifestOf(started.bundle).coverage.criteria[0].text, clipped);
});

test('chain mode refuses a renamed plan, a missing plan or receipt and an untrusted newest record, and ignores FR rows', () => {
  const fx = chainFixture();
  const planPath = path.join(fx.root, '.zensu', 'plans', `${STEM}.md`);
  fs.writeFileSync(planPath, planText([
    ['AC-001', 'The dashboard lists every project'],
    ['FR-001', 'The service logs every export'],
    ['AC-002', 'The export downloads a CSV file'],
  ]));
  const { id, bundle } = begin(fx, { drivers: 'browser', log: fx.logPath }, 'feature: The dashboard lists projects\n');
  const binding = JSON.parse(fs.readFileSync(path.join(repositoryDirectory(fx), `${id}.binding.json`), 'utf8'));
  assert.deepEqual(binding.criteria.map((criterion) => criterion.id), ['AC-001', 'AC-002'], 'an FR row is no criterion');
  addImage(fx, id, 'dashboard.png');
  ok(step(fx, id, { criteria: 'AC-001', evidence: 'e1' }));
  const renamedStem = '2026-11-09-0300_build-renamed';
  const renamedLog = path.join(fx.root, '.zensu', 'logs', `${renamedStem}.log`);
  fs.writeFileSync(renamedLog, 'BUILD STARTED\n');
  fs.copyFileSync(planPath, path.join(fx.root, '.zensu', 'plans', `${renamedStem}.md`));
  const receipt = fs.readFileSync(fx.receiptPath, 'utf8');
  fs.writeFileSync(fx.receiptPath, JSON.stringify({ ...JSON.parse(receipt), log: `.zensu/logs/${renamedStem}.log` }));
  refused(call(fx, 'render', { report: id, verdict: 'PARTIAL', log: renamedLog }), new RegExp(`^the chain's plan is now \\.zensu/plans/${renamedStem}\\.md, but report ${id} began on \\.zensu/plans/${STEM}\\.md; begin a new report$`));
  fs.writeFileSync(fx.receiptPath, receipt);
  fs.renameSync(planPath, `${planPath}.moved`);
  refused(call(fx, 'render', { report: id, verdict: 'PARTIAL', log: fx.logPath }), new RegExp(`^the plan \\.zensu/plans/${STEM}\\.md does not exist$`));
  fs.renameSync(`${planPath}.moved`, planPath);
  fs.renameSync(fx.receiptPath, `${fx.receiptPath}.moved`);
  refused(call(fx, 'render', { report: id, verdict: 'PARTIAL', log: fx.logPath }), /^no edit-landing receipt exists for this chain; run the Phase 6 step 5b Edit Landing Audit first/);
  fs.renameSync(`${fx.receiptPath}.moved`, fx.receiptPath);
  attest(fx, 'AC-001', 'pass', 'Opened the dashboard; all four projects are listed');
  const untrusted = path.join(av.storeLocations(fx.data, SESSION).records, 'av1_9999999999999_ffffffffffff.json');
  fs.writeFileSync(untrusted, '{');
  refused(call(fx, 'render', { report: id, verdict: 'PARTIAL', log: fx.logPath }), /^the acceptance states could not be read \(invalid: the newest acceptance record cannot be trusted \(av1_9999999999999_ffffffffffff: unparseable\); verify again\)$/);
  fs.unlinkSync(untrusted);
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL', log: fx.logPath }));
  assert.deepEqual(manifestOf(bundle).coverage.criteria.map((criterion) => [criterion.id, criterion.state]), [['AC-001', 'pass'], ['AC-002', 'missing']]);
});

test('chain mode reports a dropped partial criterion as partial and a plan without an active criterion as empty', () => {
  const fx = chainFixture();
  attest(fx, 'AC-001', 'pass', 'Opened the dashboard; all four projects are listed');
  attest(fx, 'AC-002', 'pass', 'Downloaded the CSV export');
  attest(fx, 'AC-003', 'partial', 'Only the first page was checked');
  fs.writeFileSync(path.join(fx.root, '.zensu', 'plans', `${STEM}.md`), planText([
    ['AC-001', 'The dashboard lists every project'],
    ['AC-002', 'The export downloads a CSV file'],
    ['AC-003', '(deprecated) Projects are sorted by name'],
  ]));
  const { id, bundle } = begin(fx, { drivers: 'browser', log: fx.logPath }, 'feature: The dashboard lists projects\n');
  addImage(fx, id, 'dashboard.png');
  ok(step(fx, id, { criteria: 'AC-001,AC-002', evidence: 'e1' }));
  refused(call(fx, 'render', { report: id, verdict: 'PASS', log: fx.logPath }), /verdict\.contradiction at verdict: the stated verdict PASS needs every in-scope criterion and every P0 row passed: AC-003 partial/);
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL', log: fx.logPath }));
  const row = manifestOf(bundle).coverage.criteria.find((criterion) => criterion.id === 'AC-003');
  assert.equal(row.state, 'partial');
  assert.equal(row.note, 'deprecated while its newest verdict is partial; Only the first page was checked');
  const empty = chainFixture();
  fs.writeFileSync(path.join(empty.root, '.zensu', 'plans', `${STEM}.md`), planText([['AC-001', '(deprecated) The legacy grid view renders']]));
  const bare = begin(empty, { drivers: 'browser', log: empty.logPath }, 'feature: The legacy grid view is gone\n');
  refused(call(empty, 'render', { report: bare.id, verdict: 'PASS', log: empty.logPath }), /^REPORT REFUSED — verdict\.empty at verdict/);
  ok(call(empty, 'render', { report: bare.id, verdict: 'PARTIAL', log: empty.logPath }));
  assert.deepEqual(manifestOf(bare.bundle).coverage.criteria, []);
});

test('stdin passes at exactly its cap and is refused one byte above it, in process and through the transport', () => {
  const fx = fixture();
  const { id } = begin(fx);
  const signal = { report: id, kind: 'signal', source: 'console', class: 'error' };
  const atCap = 'x'.repeat(er.LIMITS.maxStdinBytes);
  const capped = refused(call(fx, 'add', signal, atCap), /^the signal message on stdin exceeds 500 characters$/);
  assert.doesNotMatch(capped.errors.join('\n'), /65536 bytes/);
  refused(call(fx, 'add', signal, `${atCap}x`), /^stdin exceeds 65536 bytes$/);
  const directory = tempDir('stdin-edge');
  fs.writeFileSync(path.join(directory, 'stdin'), atCap);
  assert.equal(er.transportOptions({ ZENSU_ERP_DIR: directory }).stdinText, atCap);
  fs.writeFileSync(path.join(directory, 'stdin'), `${atCap}x`);
  const carried = er.transportOptions({ ZENSU_ERP_DIR: directory });
  assert.equal(carried.stdinText.length, er.LIMITS.maxStdinBytes + 1, 'the transport carries one byte past the cap so the verb refuses it');
  refused(call(fx, 'add', signal, carried.stdinText), /^stdin exceeds 65536 bytes$/);
});

test('the report-side secret rules refuse authorization values, JWTs, URL credentials, session cookies and API keys', () => {
  const fx = fixture();
  const { id } = begin(fx);
  const shapes = [
    ['Authorization', ': ', 'Basic ', 'dXNlcjpwYXNzd29yZA'],
    ['Bearer ', 'k3yValue', '1234', 'abcdefgh'],
    ['eyJ', 'hbGciOiJIUzI1NiJ9', '.', 'eyJzdWIiOiIxIn0', '.', 'c2lnbmF0dXJlMDA'],
    ['https://', 'deploy', ':', 'hunter2pass', '@', 'git.example.com/repo'],
    ['Cookie', ': ', 'session', '=', 'abcdef0123456789xyz'],
    ['X-Api-Key', ': ', 'k_live_', '0123456789'],
    ['Authorization', ': ', 'k3yValue', '1234', 'abcdefgh'],
    ['Authorization', ': ', 'Custom ', 'Zx9Lm3Np', '8Rt5Vw1'],
    ['"authorization"', ': ', '"', 'Token ', 'Zx9Lm3Np', '8Rt5Vw1', '"'],
    ['Cookie', ': ', 'theme=dark; ', 'session', '=', 'abcdef0123456789xyz'],
    ['"cookie"', ': ', '"', 'sid', '=', 'abcdef0123456789xyz', '"'],
    ['"x-api-key"', ': ', '"', 'k_live_', '0123456789', '"'],
  ].map((parts) => parts.join(''));
  const signal = { report: id, kind: 'signal', source: 'network', class: 'request' };
  for (const shape of shapes) {
    refused(call(fx, 'add', signal, `The request sent ${shape} upstream`), /^the signal message on stdin matches a secret pattern; describe it without the value$/);
    refused(call(fx, 'add', { report: id, kind: 'text', file: runFile(fx, 'headers.txt', `GET /api\n${shape}\n`) }, 'The request headers'), /^the text file matches a secret pattern; capture it without the value$/);
  }
  for (const benign of ['The Authorization header was missing', 'Bearer tokens expire after an hour', 'Opened https://example.com/login', 'cookie: theme=dark', 'The x-api-key header is required', 'authorization: required']) {
    ok(call(fx, 'add', signal, benign));
  }
});

const PLACEHOLDER_SHAPES = ['Authorization: Bearer <access-token>', 'X-Api-Key: YOUR_API_KEY', 'https://<user>:<password>@git.example.com', 'Cookie: session=<session-id-value>'];

test('placeholder spellings of the report secret shapes pass as documentation, in a signal message and in a chain plan row', () => {
  const fx = fixture();
  const { id } = begin(fx);
  for (const shape of PLACEHOLDER_SHAPES) ok(call(fx, 'add', { report: id, kind: 'signal', source: 'network', class: 'request' }, `The docs show ${shape}`));
  const chained = chainFixture();
  fs.writeFileSync(path.join(chained.root, '.zensu', 'plans', `${STEM}.md`), planText(PLACEHOLDER_SHAPES.map((shape, index) => [`AC-00${index + 1}`, `A request with ${shape} is answered 200`])));
  const started = begin(chained, { drivers: 'browser', log: chained.logPath }, 'feature: The API accepts documented headers\n');
  ok(call(chained, 'render', { report: started.id, verdict: 'PARTIAL', log: chained.logPath }));
  assert.deepEqual(manifestOf(started.bundle).coverage.criteria.map((criterion) => criterion.text), PLACEHOLDER_SHAPES.map((shape) => `A request with ${shape} is answered 200`));
});

test('a text file whose secret label and value sit on two lines is refused', () => {
  const fx = fixture();
  const { id } = begin(fx);
  refused(call(fx, 'add', { report: id, kind: 'text', file: runFile(fx, 'env.txt', `GET /api\n${SPLIT_KEY}:\n${SPLIT_VALUE}\n`) }, 'The environment dump'), /^the text file matches a secret pattern; capture it without the value$/);
});

test('a request path or consent route that only resembles a local path is recorded, one naming the project root or home is refused, and a text keeps neither', () => {
  const fx = fixture();
  const { id, bundle } = begin(fx);
  for (const route of ['/home', '/root/admin', '/Users/42/edit']) ok(call(fx, 'add', { report: id, kind: 'request', method: 'GET', path: route, status: '200' }));
  ok(call(fx, 'add', { report: id, kind: 'request', method: 'GET', path: '/root/settings', status: '200' }, '', { home: '/root' }));
  for (const route of [`/@fs${fx.root}/src/App.tsx`, `${fx.home}/notes`]) {
    refused(call(fx, 'add', { report: id, kind: 'request', method: 'GET', path: route, status: '200' }), /^--path names a local path; describe it without the value$/);
  }
  ok(call(fx, 'add', { report: id, kind: 'signal', source: 'network', class: 'request' }, `GET http://localhost:5173/@fs${fx.root}/src/App.tsx failed`));
  ok(call(fx, 'add', { report: id, kind: 'signal', source: 'console', class: 'note' }, `Captured from ${fx.root}.`));
  ok(call(fx, 'add', { report: id, kind: 'signal', source: 'console', class: 'note' }, `Captured from ${fx.root}.`, { home: path.dirname(fx.root) }));
  ok(call(fx, 'add', { report: id, kind: 'signal', source: 'console', class: 'note' }, `Copied to ${fx.root}.bak/x`));
  ok(call(fx, 'add', { report: id, kind: 'signal', source: 'console', class: 'note' }, `Captured from ${fx.root}...`));
  ok(call(fx, 'add', { report: id, kind: 'signal', source: 'console', class: 'note' }, `Captured from ${fx.root}...`, { home: path.dirname(fx.root) }));
  refused(call(fx, 'add', { report: id, kind: 'request', method: 'GET', path: `/@fs${fx.root}.`, status: '200' }), /^--path names a local path; describe it without the value$/);
  refused(call(fx, 'render', { report: id, verdict: 'PARTIAL' }, `consent: http://localhost:3000 /@fs${fx.home}/x asked\n`), /^the route of a consent line names a local path; describe it without the value$/);
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL' }, 'consent: http://localhost:3000 /home asked\nconsent: http://localhost:3000 /root/admin asked\n'));
  const manifest = manifestOf(bundle);
  assert.deepEqual(['e1', 'e2', 'e3', 'e4'].map((item) => manifest.evidence[item].path), ['/home', '/root/admin', '/Users/42/edit', '/root/settings']);
  assert.equal(manifest.evidence.e5.message, 'GET http://localhost:5173/@fs<project>/src/App.tsx failed');
  assert.deepEqual([manifest.evidence.e6.message, manifest.evidence.e7.message], ['Captured from <project>.', 'Captured from <project>.']);
  assert.ok(!manifest.evidence.e8.message.includes('<project>'), manifest.evidence.e8.message);
  assert.deepEqual([manifest.evidence.e9.message, manifest.evidence.e10.message], ['Captured from <project>...', 'Captured from <project>...']);
  assert.deepEqual(manifest.sections.consent.map((entry) => entry.route), ['/home', '/root/admin']);
});

test('the manifest and the binding are read schema first and a schema this reader does not know is named', () => {
  const faults = er.validateManifest({ schema: 'zensu-evidence-report/v2', extra: true, steps: 'none' });
  assert.deepEqual(faults.map((fault) => [fault.code, fault.at]), [['schema.version', 'schema']]);
  assert.equal(faults[0].message, 'the manifest names the schema zensu-evidence-report/v2, which this reader does not know');
  assert.equal(er.validateManifest({ schema: 'two words' })[0].message, `the manifest names no schema this reader knows; schema must be ${er.SCHEMA}`);
  const fx = fixture();
  const { id } = begin(fx);
  const bindingPath = path.join(repositoryDirectory(fx), `${id}.binding.json`);
  const binding = JSON.parse(fs.readFileSync(bindingPath, 'utf8'));
  fs.writeFileSync(bindingPath, JSON.stringify({ ...binding, schema: 'zensu-evidence-report-binding/v2', future: true }));
  assert.equal(ok(call(fx, 'list')).reports[0].state, 'schema zensu-evidence-report-binding/v2');
  refused(call(fx, 'add', { report: id, kind: 'request', method: 'GET', path: '/', status: '200' }), /^the binding of vr1_[0-9_a-f]+ is invalid \(the binding names the schema zensu-evidence-report-binding\/v2, which this reader does not know\)$/, 2);
  const checked = begin(fx);
  const checkedPath = path.join(repositoryDirectory(fx), `${checked.id}.binding.json`);
  const original = JSON.parse(fs.readFileSync(checkedPath, 'utf8'));
  assert.equal(original.begin_failure, null);
  assert.match(original.target.begin_tree, /^[0-9a-f]{40}$/);
  const request = { report: checked.id, kind: 'request', method: 'GET', path: '/', status: '200' };
  for (const [rewritten, problem] of [
    [{ ...original, begin_failure: 'git exploded' }, 'malformed begin failure'],
    [{ ...original, begin_failure: 'git timed out' }, 'the begin failure contradicts the begin tree'],
    [{ ...original, target: { ...original.target, begin_tree: null } }, 'the begin failure contradicts the begin tree'],
  ]) {
    fs.writeFileSync(checkedPath, JSON.stringify(rewritten));
    refused(call(fx, 'add', request), new RegExp(`^the binding of vr1_[0-9_a-f]+ is invalid \\(${problem}\\)$`), 2);
  }
  fs.writeFileSync(checkedPath, JSON.stringify(original));
  ok(call(fx, 'add', request));
  const drafted = begin(fx);
  const draftPath = path.join(repositoryDirectory(fx), `${drafted.id}.binding.json`);
  const draft = JSON.parse(fs.readFileSync(draftPath, 'utf8'));
  const zensu = { feature: '0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b', ref: 'AC-001' };
  draft.criteria[0].zensu = zensu;
  draft.criteria[1].zensu = { feature: 'not-a-feature', ref: 'AC-002' };
  fs.writeFileSync(draftPath, `${JSON.stringify(draft, null, 2)}\n`);
  refused(call(fx, 'render', { report: drafted.id, verdict: 'PARTIAL' }), /is invalid \(criteria\[1\]\.zensu\.feature: criteria\[1\]\.zensu\.feature must be a feature id\)$/, 2);
  draft.criteria[1].zensu = null;
  fs.writeFileSync(draftPath, `${JSON.stringify(draft, null, 2)}\n`);
  ok(call(fx, 'render', { report: drafted.id, verdict: 'PARTIAL' }));
  assert.deepEqual(manifestOf(drafted.bundle).coverage.criteria.map((criterion) => criterion.zensu), [zensu, null]);
});

test('the PNG decoder returns the exact pixels of every filter type for RGB and RGBA and refuses a pixel stream of the wrong length', () => {
  for (const channels of [3, 4]) {
    const width = 7;
    const height = 10;
    const stride = width * channels;
    const pixels = sampleBytes(stride * height, 40 + channels);
    for (const filters of [[0], [1], [2], [3], [4], [4, 3, 2, 1, 0], [1, 4, 0, 3, 2]]) {
      const facts = er.pngFacts(pngOf({ width, height, channels, pixels, filters }));
      assert.deepEqual([facts.reason, facts.width, facts.height, facts.channels, facts.icc], [undefined, width, height, channels, null]);
      assert.ok(Buffer.concat(er.decodePng(facts)).equals(pixels), `${channels} channels with the filters ${filters}`);
    }
    const stream = Buffer.concat(Array.from({ length: height }, (unused, line) => Buffer.concat([Buffer.from([0]), pixels.subarray(line * stride, (line + 1) * stride)])));
    const packed = zlib.deflateSync(stream);
    const split = er.pngFacts(pngOf({ width, height, channels, pixels, idat: [packed.subarray(0, 9), packed.subarray(9)] }));
    assert.equal(split.idat.length, 2);
    assert.ok(Buffer.concat(er.decodePng(split)).equals(pixels));
    const unknownFilter = Buffer.from(stream);
    unknownFilter[stride + 1] = 5;
    const broken = [stream.subarray(0, stream.length - 1), Buffer.concat([stream, Buffer.from([0])]), Buffer.alloc(0), unknownFilter].map((bytes) => zlib.deflateSync(bytes));
    for (const idat of [...broken, Buffer.from('not a zlib stream')]) {
      assert.equal(er.decodePng(er.pngFacts(pngOf({ width, height, channels, pixels, idat }))), null);
    }
  }
});

test('a PNG that libpng wrote with all five filter types decodes to the pixels libwebp decoded for the same image', () => {
  const facts = er.pngFacts(LIBPNG_FILTERS_PNG);
  assert.deepEqual([facts.reason, facts.width, facts.height, facts.channels], [undefined, 12, 10, 3]);
  const stream = zlib.inflateSync(Buffer.concat(facts.idat));
  assert.deepEqual([...new Set(Array.from({ length: 10 }, (unused, line) => stream[line * 37]))].sort(), [0, 1, 2, 3, 4]);
  assert.equal(hex(rgbaOf(Buffer.concat(er.decodePng(facts)), 3)), LIBPNG_FILTERS_RGBA);
});

test('the PNG facts name the first reason a PNG is outside what a lossless WebP can hold', () => {
  const width = 5;
  const height = 4;
  const base = { width, height, channels: 3, pixels: sampleBytes(width * height * 3, 7) };
  const facts = (spec, limits) => er.pngFacts(pngOf({ ...base, ...spec }), limits);
  const density = (across, down) => {
    const bytes = Buffer.alloc(9);
    bytes.writeUInt32BE(across, 0);
    bytes.writeUInt32BE(down, 4);
    bytes[8] = 1;
    return bytes;
  };
  const profile = sampleBytes(300, 3);
  assert.equal(facts({}).reason, undefined);
  assert.equal(facts({ depth: 16 }).reason, 'it is not an 8-bit truecolor image');
  for (const colour of [0, 3, 4]) assert.equal(facts({ colour }).reason, 'it is not an 8-bit truecolor image');
  assert.equal(facts({ interlace: 1 }).reason, 'it is interlaced');
  assert.equal(er.pngFacts(pngOf({ width: 16384, height: 1, pixels: Buffer.alloc(16384 * 3) })).reason, 'a side is longer than 16383 pixels, the limit of a WebP');
  assert.equal(er.pngFacts(pngOf({ width: 1, height: 16384, pixels: Buffer.alloc(16384 * 3) })).reason, 'a side is longer than 16383 pixels, the limit of a WebP');
  assert.equal(er.pngFacts(pngOf({ width: 16383, height: 1, pixels: Buffer.alloc(16383 * 3) })).reason, undefined);
  assert.equal(facts({}, { ...er.LIMITS, maxTranscodePixels: 19 }).reason, 'it holds more than 19 pixels');
  assert.equal(facts({}, { ...er.LIMITS, maxTranscodePixels: 20 }).reason, undefined);
  for (const type of ['tRNS', 'PLTE', 'bKGD', 'hIST', 'sPLT', 'cICP', 'mDCV', 'cLLI']) {
    assert.equal(facts({ extra: [[type, Buffer.alloc(3)]] }).reason, `it carries a ${type} chunk, which a WebP cannot hold`);
  }
  for (const type of ['gAMA', 'cHRM']) {
    assert.equal(facts({ extra: [[type, Buffer.alloc(4)]] }).reason, `it carries ${type} without sRGB or iCCP`);
    assert.equal(facts({ extra: [['sRGB', Buffer.from([0])], [type, Buffer.alloc(4)]] }).reason, undefined);
    assert.ok(facts({ extra: [[type, Buffer.alloc(4)], ['iCCP', profileChunk(profile)]] }).icc.equals(profile));
  }
  assert.equal(facts({ extra: [['sBIT', Buffer.from([8, 8, 8])], ['pHYs', density(5669, 5669)]] }).reason, undefined);
  assert.equal(facts({ extra: [['pHYs', density(5669, 2835)]] }).reason, 'its pHYs chunk does not declare square pixels');
  assert.equal(facts({ extra: [['pHYs', Buffer.alloc(8)]] }).reason, 'its pHYs chunk does not declare square pixels');
  assert.equal(facts({ extra: [['sRGB', Buffer.from([0])], ['sRGB', Buffer.from([0])]] }).reason, 'it repeats its sRGB chunk');
  assert.ok(facts({ extra: [['iCCP', profileChunk(profile)]] }).icc.equals(profile));
  const unreadable = [
    Buffer.from([0, 0, 1, 2]),
    Buffer.concat([Buffer.from('P3\u0000\u0001', 'latin1'), zlib.deflateSync(profile)]),
    Buffer.from('P3\u0000\u0000not a zlib stream', 'latin1'),
    Buffer.from(`${'n'.repeat(80)}\u0000\u0000`, 'latin1'),
  ];
  for (const data of unreadable) assert.equal(facts({ extra: [['iCCP', data]] }).reason, 'its ICC profile cannot be read');
  assert.equal(facts({ extra: [['iCCP', profileChunk(profile)]] }, { ...er.LIMITS, maxProfileBytes: 299 }).reason, 'its ICC profile cannot be read');
});

test('the tool lookup takes the first absolute path entry that holds cwebp, needs dwebp beside it and refuses a pair inside the project', { skip: NO_STAND_IN_TOOLS }, () => {
  const project = tempDir('project');
  let asked = 0;
  const roots = () => {
    asked += 1;
    return [project];
  };
  const join = (...entries) => entries.join(path.delimiter);
  const good = standInTools();
  const found = { encoder: path.join(good.directory, 'cwebp'), decoder: path.join(good.directory, 'dwebp') };
  const empty = tempDir('empty');
  assert.deepEqual(er.findWebpTools(good.directory, roots), found);
  assert.deepEqual(er.findWebpTools(join('', 'relative/bin', '.', empty, path.join(empty, 'missing'), good.directory), roots), found);
  asked = 0;
  for (const value of [undefined, '', 'bin', join('', '.', 'tools/bin'), empty, path.join(empty, 'missing')]) assert.equal(er.findWebpTools(value, roots), null);
  assert.equal(asked, 0);
  const encoderOnly = standInTools({ dwebp: null });
  assert.equal(er.findWebpTools(join(encoderOnly.directory, good.directory), roots), null);
  const decoderOnly = standInTools({ cwebp: null });
  assert.deepEqual(er.findWebpTools(join(decoderOnly.directory, good.directory), roots), found);
  const plainFile = standInTools();
  fs.chmodSync(path.join(plainFile.directory, 'cwebp'), 0o644);
  assert.equal(er.findWebpTools(plainFile.directory, roots), null);
  assert.deepEqual(er.findWebpTools(join(plainFile.directory, good.directory), roots), found);
  const folder = standInTools({ cwebp: null });
  fs.mkdirSync(path.join(folder.directory, 'cwebp'));
  assert.deepEqual(er.findWebpTools(join(folder.directory, good.directory), roots), found);
  const plainDecoder = standInTools();
  fs.chmodSync(path.join(plainDecoder.directory, 'dwebp'), 0o644);
  assert.equal(er.findWebpTools(join(plainDecoder.directory, good.directory), roots), null);
  const inside = standInTools({}, path.join(project, 'node_modules', '.bin'));
  assert.equal(er.findWebpTools(join(inside.directory, good.directory), roots), null);
  assert.equal(er.findWebpTools(good.directory, () => [good.directory]), null);
  assert.equal(er.findWebpTools(good.directory, () => null), null);
  const linked = path.join(tempDir('links'), 'bin');
  fs.symlinkSync(good.directory, linked);
  assert.deepEqual(er.findWebpTools(linked, roots), found);
  const projectLink = path.join(project, 'tools');
  fs.symlinkSync(good.directory, projectLink);
  assert.equal(er.findWebpTools(projectLink, roots), null);
  const linkedTool = tempDir('linked-tool');
  fs.symlinkSync(path.join(inside.directory, 'cwebp'), path.join(linkedTool, 'cwebp'));
  fs.symlinkSync(path.join(good.directory, 'dwebp'), path.join(linkedTool, 'dwebp'));
  assert.equal(er.findWebpTools(linkedTool, roots), null);
  const open = standInTools();
  const openPair = { encoder: path.join(open.directory, 'cwebp'), decoder: path.join(open.directory, 'dwebp') };
  for (const mode of [0o777, 0o1777, 0o757]) {
    fs.chmodSync(open.directory, mode);
    asked = 0;
    assert.equal(er.findWebpTools(open.directory, roots), null, `a tool directory of mode ${mode.toString(8)}`);
    assert.equal(er.findWebpTools(join(open.directory, good.directory), roots), null);
    assert.equal(asked, 0);
  }
  fs.chmodSync(open.directory, 0o775);
  assert.deepEqual(er.findWebpTools(open.directory, roots), openPair);
  for (const tool of ['cwebp', 'dwebp']) {
    const loose = standInTools();
    fs.chmodSync(path.join(loose.directory, tool), 0o757);
    assert.equal(er.findWebpTools(loose.directory, roots), null, `a ${tool} that everyone may write`);
    fs.chmodSync(path.join(loose.directory, tool), 0o775);
    assert.deepEqual(er.findWebpTools(loose.directory, roots), { encoder: path.join(loose.directory, 'cwebp'), decoder: path.join(loose.directory, 'dwebp') });
  }
  fs.chmodSync(open.directory, 0o777);
  const viaLinks = tempDir('via-links');
  for (const tool of ['cwebp', 'dwebp']) fs.symlinkSync(path.join(open.directory, tool), path.join(viaLinks, tool));
  assert.equal(er.findWebpTools(viaLinks, roots), null);
  fs.chmodSync(open.directory, 0o755);
  assert.deepEqual(er.findWebpTools(viaLinks, roots), openPair);
  fs.chmodSync(viaLinks, 0o777);
  assert.equal(er.findWebpTools(viaLinks, roots), null);
});

test('add stores a verified lossless WebP in place of the PNG and records the captured file as its source', { skip: NO_STAND_IN_TOOLS }, () => {
  const fx = fixture();
  const { id, bundle } = begin(fx);
  const width = 9;
  const height = 6;
  const pixels = sampleBytes(width * height * 3, 11);
  const captured = pngOf({ width, height, pixels, filters: [4, 1, 2, 3, 0] });
  const tools = verifiedTools(width, height, pixels, 3);
  const scratch = scratchOf(fx);
  const hourAgo = new Date(Date.now() - 60 * 60 * 1000);
  for (const [name, time] of [['webp-stale', hourAgo], ['webp-fresh', new Date()], ['other', hourAgo]]) {
    fs.mkdirSync(path.join(scratch, name), { recursive: true });
    fs.utimesSync(path.join(scratch, name), time, time);
  }
  const coverageDirectory = process.env.NODE_V8_COVERAGE;
  process.env.ZENSU_ERP_CANARY = 'leaked';
  process.env.NODE_V8_COVERAGE = path.join(fx.data, 'coverage-canary');
  let added;
  try {
    added = ok(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, 'shot.png', captured), viewport: '1440x900@1' }, 'The settings page after a reload', { toolPath: ['relative', tools.directory].join(path.delimiter) }));
  } finally {
    delete process.env.ZENSU_ERP_CANARY;
    if (coverageDirectory === undefined) delete process.env.NODE_V8_COVERAGE;
    else process.env.NODE_V8_COVERAGE = coverageDirectory;
  }
  const sha = hex(tools.webp);
  assert.equal(added.lines[0], `zensu evidence report: e1 added to ${id} | image | image/webp ${width}x${height} | ${tools.webp.length} bytes | files/${sha}.webp | transcoded losslessly from a PNG of ${captured.length} bytes`);
  assert.deepEqual(fs.readdirSync(path.join(bundle, 'files')), [`${sha}.webp`]);
  assert.ok(fs.readFileSync(path.join(bundle, 'files', `${sha}.webp`)).equals(tools.webp));
  assert.deepEqual(bindingOf(fx, id).files[sha], { name: `files/${sha}.webp`, type: 'image/webp', bytes: tools.webp.length, width, height, viewport: { width: 1440, height: 900, scale: 1 }, source_sha256: hex(captured) });
  const calls = tools.calls();
  assert.deepEqual(calls.map((entry) => entry.tool), ['cwebp', 'dwebp']);
  const directory = calls[0].cwd;
  assert.equal(path.dirname(directory), scratch);
  assert.match(path.basename(directory), /^webp-/);
  assert.deepEqual(calls[0].args, [...ENCODER_FLAGS, '-o', path.join(directory, 'target.webp'), path.join(directory, 'source.png')]);
  assert.deepEqual(calls[1].args, [path.join(directory, 'target.webp'), '-pam', '-o', path.join(directory, 'decoded.pam')]);
  for (const entry of calls) {
    assert.equal(entry.cwd, directory);
    assert.equal(entry.program, path.join(tools.directory, entry.tool));
    assert.deepEqual(Object.keys(entry.env).filter((key) => !key.startsWith('__CF')), []);
  }
  assert.deepEqual(fs.readdirSync(scratch).sort(), ['other', 'webp-fresh']);
  const profile = sampleBytes(200, 5);
  const translucent = sampleBytes(width * height * 4, 12);
  const tagged = pngOf({ width, height, channels: 4, pixels: translucent, filters: [3, 4], extra: [['iCCP', profileChunk(profile)], ['tEXt', Buffer.from('Software\u0000Example capture tool', 'latin1')]] });
  const cleaned = er.sniff(tagged).clean();
  const withProfile = verifiedTools(width, height, translucent, 4, { profiles: [profile] });
  const second = ok(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, 'tagged.png', tagged) }, 'A translucent overlay', { toolPath: withProfile.directory }));
  const taggedSha = hex(withProfile.webp);
  assert.equal(second.lines[0], `zensu evidence report: e2 added to ${id} | image | image/webp ${width}x${height} | ${withProfile.webp.length} bytes | files/${taggedSha}.webp | dropped the metadata chunks tEXt | transcoded losslessly from a PNG of ${cleaned.length} bytes`);
  assert.equal(bindingOf(fx, id).files[taggedSha].source_sha256, hex(tagged));
  assert.deepEqual(privateScratch(fx), ['webp-fresh']);
  ok(step(fx, id, { criteria: 'AC-001', evidence: 'e1,e2' }));
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL' }));
  assert.deepEqual(Object.values(manifestOf(bundle).files).map((file) => file.type), ['image/webp', 'image/webp']);
  assert.match(fs.readFileSync(path.join(bundle, 'index.html'), 'utf8'), new RegExp(`<img src="files/${sha}\\.webp"`));
  assert.match(fs.readFileSync(ok(call(fx, 'export', { report: id })).target, 'utf8'), /<img src="data:image\/webp;base64,/);
});

test('a transcode that cannot be verified keeps the PNG and names the reason on the add line', { skip: NO_STAND_IN_TOOLS }, () => {
  const fx = fixture();
  const { id, bundle } = begin(fx);
  const width = 8;
  const height = 5;
  const profile = sampleBytes(120, 9);
  let count = 0;
  const attempt = (reason, called, prepare, spec = {}, overrides = {}) => {
    count += 1;
    const channels = spec.channels || 3;
    const pixels = sampleBytes(width * height * channels, 100 + count);
    const captured = pngOf({ width, height, channels, pixels, ...spec });
    const tools = verifiedTools(width, height, pixels, channels);
    prepare(tools, pixels, captured);
    const added = ok(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, `case-${count}.png`, captured) }, `Case ${count}`, { toolPath: tools.directory, ...overrides }));
    assert.equal(added.lines[0], `zensu evidence report: e${count} added to ${id} | image | image/png ${width}x${height} | ${captured.length} bytes | files/${hex(captured)}.png | PNG kept: ${reason}`);
    assert.equal(bindingOf(fx, id).files[hex(captured)].source_sha256, null);
    const started = tools.calls().map((entry) => entry.tool);
    if (typeof called === 'function') assert.ok(called(started), `${reason}: ${JSON.stringify(started)}`);
    else assert.deepEqual(started, called, reason);
    assert.deepEqual(privateScratch(fx), [], reason);
  };
  const differs = 'the decoded WebP differs from the PNG';
  const both = ['cwebp', 'dwebp'];
  attempt(differs, both, (tools, pixels) => {
    const rgba = rgbaOf(pixels, 3);
    rgba[rgba.length - 2] ^= 1;
    tools.plan('dwebp', { output: tools.answer('answer.pam', pamOf(width, height, rgba)) });
  });
  attempt(differs, both, (tools, pixels) => {
    const rgba = rgbaOf(pixels, 3);
    rgba[3] = 0xfe;
    tools.plan('dwebp', { output: tools.answer('answer.pam', pamOf(width, height, rgba)) });
  });
  attempt(differs, both, (tools, pixels) => tools.plan('dwebp', { output: tools.answer('answer.pam', pamOf(width + 1, height, rgbaOf(pixels, 3))) }));
  attempt(differs, both, (tools, pixels) => tools.plan('dwebp', { output: tools.answer('answer.pam', pamOf(width, height, rgbaOf(pixels, 3)).subarray(0, 200)) }));
  attempt(differs, both, (tools) => tools.plan('dwebp', {}));
  attempt(differs, both, (tools, pixels) => {
    const rgba = rgbaOf(pixels, 4);
    rgba[7] ^= 0x80;
    tools.plan('dwebp', { output: tools.answer('answer.pam', pamOf(width, height, rgba)) });
  }, { channels: 4 });
  const encoderOnly = ['cwebp'];
  const answers = (bytes) => (tools) => tools.plan('cwebp', { output: tools.answer('answer.webp', bytes) });
  attempt('the WebP has another size than the PNG', encoderOnly, answers(losslessWebp(width + 1, height)));
  attempt('the WebP has another size than the PNG', encoderOnly, answers(losslessWebp(width, height - 1)));
  attempt('cwebp wrote no lossless WebP', encoderOnly, answers(riff([['VP8 ', Buffer.alloc(12)]])));
  attempt('cwebp wrote no lossless WebP', encoderOnly, answers(riff([['VP8X', Buffer.from([0x02, 0, 0, 0, width - 1, 0, 0, height - 1, 0, 0])], ['ANIM', Buffer.alloc(6)]])));
  attempt('cwebp wrote no lossless WebP', encoderOnly, answers(Buffer.from('this is no image at all')));
  attempt('cwebp wrote no lossless WebP', encoderOnly, answers(Buffer.alloc(0)));
  attempt('the WebP carries metadata', encoderOnly, answers(losslessWebp(width, height, { exif: true })));
  attempt('the WebP carries metadata', encoderOnly, answers(losslessWebp(width, height, { xmp: true })));
  attempt('the ICC profile did not survive', encoderOnly, answers(losslessWebp(width, height, { profiles: [profile] })));
  const tagged = { extra: [['iCCP', profileChunk(profile)]] };
  attempt('the ICC profile did not survive', encoderOnly, answers(losslessWebp(width, height)), tagged);
  attempt('the ICC profile did not survive', encoderOnly, answers(losslessWebp(width, height, { profiles: [sampleBytes(120, 10)] })), tagged);
  attempt('the ICC profile did not survive', encoderOnly, answers(losslessWebp(width, height, { profiles: [profile, profile] })), tagged);
  attempt('the WebP is not smaller', encoderOnly, (tools, pixels, captured) => tools.plan('cwebp', { output: tools.answer('answer.webp', losslessWebp(width, height, { pad: captured.length })) }));
  attempt('cwebp failed', encoderOnly, (tools) => tools.plan('cwebp', { exit: 3 }));
  attempt('cwebp wrote no file', encoderOnly, (tools) => tools.plan('cwebp', {}));
  attempt('dwebp failed', both, (tools) => tools.plan('dwebp', { exit: 1 }));
  const onlyTheEncoderIfAny = (started) => started.length <= 1 && started.every((tool) => tool === 'cwebp');
  attempt('cwebp ran past 250 ms', onlyTheEncoderIfAny, (tools) => tools.plan('cwebp', { sleepMs: 20000 }), {}, { limits: { toolMs: 250 } });
  attempt('cwebp could not be started', [], (tools) => fs.writeFileSync(path.join(tools.directory, 'cwebp'), '#!/nonexistent/interpreter\n', { mode: 0o755 }));
  assert.deepEqual(fs.readdirSync(path.join(bundle, 'files')).filter((name) => !name.endsWith('.png')), []);
  assert.equal(fs.readdirSync(path.join(bundle, 'files')).length, count);
});

test('the pixel comparison reads a decoded image in several blocks, and a difference in any of them or a file that ends early keeps the PNG', { skip: NO_STAND_IN_TOOLS }, () => {
  const fx = fixture();
  const { id } = begin(fx);
  const width = 300;
  const height = 900;
  const stride = width * 4;
  const rowsPerBlock = Math.floor((1024 * 1024) / stride);
  const head = pamOf(width, height, Buffer.alloc(0)).length;
  assert.ok(height > rowsPerBlock && height < 2 * rowsPerBlock, 'the decoded image spans two read blocks');
  let count = 0;
  const add = (channels, change) => {
    count += 1;
    const pixels = sampleBytes(width * height * channels, 400 + count);
    const captured = pngOf({ width, height, channels, pixels });
    const tools = verifiedTools(width, height, pixels, channels, { pad: 3 + count });
    tools.plan('dwebp', { output: tools.answer('answer.pam', change(pamOf(width, height, rgbaOf(pixels, channels)))) });
    const added = ok(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, `blocks-${count}.png`, captured) }, `Blocks ${count}`, { toolPath: tools.directory }));
    assert.deepEqual(tools.calls().map((entry) => entry.tool), ['cwebp', 'dwebp']);
    assert.deepEqual(privateScratch(fx), []);
    return { line: added.lines[0], captured, webp: tools.webp };
  };
  const flipped = (offset) => (pam) => {
    pam[head + offset] ^= 1;
    return pam;
  };
  for (const channels of [3, 4]) {
    const stored = add(channels, (pam) => pam);
    assert.equal(stored.line, `zensu evidence report: e${count} added to ${id} | image | image/webp ${width}x${height} | ${stored.webp.length} bytes | files/${hex(stored.webp)}.webp | transcoded losslessly from a PNG of ${stored.captured.length} bytes`);
  }
  const block = rowsPerBlock * stride;
  const changes = [
    [3, flipped(block - 1), 'the last byte of the first block'],
    [3, flipped(block), 'the first byte of the second block'],
    [3, flipped(height * stride - 1), 'the last byte'],
    [4, flipped(height * stride - 4), 'the last pixel of an image with alpha'],
    [3, (pam) => pam.subarray(0, head + block), 'a file that ends after the first block'],
  ];
  for (const [channels, change, label] of changes) {
    const kept = add(channels, change);
    assert.equal(kept.line, `zensu evidence report: e${count} added to ${id} | image | image/png ${width}x${height} | ${kept.captured.length} bytes | files/${hex(kept.captured)}.png | PNG kept: the decoded WebP differs from the PNG`, label);
  }
});

test('a PNG outside what a lossless WebP can hold stays PNG with its reason and starts no tool', { skip: NO_STAND_IN_TOOLS }, () => {
  const fx = fixture();
  const { id } = begin(fx);
  const width = 6;
  const height = 4;
  const tools = standInTools();
  let count = 0;
  const kept = (reason, spec, overrides = {}) => {
    count += 1;
    const pixels = sampleBytes(width * height * 3, 200 + count);
    const captured = pngOf({ width, height, pixels, ...spec });
    const added = ok(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, `kept-${count}.png`, captured) }, `Kept ${count}`, { toolPath: tools.directory, ...overrides }));
    assert.equal(added.lines[0], `zensu evidence report: e${count} added to ${id} | image | image/png ${width}x${height} | ${captured.length} bytes | files/${hex(captured)}.png | PNG kept: ${reason}`);
  };
  kept('it is not an 8-bit truecolor image', { colour: 0 });
  kept('it is not an 8-bit truecolor image', { depth: 16 });
  kept('it is interlaced', { interlace: 1 });
  kept('it carries a tRNS chunk, which a WebP cannot hold', { extra: [['tRNS', Buffer.alloc(6)]] });
  kept('it carries gAMA without sRGB or iCCP', { extra: [['gAMA', Buffer.from([0, 1, 0x86, 0xa0])]] });
  kept('its pHYs chunk does not declare square pixels', { extra: [['pHYs', Buffer.from([0, 0, 0, 2, 0, 0, 0, 1, 1])]] });
  kept('it holds more than 23 pixels', {}, { limits: { maxTranscodePixels: 23 } });
  kept('its pixel data cannot be read', { idat: zlib.deflateSync(Buffer.alloc(11)) });
  assert.deepEqual(tools.calls(), []);
  assert.deepEqual(privateScratch(fx), []);
});

test('without a tool path, or with one that names no absolute directory holding the tools, add stores the PNG with the step-2 line', () => {
  const fx = fixture();
  const { id, bundle } = begin(fx);
  const empty = tempDir('empty');
  const toolPaths = [undefined, '', 'bin', ['', '.', 'node_modules/.bin'].join(path.delimiter), empty, path.join(empty, 'missing')];
  toolPaths.forEach((toolPath, index) => {
    const bytes = png(4, 3, 20 + index);
    const added = ok(call(fx, 'add', { report: id, kind: 'image', file: runFile(fx, `plain-${index}.png`, bytes) }, 'A capture', toolPath === undefined ? {} : { toolPath }));
    assert.equal(added.lines[0], `zensu evidence report: e${index + 1} added to ${id} | image | image/png 4x3 | ${bytes.length} bytes | files/${hex(bytes)}.png`);
  });
  assert.deepEqual(Object.values(bindingOf(fx, id).files).map((file) => [file.type, file.source_sha256]), toolPaths.map(() => ['image/png', null]));
  assert.equal(fs.readdirSync(path.join(bundle, 'files')).length, toolPaths.length);
  assert.deepEqual(privateScratch(fx), []);
});

test('a pair that is incomplete, inside the project or its work tree, or switched off leaves the step-2 add and starts no tool', { skip: NO_STAND_IN_TOOLS }, () => {
  const fx = fixture();
  const { id } = begin(fx);
  const width = 4;
  const height = 3;
  let count = 0;
  const silent = (target, tools, overrides, label) => {
    count += 1;
    const pixels = sampleBytes(width * height * 3, 300 + count);
    const bytes = pngOf({ width, height, pixels });
    const prepared = tools(pixels);
    const added = ok(call(target.fx, 'add', { report: target.id, kind: 'image', file: runFile(target.fx, `silent-${count}.png`, bytes) }, 'A capture', overrides(prepared)));
    assert.match(added.lines[0], new RegExp(`^zensu evidence report: e[0-9]+ added to ${target.id} \\| image \\| image/png ${width}x${height} \\| ${bytes.length} bytes \\| files/${hex(bytes)}\\.png$`), label);
    assert.deepEqual(prepared.calls(), [], label);
  };
  const here = { fx, id };
  const working = (directory) => (pixels) => verifiedTools(width, height, pixels, 3, {}, directory);
  const onPath = (prepared) => ({ toolPath: prepared.directory });
  silent(here, () => standInTools({ dwebp: null }), onPath, 'cwebp without dwebp');
  silent(here, working(path.join(fx.root, 'node_modules', '.bin')), onPath, 'a pair inside the project root');
  const workTree = tempDir('work-tree');
  silent(here, working(path.join(workTree, 'bin')), (prepared) => ({ toolPath: prepared.directory, chain: { receiptPath: '', editLandingEscaped: false, workTree, workTreeFault: null, bashPath: 'bash' } }), 'a pair inside the chain work tree');
  for (const config of [{ user: { webp: 'off' } }, { project: { webp: 'off' } }, { user: { webp: 'auto' }, project: { webp: 'lossy' } }, { user: { webp: false } }]) {
    silent(here, working(), (prepared) => ({ toolPath: prepared.directory, config }), `config ${JSON.stringify(config)}`);
  }
  const top = repo({ label: 'monorepo' });
  const application = path.join(top, 'packages', 'app');
  fs.mkdirSync(application, { recursive: true });
  const nested = fixture({ root: application });
  const below = { fx: nested, id: begin(nested).id };
  silent(below, working(path.join(top, 'tools')), onPath, 'a pair elsewhere in the repository of a project root below its top');
  const outside = verifiedTools(width, height, sampleBytes(width * height * 3, 399), 3);
  const proof = ok(call(nested, 'add', { report: below.id, kind: 'image', file: runFile(nested, 'proof.png', pngOf({ width, height, pixels: sampleBytes(width * height * 3, 399) })) }, 'A capture', { toolPath: outside.directory }));
  assert.match(proof.lines[0], /\| image\/webp 4x3 \| .* \| transcoded losslessly from a PNG of [0-9]+ bytes$/);
});

test('evidence.report.webp transcodes only while every layer that sets it says auto, and begin discloses what switched it off', () => {
  const unknown = 'zensu evidence report: evidence.report.webp must be auto or off, so no image is transcoded';
  const stands = 'zensu evidence report: the user configuration switched WebP transcoding off, and a project configuration can switch it off but never on';
  const read = (config) => {
    const { webp, disclosures } = er.normalizeConfig(config);
    return [webp, disclosures];
  };
  for (const config of [undefined, {}, { user: {} }, { user: { webp: 'auto' } }, { project: { webp: 'auto' } }, { user: { webp: 'auto' }, project: { webp: 'auto' } }]) {
    assert.deepEqual(read(config), ['auto', []], JSON.stringify(config));
  }
  for (const layer of ['user', 'project']) {
    assert.deepEqual(read({ [layer]: { webp: 'off' } }), ['off', []]);
    for (const value of ['lossy', 'AUTO', 'Off', ' auto', '', true, false, null, 0, ['auto'], { mode: 'auto' }]) {
      assert.deepEqual(read({ [layer]: { webp: value } }), ['off', [unknown]], `${layer}: ${JSON.stringify(value)}`);
    }
  }
  assert.deepEqual(read({ user: { webp: 'auto' }, project: { webp: 'off' } }), ['off', []]);
  assert.deepEqual(read({ user: { webp: 'off' }, project: { webp: 'off' } }), ['off', []]);
  assert.deepEqual(read({ user: { webp: 'off' }, project: { webp: 'auto' } }), ['off', [stands]]);
  assert.deepEqual(read({ user: { webp: 'off' }, project: { webp: 'lossy' } }), ['off', [unknown]]);
  assert.deepEqual(read({ user: { webp: 'auto' }, project: { webp: 1 } }), ['off', [unknown]]);
  const stood = begin(fixture(), {}, FEATURE, { config: { user: { webp: 'off' }, project: { webp: 'auto' } } });
  assert.equal(stood.lines[0], stands);
  const refusedValue = begin(fixture(), {}, FEATURE, { config: { project: { webp: 'lossy' } } });
  assert.equal(refusedValue.lines[0], unknown);
  const quiet = begin(fixture(), {}, FEATURE, { config: { project: { webp: 'off' } } });
  assert.doesNotMatch(quiet.lines.join('\n'), /webp|WebP/);
});

test('the rendered page carries one content security policy right after its charset, with the digest of its one style element', () => {
  for (const entry of corpusCases().filter((item) => item.spec.expect.rendering)) {
    for (const [mode, images] of [['bundle', "'self' file:"], ['export', 'data:']]) {
      const html = er.renderDirectory(entry.directory, { mode }).html;
      const lines = html.split('\n');
      const styles = [...html.matchAll(/<style>([\s\S]*?)<\/style>/g)];
      assert.equal(styles.length, 1, entry.name);
      const style = crypto.createHash('sha256').update(styles[0][1]).digest('base64');
      const policy = `default-src 'none'; img-src ${images}; style-src 'sha256-${style}'; base-uri 'none'; form-action 'none'`;
      assert.equal(lines[lines.indexOf('<meta charset="utf-8">') + 1], `<meta http-equiv="Content-Security-Policy" content="${policy}">`, `${entry.name} in ${mode} mode`);
      assert.equal((html.match(/Content-Security-Policy/g) || []).length, 1, entry.name);
      assert.equal(lines.indexOf('<meta charset="utf-8">'), 3, entry.name);
      assert.doesNotMatch(html, /\sstyle="/, entry.name);
    }
  }
});
