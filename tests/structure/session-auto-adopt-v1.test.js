'use strict';

// Unit driver for hooks/lib/session-auto-adopt-v1.js — the adoption ladder the
// binder, the SessionStart adapter and the manual entry point share.
//
// Every case here injects the core and the sweep through createAutoAdopter, so a
// refusal, a lock timeout or a crash-resume conflict costs a stub rather than a
// synthetic install plus a session lifecycle. The one real-filesystem surface is
// the config reader, driven against a temp HOME, because its precedence rule is a
// hand mirror of _ZENSU_CFG_JS in hooks/lib/zensu-config.sh.
//
// Registered with the tree runner through test-versioned-plugin-upgrade.sh —
// tests/run-all.sh discovers only test-*.sh, so an undriven *.test.js never runs.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const LIB = path.join(__dirname, '..', '..', 'hooks', 'lib');
const MODULE_FILE = path.join(LIB, 'session-auto-adopt-v1.js');
const CORE_FILE = path.join(LIB, 'session-control-core-v1.js');

const mod = require(MODULE_FILE);
const realCore = require(CORE_FILE);

const VERDICT_FIELDS = ['outcome', 'reason', 'recorded', 'executing', 'projectRoot', 'orphanedProjectRoot',
  'prunedPluginRoot', 'supersededFile', 'provenance', 'leases', 'error'];

const REQUEST = Object.freeze({
  executingPluginRoot: '/plugins/zensu/0.21.1',
  pluginData: '/plugins/data/zensu-zensu',
  recordsDir: '/plugins/data/zensu-zensu/session-control/v1/records',
  sessionId: 'session-id',
  host: 'claude',
  environment: {},
});

function refusalError(reason) {
  const error = new Error(`session-control-v1: record is not adoptable: ${reason}`);
  error.code = realCore.ADOPTION_REFUSED_CODE;
  error.reason = reason;
  return error;
}

function conflictError(file) {
  const error = new Error(`session-control-v1: a superseded record already exists and adoption would overwrite it: ${file}`);
  error.code = realCore.SUPERSEDED_EXISTS_CODE;
  error.supersededFile = file;
  return error;
}

function stubCore(overrides) {
  const calls = { adoptable: 0, adopt: 0 };
  const core = {
    ADOPTION_REFUSALS: realCore.ADOPTION_REFUSALS,
    isAdoptionRefusal: realCore.isAdoptionRefusal,
    isSupersededRecordConflict: realCore.isSupersededRecordConflict,
    sessionKey: (id) => `scv1_${id}`,
    executingPluginVersion: () => '0.21.1',
    readContext: () => ({ plugin_version: '0.20.0' }),
    adoptableRecord: () => {
      calls.adoptable += 1;
      return { ok: true, recorded: '0.20.0', executing: '0.21.1', orphanedProjectRoot: false, prunedPluginRoot: false, context: {} };
    },
    adoptContext: () => {
      calls.adopt += 1;
      return {
        context: { plugin_root: '/plugins/zensu/0.21.1' },
        supersededFile: '/records/scv1_x.superseded-0.20.0.json',
        recorded: '0.20.0',
        executing: '0.21.1',
        projectRoot: '/work/project',
        orphanedProjectRoot: false,
        prunedPluginRoot: false,
        provenance: 'recorded',
      };
    },
    ...overrides,
  };
  return { core, calls };
}

function stubSweep(result) {
  const calls = [];
  return {
    calls,
    sweep: {
      discardSupersededLeases: (pluginData, key, root) => {
        calls.push({ pluginData, key, root });
        if (result instanceof Error) throw result;
        return result || { discarded: 2, failed: [], unsafe: '', unsafeAt: '' };
      },
    },
  };
}

function adopter(coreOverrides, sweepResult, extra) {
  const { core, calls } = stubCore(coreOverrides);
  const swept = stubSweep(sweepResult);
  const instance = mod.createAutoAdopter({ core, sweep: swept.sweep, readConfig: () => ({}), ...(extra || {}) });
  return { instance, calls, sweepCalls: swept.calls };
}

