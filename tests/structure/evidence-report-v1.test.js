'use strict';

const assert = require('node:assert/strict');
const childProcess = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const test = require('node:test');

const ROOT = path.join(__dirname, '..', '..');
const LIB = path.join(ROOT, 'hooks', 'lib', 'evidence-report-v1.js');
const er = require(LIB);
const av = require(path.join(ROOT, 'hooks', 'lib', 'acceptance-verify-v1.js'));
const evr = require(path.join(ROOT, 'hooks', 'lib', 'evidence-run-v1.js'));
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

function idle(fx, id) {
  const when = new Date(Date.now() - er.LIMITS.openReportMs - 24 * 60 * 60 * 1000);
  fs.utimesSync(path.join(repositoryDirectory(fx), `${id}.binding.json`), when, when);
}

function corpusCases() {
  return fs.readdirSync(CORPUS).sort().map((name) => ({ name, directory: path.join(CORPUS, name), spec: JSON.parse(fs.readFileSync(path.join(CORPUS, name, 'case.json'), 'utf8')) }));
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
  assert.ok(cases.length >= 28, `the corpus holds ${cases.length} cases`);
  const mismatches = [];
  for (const entry of cases) {
    const result = er.renderDirectory(entry.directory, { inScope: entry.spec.inScope });
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

test('the corpus names every integrity fault the renderer can raise', () => {
  const codes = new Set();
  for (const entry of corpusCases()) {
    for (const fault of entry.spec.expect.refusal || []) codes.add(fault.code);
  }
  for (const code of ['criterion.absent', 'step.unknown-criterion', 'step.unknown-evidence', 'criterion.steps', 'evidence.unknown-file', 'evidence.file-type', 'file.unreferenced', 'file.missing', 'file.digest', 'file.size', 'file.type', 'criterion.no-image', 'verdict.contradiction', 'manifest.unparseable', 'schema.unknown-key', 'schema.missing-key', 'schema.value']) {
    assert.ok(codes.has(code), `the corpus lacks a case for ${code}`);
  }
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

test('add accepts only a regular file inside the run directory, named by its physical path', { skip: NOT_ON_WINDOWS }, () => {
  const fx = fixture();
  const { id } = begin(fx);
  const inside = runFile(fx, 'shot.png', png(4, 3));
  const outside = path.join(fx.root, 'outside.png');
  fs.writeFileSync(outside, png(4, 3, 2));
  refused(call(fx, 'add', { report: id, kind: 'image', file: outside }, 'caption'), /lies outside the run directory/);
  const link = path.join(fx.runDir, 'link.png');
  fs.symlinkSync(inside, link);
  refused(call(fx, 'add', { report: id, kind: 'image', file: link }, 'caption'), /is a symlink/);
  const hard = path.join(fx.runDir, 'hard.png');
  fs.linkSync(runFile(fx, 'linked.png', png(4, 3, 3)), hard);
  refused(call(fx, 'add', { report: id, kind: 'image', file: hard }, 'caption'), /more than one link/);
  fs.mkdirSync(path.join(fx.runDir, 'folder'));
  refused(call(fx, 'add', { report: id, kind: 'image', file: path.join(fx.runDir, 'folder') }, 'caption'), /not a regular file/);
  refused(call(fx, 'add', { report: id, kind: 'image', file: `${fx.runDir}/folder/../shot.png` }, 'caption'), /normalized path/, 2);
  refused(call(fx, 'add', { report: id, kind: 'image', file: 'shot.png' }, 'caption'), /absolute path/, 2);
  refused(call(fx, 'add', { report: id, kind: 'image', file: path.join(fx.runDir, 'missing.png') }, 'caption'), /does not exist/);
  const away = tempDir('away');
  fs.writeFileSync(path.join(away, 'shot.png'), png(4, 3, 4));
  fs.symlinkSync(away, path.join(fx.runDir, 'linked-dir'));
  refused(call(fx, 'add', { report: id, kind: 'image', file: path.join(fx.runDir, 'linked-dir', 'shot.png') }, 'caption'), /runs through a symlink/);
  const fifo = path.join(fx.runDir, 'pipe.png');
  if (childProcess.spawnSync('mkfifo', [fifo]).status === 0) {
    refused(call(fx, 'add', { report: id, kind: 'image', file: fifo }, 'caption'), /not a regular file/);
  }
  ok(call(fx, 'add', { report: id, kind: 'image', file: inside }, 'caption'));
});

test('begin accepts only a physical run directory inside the work tree and apart from the store', { skip: NOT_ON_WINDOWS }, () => {
  const fx = fixture();
  refused(call(fx, 'begin', { 'run-dir': tempDir('elsewhere'), drivers: 'browser' }, FEATURE), /inside the project's work tree/);
  refused(call(fx, 'begin', { 'run-dir': path.join(fx.root, 'missing'), drivers: 'browser' }, FEATURE), /does not exist/);
  const link = path.join(fx.root, 'run-link');
  fs.symlinkSync(fx.runDir, link);
  refused(call(fx, 'begin', { 'run-dir': link, drivers: 'browser' }, FEATURE), /is a symlink/);
  refused(call(fx, 'begin', { 'run-dir': fx.root, drivers: 'browser' }, FEATURE), /inside the project's work tree/);
  const store = path.join(fx.root, 'reports');
  fs.writeFileSync(path.join(fx.root, '.gitignore'), '.zensu/\nreports/\n');
  refused(call(fx, 'begin', { 'run-dir': path.join(store), drivers: 'browser' }, FEATURE, { config: { dir: store } }), /does not exist|must not overlap the report store/);
  fs.mkdirSync(path.join(store, 'run'), { recursive: true });
  refused(call(fx, 'begin', { 'run-dir': path.join(store, 'run'), drivers: 'browser' }, FEATURE, { config: { dir: store } }), /must not overlap the report store/);
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

test('the default store lies outside every git work tree and a store inside one is refused unless git ignores it', () => {
  const fx = fixture();
  begin(fx);
  const store = path.join(fx.root, 'reports');
  refused(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser' }, FEATURE, { config: { dir: store } }), /inside the git work tree .+ does not report it ignored/);
  fs.writeFileSync(path.join(fx.root, '.gitignore'), '.zensu/\nreports/\n');
  const accepted = ok(call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser' }, FEATURE, { config: { dir: store } }));
  assert.ok(accepted.bundle.startsWith(fs.realpathSync(store)));
  const tracked = repo({ label: 'data-in-repo' });
  const data = path.join(tracked, 'plugin-data');
  fs.mkdirSync(data);
  const inside = fixture({ data });
  refused(call(inside, 'begin', { 'run-dir': inside.runDir, drivers: 'browser' }, FEATURE), /does not report it ignored/);
  assert.equal(er.storePlacement(tempDir('outside')).ok, true);
  assert.equal(er.storePlacement(tracked).ok, false);
});

test('retention keeps the newest reports per repository and deletes the oldest first', () => {
  const fx = fixture();
  const ids = [];
  for (let index = 0; index < 4; index += 1) {
    const started = begin(fx, {}, FEATURE, { config: { keep: 2 }, now: () => 1790000000000 + index });
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
  const footprint = (started, fx) => {
    const directory = repositoryDirectory(fx);
    const files = path.join(directory, started.id, 'files');
    const stored = fs.readdirSync(files).reduce((sum, name) => sum + fs.statSync(path.join(files, name)).size, 0);
    return stored + fs.statSync(path.join(directory, `${started.id}.binding.json`)).size;
  };
  assert.ok(footprint(reports[0], first) > 4096);
  const cap = footprint(reports[1], first) + footprint(reports[2], second) + 4096;
  const latest = begin(second, {}, FEATURE, { config: { maxBytes: cap }, now: () => clock });
  clock += 1;
  assert.ok(!fs.existsSync(path.join(repositoryDirectory(first), reports[0].id)), 'the oldest report is deleted first');
  assert.ok(fs.existsSync(path.join(repositoryDirectory(first), reports[1].id)));
  assert.ok(fs.existsSync(path.join(repositoryDirectory(second), reports[2].id)));
  assert.ok(fs.existsSync(latest.bundle));
  idle(second, latest.id);
  fs.writeFileSync(path.join(repositoryDirectory(first), `${reports[1].id}.lock`), String(process.pid));
  const newest = begin(first, {}, FEATURE, { config: { maxBytes: 1 }, now: () => clock });
  assert.ok(fs.existsSync(newest.bundle), 'the report being written survives');
  assert.ok(fs.existsSync(path.join(repositoryDirectory(first), reports[1].id)), 'a locked report survives');
  assert.ok(!fs.existsSync(path.join(repositoryDirectory(second), reports[2].id)));
  assert.ok(!fs.existsSync(latest.bundle));
});

test('retention ignores entries it does not own and never follows a symlink', { skip: NOT_ON_WINDOWS }, () => {
  const fx = fixture();
  const first = begin(fx, {}, FEATURE, { now: () => 1790000000000 });
  const directory = repositoryDirectory(fx);
  const outside = tempDir('precious');
  fs.writeFileSync(path.join(outside, 'keep.txt'), 'keep');
  fs.symlinkSync(outside, path.join(directory, 'vr1_1780000000000_0123456789ab'));
  fs.mkdirSync(path.join(directory, 'notes'));
  idle(fx, first.id);
  begin(fx, {}, FEATURE, { config: { keep: 1 }, now: () => 1790000000001 });
  assert.ok(!fs.existsSync(first.bundle));
  assert.ok(fs.existsSync(path.join(outside, 'keep.txt')));
  assert.ok(fs.lstatSync(path.join(directory, 'vr1_1780000000000_0123456789ab')).isSymbolicLink());
  assert.ok(fs.existsSync(path.join(directory, 'notes')));
  assert.deepEqual(er.sweep(tempDir('empty-store'), { keep: 1, maxBytes: 1 }).removed, []);
});

test('retention trims only the calling repository and spares a report another call is still building', () => {
  const data = tempDir('shared-keep');
  const first = fixture({ data, label: 'keep-first' });
  const second = fixture({ data, label: 'keep-second' });
  const others = [0, 1].map((index) => begin(first, {}, FEATURE, { now: () => 1790000000000 + index }));
  for (const started of others) idle(first, started.id);
  const open = begin(second, {}, FEATURE, { now: () => 1790000000002 });
  begin(second, {}, FEATURE, { config: { keep: 1 }, now: () => 1790000000003 });
  for (const started of others) assert.ok(fs.existsSync(started.bundle), 'the keep of one repository never trims another');
  assert.ok(fs.existsSync(open.bundle), 'an unrendered report touched within the window is still being built');
  addImage(second, open.id);
  ok(call(second, 'render', { report: open.id, verdict: 'PARTIAL' }));
  begin(second, {}, FEATURE, { config: { keep: 1 }, now: () => 1790000000004 });
  assert.ok(!fs.existsSync(open.bundle), 'a rendered report beyond keep is deleted');
  const stale = begin(second, {}, FEATURE, { now: () => 1790000000005 });
  idle(second, stale.id);
  const building = begin(second, {}, FEATURE, { now: () => 1790000000006 });
  begin(second, {}, FEATURE, { config: { keep: 1, maxBytes: 1 }, now: () => 1790000000007 });
  assert.ok(!fs.existsSync(stale.bundle), 'an unrendered report idle beyond the window is deleted');
  assert.ok(fs.existsSync(building.bundle), 'the size pass spares a report still being built');
  for (const started of others) assert.ok(!fs.existsSync(started.bundle), 'the store-wide cap applies to every repository');
  const held = begin(second, {}, FEATURE, { now: () => 1790000000008 });
  idle(second, held.id);
  fs.mkdirSync(path.join(repositoryDirectory(second), `${held.id}.lock`));
  begin(second, {}, FEATURE, { config: { keep: 1 }, now: () => 1790000000009 });
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
  fs.writeFileSync(path.join(fx.root, 'a.txt'), 'changed\n');
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL' }));
  const manifest = manifestOf(bundle);
  assert.equal(manifest.target.dirty, true);
  assert.notEqual(manifest.target.tree, binding.target.tree);
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

test('every write is atomic and a symlinked bundle, binding or output file is refused', { skip: NOT_ON_WINDOWS }, () => {
  const fx = fixture();
  const { id, bundle } = begin(fx);
  addImage(fx, id);
  const directory = repositoryDirectory(fx);
  const decoy = path.join(tempDir('decoy'), 'index.html');
  fs.writeFileSync(decoy, 'decoy');
  fs.symlinkSync(decoy, path.join(bundle, 'index.html'));
  refused(call(fx, 'render', { report: id, verdict: 'PARTIAL' }), /is not a regular file, so it is not replaced/, 2);
  assert.equal(fs.readFileSync(decoy, 'utf8'), 'decoy');
  fs.unlinkSync(path.join(bundle, 'index.html'));
  ok(call(fx, 'render', { report: id, verdict: 'PARTIAL' }));
  const leftovers = [...fs.readdirSync(directory), ...fs.readdirSync(bundle), ...fs.readdirSync(path.join(bundle, 'files'))].filter((name) => name.endsWith('.tmp') || name.endsWith('.lock'));
  assert.deepEqual(leftovers, []);
  const second = begin(fx);
  const bindingPath = path.join(directory, `${second.id}.binding.json`);
  const moved = path.join(tempDir('binding'), 'binding.json');
  fs.renameSync(bindingPath, moved);
  fs.symlinkSync(moved, bindingPath);
  refused(call(fx, 'add', { report: second.id, kind: 'request', method: 'GET', path: '/', status: '200' }), /binding of .+ cannot be read \(symlink\)/, 2);
  const third = begin(fx);
  const real = path.join(tempDir('bundle'), 'moved');
  fs.renameSync(third.bundle, real);
  fs.symlinkSync(real, third.bundle);
  refused(call(fx, 'add', { report: third.id, kind: 'request', method: 'GET', path: '/', status: '200' }), /is not a real directory/, 2);
});

test('a lock held by another call makes a verb wait and a stale lock is taken over', () => {
  const fx = fixture();
  const { id } = begin(fx);
  const lock = path.join(repositoryDirectory(fx), `${id}.lock`);
  fs.writeFileSync(lock, '1');
  const started = Date.now();
  refused(call(fx, 'add', { report: id, kind: 'request', method: 'GET', path: '/', status: '200' }, '', { limits: { lockWaitMs: 150 } }), /another call holds this report's lock/, 2);
  assert.ok(Date.now() - started >= 140, 'the verb waited for the lock');
  const old = new Date(Date.now() - 5 * 60 * 1000);
  fs.utimesSync(lock, old, old);
  ok(call(fx, 'add', { report: id, kind: 'request', method: 'GET', path: '/', status: '200' }));
  assert.ok(!fs.existsSync(lock));
});

test('the config keys are read permissively and every value not used is disclosed', () => {
  assert.deepEqual(er.normalizeConfig(undefined), { enabled: true, dir: null, keep: 30, maxBytes: 2147483648, disclosures: [] });
  assert.equal(er.normalizeConfig({ enabled: false }).enabled, false);
  assert.equal(er.normalizeConfig({ enabled: 'false' }).enabled, true);
  const relative = er.normalizeConfig({ dir: 'reports' });
  assert.equal(relative.dir, null);
  assert.match(relative.disclosures[0], /evidence\.report\.dir is not an absolute path/);
  const bad = er.normalizeConfig({ keep: 0, maxBytes: -1 });
  assert.equal(bad.keep, 30);
  assert.equal(bad.maxBytes, 2147483648);
  assert.equal(bad.disclosures.length, 2);
  assert.deepEqual(er.normalizeConfig({ keep: 5, maxBytes: 1000 }), { enabled: true, dir: null, keep: 5, maxBytes: 1000, disclosures: [] });
  assert.match(er.normalizeConfig({ maxBytesFromProject: true }).disclosures[0], /maxBytes caps the whole store, so it is read from the user configuration only/);
  const fx = fixture();
  const disabled = call(fx, 'begin', { 'run-dir': fx.runDir, drivers: 'browser' }, FEATURE, { config: { enabled: false } });
  assert.equal(disabled.code, 3);
  assert.match(disabled.lines.join('\n'), /evidence\.report\.enabled is false/);
  assert.ok(!fs.existsSync(path.join(fx.data, 'evidence-report')));
  const disclosed = begin(fx, {}, FEATURE, { config: { keep: 'many' } });
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
  assert.deepEqual(required, ['./acceptance-verify-v1.js', './evidence-run-v1.js', './secret-patterns.js', './zensu-artifact-redact-v1.js', 'node:crypto', 'node:fs', 'node:path']);
  const seen = new Set();
  const env = new Proxy({ ZENSU_ERP_HOST: 'kiro' }, { get(target, key) { seen.add(String(key)); return target[key]; } });
  const options = er.transportOptions(env);
  assert.equal(options.host, 'kiro');
  for (const key of seen) assert.match(key, /^ZENSU_ERP_[A-Z_]+$/);
});

test('the core module makes no network request, starts no program itself and runs git through the evidence runner', () => {
  const source = fs.readFileSync(LIB, 'utf8');
  assert.doesNotMatch(source, /require\('node:(?:http|https|http2|net|tls|dns|dgram|child_process)'\)/);
  assert.doesNotMatch(source, /\bfetch\(|spawnSync|execFileSync|childProcess/);
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

test('a lock entry that cannot be removed is refused at once instead of spinning', () => {
  const fx = fixture();
  const { id } = begin(fx);
  const lock = path.join(repositoryDirectory(fx), `${id}.lock`);
  fs.mkdirSync(lock);
  const request = { report: id, kind: 'request', method: 'GET', path: '/api/items', status: '200' };
  const started = Date.now();
  refused(call(fx, 'add', request), /the stale report lock .+ cannot be removed/, 2);
  assert.ok(Date.now() - started < er.LIMITS.lockWaitMs, 'the refusal does not wait for the lock deadline');
  fs.rmdirSync(lock);
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
    second = begin(fx, {}, FEATURE, { config: { keep: 1 }, now: () => 1790000000001 });
  } finally {
    failing.mock.restore();
  }
  const notice = second.lines.find((line) => line.includes('retention could not delete 1 report(s): '));
  assert.ok(notice && notice.includes(`/${first.id} (EBUSY)`), second.lines.join('\n'));
  assert.ok(fs.existsSync(first.bundle), 'the report whose delete failed stays');
  assert.ok(fs.existsSync(second.bundle), 'the new report is kept');
  const third = begin(fx, {}, FEATURE, { config: { keep: 1 }, now: () => 1790000000002 });
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

test('chain mode measures the target in the chain work tree through the acceptance fingerprint', () => {
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
});
