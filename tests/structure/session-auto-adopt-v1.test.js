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
  // The refusal carries its own state, exactly as the real adoptableRecord attaches
  // it. The readers below THROW on purpose: the verdict's state has to come off the
  // probe, and a module that re-derived it from a second walk of the reader ladder
  // would fail here instead of silently agreeing with a stub.
  const readerMustNotRun = () => { throw new Error('the module must not re-read the record'); };
  for (const reason of Object.values(realCore.ADOPTION_REFUSALS)) {
    const { instance, calls } = adopter({
      readContext: readerMustNotRun,
      readOrphanedProjectRootContext: readerMustNotRun,
      readPrunedPluginRootContext: readerMustNotRun,
      executingPluginVersion: readerMustNotRun,
      adoptableRecord: () => ({
        ok: false, reason, recorded: '0.20.0', executing: '0.21.1', orphanedProjectRoot: false, prunedPluginRoot: true,
      }),
    });
    const verdict = instance.adoptForHook(REQUEST);
    const expected = reason === 'already-served' ? 'already-served' : 'refused';
    assert.equal(verdict.outcome, expected, reason);
    assert.equal(verdict.reason, reason);
    // already-served deliberately drops `recorded`: the record on disk is the
    // re-minted one by then, so its version is not the one this session came FROM.
    assert.equal(verdict.recorded, reason === 'already-served' ? null : '0.20.0', reason);
    assert.equal(verdict.executing, '0.21.1');
    assert.equal(verdict.prunedPluginRoot, true, 'the state flag travels with the refusal');
    assert.equal(verdict.orphanedProjectRoot, false);
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

test('a throwing probe never escapes: UNAVAILABLE / probe-failed, with no state at all', () => {
  const { instance, calls } = adopter({ adoptableRecord: () => { throw new TypeError('boom'); } });
  const verdict = instance.adoptForHook(REQUEST);
  assert.equal(verdict.outcome, 'unavailable');
  assert.equal(verdict.reason, 'probe-failed');
  // Nothing about the record was established, so nothing is claimed about it: the
  // stub's readContext would have answered 0.20.0 had the module gone looking.
  assert.equal(verdict.recorded, null);
  assert.equal(verdict.executing, null);
  assert.equal(mod.establishesNamedState(verdict), false);
  assert.match(verdict.error, /boom/);
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
  // The probe runs BEFORE the opt-out is consulted: opted-out stands only for a
  // record the ladder would otherwise have adopted.
  assert.equal(calls.adoptable, 1);
  assert.equal(calls.adopt, 0);
  const manual = instance.adoptForHook({ ...REQUEST, respectOptOut: false });
  assert.equal(manual.outcome, 'adopted');
  assert.equal(calls.adopt, 1);
  assert.equal(instance.autoAdoptEnabled({}), false);
});

test('under the opt-out a non-adoptable record keeps its own refusal, never opted-out', () => {
  const disabled = () => ({ hooks: { sessionAutoAdopt: false } });
  for (const reason of ['record-unreadable', 'plugin-data-mismatch', 'executing-runtime-older', 'workflow-schema-mismatch']) {
    const { core, calls } = stubCore({ adoptableRecord: () => ({ ok: false, reason }) });
    const instance = mod.createAutoAdopter({ core, sweep: stubSweep().sweep, readConfig: disabled });
    const verdict = instance.adoptForHook(REQUEST);
    assert.equal(verdict.outcome, 'refused', reason);
    assert.equal(verdict.reason, reason);
    assert.equal(calls.adopt, 0);
  }
  const served = stubCore({ adoptableRecord: () => ({ ok: false, reason: 'already-served' }) });
  const instance = mod.createAutoAdopter({ core: served.core, sweep: stubSweep().sweep, readConfig: disabled });
  assert.equal(instance.adoptForHook(REQUEST).outcome, 'already-served');
});

test('a named state is established only by a reader that answered and a state-bearing reason', () => {
  assert.deepEqual([...mod.STATE_NEUTRAL_REASONS],
    ['record-unreadable', 'plugin-data-mismatch', 'invalid-request', 'probe-failed']);
  assert.equal(mod.establishesNamedState({ recorded: '0.20.0', reason: 'executing-runtime-older' }), true);
  assert.equal(mod.establishesNamedState({ recorded: '0.20.0', reason: 'opted-out' }), true);
  assert.equal(mod.establishesNamedState({ recorded: null, reason: 'executing-runtime-older' }), false);
  for (const reason of mod.STATE_NEUTRAL_REASONS) {
    assert.equal(mod.establishesNamedState({ recorded: '0.20.0', reason }), false, reason);
  }
  assert.equal(mod.establishesNamedState(null), false);
});

test('a typed lock timeout is recognised by its code before the message is consulted', () => {
  const typed = new Error('something unrelated');
  typed.code = realCore.LOCK_TIMEOUT_CODE;
  const { instance } = adopter({ isLockTimeout: realCore.isLockTimeout, adoptContext: () => { throw typed; } });
  const verdict = instance.adoptForHook(REQUEST);
  assert.equal(verdict.outcome, 'unavailable');
  assert.equal(verdict.reason, 'lock-timeout');
  assert.equal(realCore.isLockTimeout(new Error('timed out acquiring per-session lock')), false);
});

test('the core MINTS the typed lock timeout it exports a predicate for', () => {
  // The case above proves the adopter READS the code. Nothing proved the core still
  // WRITES it: withFileLock waits ten seconds before it times out, which is too long
  // to drive here, so the producer is pinned at source — the three lines that build,
  // type and throw the error, in that order. Deleting the middle one leaves every
  // behavioural case green and sends a real timeout to the message-matching fallback.
  const source = fs.readFileSync(CORE_FILE, 'utf8');
  const message = "new Error('session-control-v1: timed out acquiring per-session lock');";
  assert.equal(source.split(message).length - 1, 1, 'the timeout message is minted at exactly one site');
  const after = source.slice(source.indexOf(message) + message.length).split('\n').slice(1, 3).map((line) => line.trim());
  assert.deepEqual(after, ['timedOut.code = LOCK_TIMEOUT_CODE;', 'throw timedOut;']);
  assert.equal(realCore.LOCK_TIMEOUT_CODE, 'ZENSU_LOCK_TIMEOUT');
});

test('the notice renderer screens every value and names a refused sweep as refused', () => {
  const base = {
    outcome: 'adopted', reason: 'adopted', recorded: '0.20.0', executing: '0.21.1',
    supersededFile: '/records/scv1_x.superseded-0.20.0.json', provenance: 'recorded',
    orphanedProjectRoot: false, leases: { discarded: 2, failed: [], unsafe: '', unsafeAt: '' },
  };
  const clean = mod.renderAdoptionNotice(base, { where: 'on this tool call' });
  assert.match(clean, /updated from 0\.20\.0 to 0\.21\.1/);
  assert.match(clean, /adopted automatically on this tool call/);
  assert.match(clean, /kept beside it as scv1_x\.superseded-0\.20\.0\.json;/);
  assert.match(clean, /2 review-evidence lease\(s\) from before the update set aside/);
  assert.doesNotMatch(clean, /\/records\//);
  assert.doesNotMatch(clean, /project root is still gone/);

  const refused = mod.renderAdoptionNotice({ ...base, leases: { discarded: 0, failed: [], unsafe: 'locked', unsafeAt: '/x' } }, { where: 'on this tool call' });
  assert.match(refused, /lease sweep was REFUSED \(locked\) and set aside nothing/);
  assert.doesNotMatch(refused, /0 review-evidence lease\(s\)/);
  // A refusal does not imply that nothing moved: the destination guard refuses per
  // lease, so the sweep can set some aside and then stop. "Set aside nothing" over a
  // count of two would be the same misreport the refused arm exists to prevent.
  const partial = mod.leaseClause({ discarded: 2, failed: [], unsafe: 'destination', unsafeAt: '/x' });
  assert.match(partial, /lease sweep set aside 2 lease\(s\) and was then REFUSED \(destination\)/);
  assert.doesNotMatch(partial, /set aside nothing/);
  assert.match(partial, /\/zensu:adopt-session --confirm repairs the lease store/);
  const stuck = mod.renderAdoptionNotice({ ...base, leases: { discarded: 1, failed: ['a'], unsafe: '' } }, { where: 'on this tool call' });
  assert.match(stuck, /1 review-evidence lease\(s\) from before the update set aside and 1 left STUCK/);
  // The command named there has to be the one that actually names them: the
  // read-only report does not re-run the sweep, the --confirm form does.
  assert.match(stuck, /\/zensu:adopt-session --confirm re-runs the sweep and names them/);
  assert.match(mod.leaseClause(null), /no review-evidence lease sweep result was recorded/);
  assert.match(mod.leaseClause({ discarded: 0, failed: [], unsafe: 'sweep failed!' }), /REFUSED \(\(unrenderable\)\)/);

  const orphan = mod.renderAdoptionNotice({ ...base, orphanedProjectRoot: true }, { where: 'at this SessionStart' });
  assert.match(orphan, /project root is still gone, so Edit, Write, MultiEdit/);
  assert.match(orphan, /adopted automatically at this SessionStart/);

  const concurrent = mod.renderAdoptionNotice({ ...base, outcome: 'already-served', reason: 'adopted-concurrently', supersededFile: null, provenance: null, leases: null }, { where: 'at this SubagentStart' });
  assert.match(concurrent, /adopted automatically by a sibling hook at this SubagentStart/);
  assert.doesNotMatch(concurrent, /kept beside it/);
  assert.match(concurrent, /updated from 0\.20\.0 to 0\.21\.1 while/);
  // Nobody measured the previous version: the sentence drops that half rather than
  // printing the re-minted record's version as the one the session came from.
  const unmeasured = mod.renderAdoptionNotice({ ...base, outcome: 'already-served', reason: 'already-served', recorded: null, supersededFile: null, provenance: null, leases: null }, { where: 'at this SessionStart' });
  assert.match(unmeasured, /plugin was updated to 0\.21\.1 while this session was running/);
  assert.doesNotMatch(unmeasured, /updated from/);
  assert.doesNotMatch(unmeasured, /\(unreadable\)/);

  const hostile = mod.renderAdoptionNotice({ ...base, recorded: 'x\ny', executing: 'a"b', provenance: 'unavailable: <script>' }, { where: 'on this tool call' });
  assert.match(hostile, /from \(unreadable\) to \(unreadable\)/);
  assert.match(hostile, /provenance \(unrenderable\)/);
  assert.equal(mod.safeVersion('0.21.1'), '0.21.1');
  assert.equal(mod.safeProvenance('no-workflow-document'), 'no-workflow-document');
  assert.equal(mod.SAFE_PROVENANCE.test('unavailable: ENOENT (x)'), true);
  // No slash: provenance carries an error message, and that is where a path arrives.
  assert.equal(mod.SAFE_PROVENANCE.test('unavailable: ENOENT /Users/someone/project'), false);
  assert.equal(mod.safeProvenance('unavailable: ENOENT /Users/someone/project'), '(unrenderable)');
});

test('the token grammar has one JavaScript owner, and the gate consumes it', () => {
  assert.ok(mod.SAFE_TOKEN instanceof RegExp);
  for (const token of [...Object.values(realCore.ADOPTION_REFUSALS), ...Object.values(mod.AUTO_ADOPT_REASONS)]) {
    assert.equal(mod.SAFE_TOKEN.test(token), true, token);
  }
  for (const hostile of ['', 'Opted-Out', 'a b', 'a"b', 'x\ny', '-lead', 'a'.repeat(65)]) {
    assert.equal(mod.SAFE_TOKEN.test(hostile), false, JSON.stringify(hostile));
  }
  // The gate reads the grammar off THIS export. A private copy there is the third
  // spelling this export was introduced to retire, so the literal must not come back.
  const gate = fs.readFileSync(path.join(LIB, 'reviewer-capability-v1.js'), 'utf8');
  assert.match(gate, /autoAdoptModule\(\)\.SAFE_TOKEN/);
  assert.doesNotMatch(gate, /\[a-z\]\[a-z0-9-\]\{0,63\}/);
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

test('a refusal names the state the PROBE carried, and claims none the probe did not', () => {
  // The stub readers answer a DIFFERENT version than the probe on purpose. A module
  // that still re-derived the pair from its own walk of the reader ladder would
  // report 0.19.0 here; the probe said 0.20.0, and the probe is the walk that
  // produced the refusal.
  const lying = { plugin_version: '0.19.0' };
  const carried = adopter({
    readContext: () => lying,
    readOrphanedProjectRootContext: () => lying,
    readPrunedPluginRootContext: () => lying,
    adoptableRecord: () => ({
      ok: false, reason: 'executing-runtime-older', recorded: '0.20.0', executing: '0.21.1',
      orphanedProjectRoot: true, prunedPluginRoot: false,
    }),
  }).instance.adoptForHook(REQUEST);
  assert.equal(carried.outcome, 'refused');
  assert.equal(carried.recorded, '0.20.0');
  assert.equal(carried.executing, '0.21.1');
  assert.equal(carried.orphanedProjectRoot, true);
  assert.equal(carried.prunedPluginRoot, false);
  assert.equal(mod.establishesNamedState(carried), true);

  // A probe that carries NO state — `record-unreadable`, or a core that predates the
  // state fields — yields the empty state, never a guess. Flags are read strictly:
  // a truthy non-boolean is not a flag.
  const bare = adopter({
    readContext: () => lying,
    adoptableRecord: () => ({ ok: false, reason: 'record-unreadable', orphanedProjectRoot: 'yes', recorded: 7 }),
  }).instance.adoptForHook(REQUEST);
  assert.equal(bare.outcome, 'refused');
  assert.equal(bare.recorded, null);
  assert.equal(bare.executing, null);
  assert.equal(bare.orphanedProjectRoot, false);
  assert.equal(bare.prunedPluginRoot, false);
  assert.equal(mod.establishesNamedState(bare), false);
});

test('the real adoptableRecord attaches the state to a refusal it reaches past the read', () => {
  // The module trusts the probe for the state, so the probe has to supply it. Driven
  // against the REAL core with a records directory that holds nothing: the one
  // refusal reachable without a fixture is `record-unreadable`, which is reached
  // BEFORE any record is read and therefore carries the empty state — every field
  // present, none of them a guess.
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-auto-adopt-probe-'));
  try {
    const pluginData = path.join(root, 'data');
    const recordsDir = path.join(pluginData, 'session-control', 'v1', 'records');
    fs.mkdirSync(recordsDir, { recursive: true });
    const refusal = realCore.adoptableRecord({
      executingPluginRoot: path.join(__dirname, '..', '..'),
      pluginData,
      recordsDir,
      sessionId: 'no-such-session',
      host: 'claude',
    });
    assert.equal(refusal.ok, false);
    assert.equal(refusal.reason, 'record-unreadable');
    assert.deepEqual(Object.keys(refusal).sort(),
      ['executing', 'ok', 'orphanedProjectRoot', 'prunedPluginRoot', 'reason', 'recorded']);
    assert.equal(refusal.recorded, null);
    assert.equal(refusal.executing, null);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
  // The later refusals carry what condition 1 established. They need a minted record
  // to reach, which the upgrade suite builds; here the contract is pinned at source:
  // every refusal below the read passes `state`, and only the pre-read one does not.
  const source = fs.readFileSync(CORE_FILE, 'utf8');
  const body = source.slice(source.indexOf('function adoptableRecord(options)'), source.indexOf("const ADOPTION_HISTORY_PHASE"));
  const refusals = body.match(/adoptionRefusal\([^)]*\)/g) || [];
  assert.ok(refusals.length >= 7, `expected the full refusal roster, found ${refusals.length}`);
  const stateless = refusals.filter((call) => !/, state\)$/.test(call));
  assert.deepEqual(stateless, ['adoptionRefusal(ADOPTION_REFUSALS.RECORD_UNREADABLE)']);
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