test('the outcome and reason vocabularies are frozen and closed', () => {
  assert.ok(Object.isFrozen(mod.AUTO_ADOPT_OUTCOMES));
  assert.ok(Object.isFrozen(mod.AUTO_ADOPT_REASONS));
  assert.deepEqual(Object.values(mod.AUTO_ADOPT_OUTCOMES).sort(),
    ['adoptable', 'adopted', 'already-served', 'opted-out', 'refused', 'unavailable']);
  assert.equal(mod.CONFIG_KEY, 'sessionAutoAdopt');
});

test('an adoptable record is adopted, and the sweep result travels verbatim', () => {
  const sweepResult = { discarded: 3, failed: ['a'], unsafe: '', unsafeAt: '' };
  const { instance, calls, sweepCalls } = adopter({}, sweepResult);
  const verdict = instance.adoptForHook(REQUEST);
  assert.equal(verdict.outcome, 'adopted');
  assert.equal(verdict.reason, 'adopted');
  assert.equal(verdict.recorded, '0.20.0');
  assert.equal(verdict.executing, '0.21.1');
  assert.equal(verdict.supersededFile, '/records/scv1_x.superseded-0.20.0.json');
  assert.equal(verdict.provenance, 'recorded');
  assert.equal(verdict.projectRoot, '/work/project');
  assert.deepEqual(verdict.leases, sweepResult);
  assert.equal(calls.adopt, 1);
  assert.deepEqual(sweepCalls, [{ pluginData: REQUEST.pluginData, key: 'scv1_session-id', root: '/plugins/zensu/0.21.1' }]);
  for (const field of VERDICT_FIELDS) assert.ok(field in verdict, field);
});

test('every core refusal reason maps to REFUSED and already-served to ALREADY_SERVED, without a write', () => {
  for (const reason of Object.values(realCore.ADOPTION_REFUSALS)) {
    const { instance, calls } = adopter({ adoptableRecord: () => ({ ok: false, reason }) });
    const verdict = instance.adoptForHook(REQUEST);
    const expected = reason === 'already-served' ? 'already-served' : 'refused';
    assert.equal(verdict.outcome, expected, reason);
    assert.equal(verdict.reason, reason);
    assert.equal(verdict.recorded, '0.20.0');
    assert.equal(verdict.executing, '0.21.1');
    assert.equal(calls.adopt, 0, `adoptContext must not run for ${reason}`);
    for (const field of VERDICT_FIELDS) assert.ok(field in verdict, field);
  }
});

test('a concurrent winner is reported as ALREADY_SERVED / adopted-concurrently', () => {
  const { instance } = adopter({ adoptContext: () => { throw refusalError('already-served'); } });
  const verdict = instance.adoptForHook(REQUEST);
  assert.equal(verdict.outcome, 'already-served');
  assert.equal(verdict.reason, 'adopted-concurrently');
  assert.equal(verdict.leases, null);
});

test('a typed refusal thrown under the lock keeps its reason', () => {
  const { instance } = adopter({ adoptContext: () => { throw refusalError('workflow-schema-mismatch'); } });
  const verdict = instance.adoptForHook(REQUEST);
  assert.equal(verdict.outcome, 'refused');
  assert.equal(verdict.reason, 'workflow-schema-mismatch');
  assert.match(verdict.error, /workflow-schema-mismatch/);
});

test('a crash-resume conflict is REFUSED as superseded-record-exists and names the file', () => {
  const { instance } = adopter({ adoptContext: () => { throw conflictError('/records/scv1_x.superseded-0.20.0.json'); } });
  const verdict = instance.adoptForHook(REQUEST);
  assert.equal(verdict.outcome, 'refused');
  assert.equal(verdict.reason, 'superseded-record-exists');
  assert.equal(verdict.supersededFile, '/records/scv1_x.superseded-0.20.0.json');
});

test('a lock timeout is UNAVAILABLE / lock-timeout, anything else UNAVAILABLE / adoption-failed', () => {
  const timeout = adopter({ adoptContext: () => { throw new Error('session-control-v1: timed out acquiring per-session lock'); } });
  const late = timeout.instance.adoptForHook(REQUEST);
  assert.equal(late.outcome, 'unavailable');
  assert.equal(late.reason, 'lock-timeout');
  const broken = adopter({ adoptContext: () => { throw new Error('EACCES: permission denied'); } });
  const failed = broken.instance.adoptForHook(REQUEST);
  assert.equal(failed.outcome, 'unavailable');
  assert.equal(failed.reason, 'adoption-failed');
  assert.match(failed.error, /EACCES/);
});

test('a throwing probe never escapes: UNAVAILABLE / probe-failed', () => {
  const { instance, calls } = adopter({ adoptableRecord: () => { throw new TypeError('boom'); } });
  const verdict = instance.adoptForHook(REQUEST);
  assert.equal(verdict.outcome, 'unavailable');
  assert.equal(verdict.reason, 'probe-failed');
  assert.equal(calls.adopt, 0);
});

test('a throwing sweep never reverts an adoption; it is carried as sweep-failed', () => {
  const { instance } = adopter({}, new Error('lock is busy or abandoned'));
  const verdict = instance.adoptForHook(REQUEST);
  assert.equal(verdict.outcome, 'adopted');
  assert.equal(verdict.leases.unsafe, 'sweep-failed');
  assert.match(verdict.leases.error, /busy/);
});

test('the opt-out is honoured on the adoption path only, and the manual caller may ignore it', () => {
  const disabled = () => ({ hooks: { sessionAutoAdopt: false } });
  const { core, calls } = stubCore({});
  const swept = stubSweep();
  const instance = mod.createAutoAdopter({ core, sweep: swept.sweep, readConfig: disabled });
  const verdict = instance.adoptForHook(REQUEST);
  assert.equal(verdict.outcome, 'opted-out');
  assert.equal(verdict.reason, 'opted-out');
  assert.equal(verdict.recorded, '0.20.0');
  assert.equal(verdict.executing, '0.21.1');
  assert.equal(calls.adoptable, 0);
  assert.equal(calls.adopt, 0);
  const manual = instance.adoptForHook({ ...REQUEST, respectOptOut: false });
  assert.equal(manual.outcome, 'adopted');
  assert.equal(calls.adopt, 1);
  assert.equal(instance.autoAdoptEnabled({}), false);
});

test('a throwing config reader degrades to enabled', () => {
  const { instance } = adopter({}, null, { readConfig: () => { throw new Error('unreadable'); } });
  assert.equal(instance.autoAdoptEnabled({}), true);
  assert.equal(instance.adoptForHook(REQUEST).outcome, 'adopted');
});

test('previewAdoption performs no write and answers ADOPTABLE for an adoptable record', () => {
  const { instance, calls } = adopter({});
  const verdict = instance.previewAdoption(REQUEST);
  assert.equal(verdict.outcome, 'adoptable');
  assert.equal(verdict.reason, 'adoptable');
  assert.equal(calls.adoptable, 1);
  assert.equal(calls.adopt, 0);
});

test('an invalid request is UNAVAILABLE / invalid-request and never reaches the core', () => {
  const { instance, calls } = adopter({});
  for (const bad of [null, {}, { ...REQUEST, sessionId: '' }, { ...REQUEST, recordsDir: 7 }]) {
    const verdict = instance.adoptForHook(bad);
    assert.equal(verdict.outcome, 'unavailable');
    assert.equal(verdict.reason, 'invalid-request');
  }
  assert.equal(calls.adoptable, 0);
  assert.equal(calls.adopt, 0);
});

test('the version pair on a refusal is best-effort and absorbs every reader fault', () => {
  const { instance } = adopter({
    adoptableRecord: () => ({ ok: false, reason: 'record-unreadable' }),
    readContext: () => { throw new Error('strict read failed'); },
    readOrphanedProjectRootContext: () => { throw new Error('no'); },
    readPrunedPluginRootContext: () => ({ plugin_version: '0.19.0' }),
    executingPluginVersion: () => { throw new Error('no manifest'); },
  });
  const verdict = instance.adoptForHook(REQUEST);
  assert.equal(verdict.outcome, 'refused');
  assert.equal(verdict.recorded, '0.19.0');
  assert.equal(verdict.executing, null);
});

test('the config reader mirrors the shell precedence: explicit file, then global merged with the project overlay', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-auto-adopt-'));
  const home = path.join(root, 'home');
  const project = path.join(root, 'project');
  const explicit = path.join(root, 'explicit.json');
  fs.mkdirSync(path.join(home, '.zensu'), { recursive: true });
  fs.mkdirSync(path.join(project, '.zensu'), { recursive: true });
  const write = (file, value) => fs.writeFileSync(file, typeof value === 'string' ? value : JSON.stringify(value));
  const globalFile = path.join(home, '.zensu', 'config.json');
  const projectFile = path.join(project, '.zensu', 'config.json');

  write(globalFile, { hooks: { sessionAutoAdopt: false, other: true } });
  write(projectFile, { hooks: { sessionAutoAdopt: true } });
  const projectWins = mod.effectiveConfig({ HOME: home, CLAUDE_PROJECT_DIR: project }, 'linux');
  assert.equal(projectWins.hooks.sessionAutoAdopt, true);
  assert.equal(projectWins.hooks.other, true);
  assert.equal(mod.createAutoAdopter({ core: stubCore({}).core, sweep: stubSweep().sweep, platform: 'linux' })
    .autoAdoptEnabled({ HOME: home, CLAUDE_PROJECT_DIR: project }), true);

  write(globalFile, { hooks: { sessionAutoAdopt: true } });
  write(projectFile, { hooks: { sessionAutoAdopt: false } });
  assert.equal(mod.createAutoAdopter({ core: stubCore({}).core, sweep: stubSweep().sweep, platform: 'linux' })
    .autoAdoptEnabled({ HOME: home, CLAUDE_PROJECT_DIR: project }), false);

  write(explicit, { hooks: { sessionAutoAdopt: true } });
  assert.equal(mod.createAutoAdopter({ core: stubCore({}).core, sweep: stubSweep().sweep, platform: 'linux' })
    .autoAdoptEnabled({ ZENSU_CONFIG: explicit, HOME: home, CLAUDE_PROJECT_DIR: project }), true);

  write(projectFile, '{ not json');
  assert.equal(mod.createAutoAdopter({ core: stubCore({}).core, sweep: stubSweep().sweep, platform: 'linux' })
    .autoAdoptEnabled({ HOME: home, CLAUDE_PROJECT_DIR: project }), true);

  write(projectFile, { hooks: { sessionAutoAdopt: 'false' } });
  assert.equal(mod.createAutoAdopter({ core: stubCore({}).core, sweep: stubSweep().sweep, platform: 'linux' })
    .autoAdoptEnabled({ HOME: home, CLAUDE_PROJECT_DIR: project }), true);

  assert.equal(mod.createAutoAdopter({ core: stubCore({}).core, sweep: stubSweep().sweep, platform: 'linux' })
    .autoAdoptEnabled({}), true);

  write(projectFile, { hooks: { __proto__: { sessionAutoAdopt: false }, constructor: { x: 1 } } });
  const merged = mod.effectiveConfig({ HOME: home, CLAUDE_PROJECT_DIR: project }, 'linux');
  assert.equal(Object.prototype.hasOwnProperty.call(merged.hooks, 'constructor'), false);
  fs.rmSync(root, { recursive: true, force: true });
});

test('the default instance is wired to the real core and sweep', () => {
  assert.equal(typeof mod.adoptForHook, 'function');
  assert.equal(typeof mod.previewAdoption, 'function');
  assert.equal(typeof mod.autoAdoptEnabled, 'function');
  const verdict = mod.adoptForHook({ executingPluginRoot: '', pluginData: '', recordsDir: '', sessionId: '' });
  assert.equal(verdict.outcome, 'unavailable');
  assert.equal(verdict.reason, 'invalid-request');
});
