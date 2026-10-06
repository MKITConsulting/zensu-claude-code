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
  'prunedPluginRoot', 'supersededFile', 'provenance', 'provenanceCause', 'leases', 'error'];

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
  assert.equal(calls.adoptable, 1, 'adoptForHook starts from the preview and never walks the probe twice');
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
    let probes = 0;
    const { instance, calls, sweepCalls } = adopter({
      readContext: readerMustNotRun,
      readOrphanedProjectRootContext: readerMustNotRun,
      readPrunedPluginRootContext: readerMustNotRun,
      executingPluginVersion: readerMustNotRun,
      adoptableRecord: () => {
        probes += 1;
        return { ok: false, reason, recorded: '0.20.0', executing: '0.21.1', orphanedProjectRoot: false, prunedPluginRoot: true };
      },
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
    assert.equal(probes, 1, `one probe for ${reason}`);
    // A served record is an adoption another process performed, and it is complete
    // only once the lease sweep has run: that outcome sweeps, every refusal does not.
    assert.equal(sweepCalls.length, reason === 'already-served' ? 1 : 0, `sweep for ${reason}`);
    assert.equal(verdict.leases === null, reason !== 'already-served', `leases for ${reason}`);
    for (const field of VERDICT_FIELDS) assert.ok(field in verdict, field);
  }
});

test('a concurrent winner is reported as ALREADY_SERVED / adopted-concurrently, and its sweep is completed here', () => {
  const sweepResult = { discarded: 1, failed: [], unsafe: '', unsafeAt: '' };
  const { instance, sweepCalls } = adopter({ adoptContext: () => { throw refusalError('already-served'); } }, sweepResult);
  const verdict = instance.adoptForHook(REQUEST);
  assert.equal(verdict.outcome, 'already-served');
  assert.equal(verdict.reason, 'adopted-concurrently');
  // The winner releases the records lock before it sweeps, so the loser would bind
  // against superseded leases; the idempotent sweep runs here too, against the
  // executing root in the spelling the lease store records.
  assert.deepEqual(verdict.leases, sweepResult);
  assert.deepEqual(sweepCalls, [{ pluginData: REQUEST.pluginData, key: 'scv1_session-id', root: REQUEST.executingPluginRoot }]);
  const canonical = adopter({ adoptContext: () => { throw refusalError('already-served'); } }, sweepResult,
    { fs: { realpathSync: { native: (root) => '/canonical' + root } } });
  canonical.instance.adoptForHook(REQUEST);
  assert.equal(canonical.sweepCalls[0].root, '/canonical/plugins/zensu/0.21.1');
  const throwing = adopter({ adoptContext: () => { throw refusalError('already-served'); } }, new Error('lease store gone'));
  assert.equal(throwing.instance.adoptForHook(REQUEST).leases.unsafe, 'sweep-failed');
});

test('a lock timeout asks the probe once more, and a record that serves by then is a sibling adoption', () => {
  let probes = 0;
  let adopts = 0;
  const { instance, sweepCalls } = adopter({
    adoptableRecord: () => {
      probes += 1;
      return probes === 1
        ? { ok: true, recorded: '0.20.0', executing: '0.21.1', orphanedProjectRoot: false, prunedPluginRoot: false, context: {} }
        : { ok: false, reason: 'already-served', recorded: '0.21.1', executing: '0.21.1' };
    },
    adoptContext: () => { adopts += 1; throw new Error('session-control-v1: timed out acquiring per-session lock'); },
  });
  const verdict = instance.adoptForHook(REQUEST);
  assert.equal(verdict.outcome, 'already-served');
  assert.equal(verdict.reason, 'adopted-concurrently');
  assert.equal(verdict.recorded, '0.20.0', 'the version this session came from, carried off the first probe');
  assert.equal(probes, 2);
  assert.equal(adopts, 1);
  assert.equal(sweepCalls.length, 1);
  // A probe that still answers adoptable, or throws, leaves the timeout standing.
  const stillOld = adopter({ adoptContext: () => { throw new Error('session-control-v1: timed out acquiring per-session lock'); } });
  assert.equal(stillOld.instance.adoptForHook(REQUEST).reason, 'lock-timeout');
  assert.equal(stillOld.sweepCalls.length, 0);
  let thrown = 0;
  const probeThrows = adopter({
    adoptableRecord: () => {
      thrown += 1;
      if (thrown > 1) throw new Error('probe broke');
      return { ok: true, recorded: '0.20.0', executing: '0.21.1', orphanedProjectRoot: false, prunedPluginRoot: false, context: {} };
    },
    adoptContext: () => { throw new Error('session-control-v1: timed out acquiring per-session lock'); },
  });
  assert.equal(probeThrows.instance.adoptForHook(REQUEST).reason, 'lock-timeout');
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

test('previewAdoption does not sweep a served record: the completing sweep belongs to adoptForHook', () => {
  // The preview backs the report's read-only path and the binder's adoption-refusal
  // mode, and both rest on it writing nothing. The lease sweep MOVES files, so a
  // served answer from the preview carries no lease result, while the same answer
  // from adoptForHook carries the sweep it ran.
  const served = { adoptableRecord: () => ({ ok: false, reason: 'already-served', recorded: '0.21.1', executing: '0.21.1' }) };
  const preview = adopter(served, { discarded: 0, failed: [] });
  const previewed = preview.instance.previewAdoption(REQUEST);
  assert.equal(previewed.outcome, 'already-served');
  assert.equal(previewed.leases, null);
  assert.equal(preview.sweepCalls.length, 0, 'the preview never sweeps');
  const hook = adopter(served, { discarded: 2, failed: [] });
  const adopted = hook.instance.adoptForHook(REQUEST);
  assert.equal(adopted.outcome, 'already-served');
  assert.deepEqual(adopted.leases, { discarded: 2, failed: [] });
  assert.equal(hook.sweepCalls.length, 1, 'adoptForHook completes the sibling adoption');
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

test('the config reader reads the strict shell candidates as separate layers: explicit file, else global and project overlay', () => {
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
  // The layers are read APART, global first — no merged view decides this key.
  const layers = mod.configLayers({ HOME: home, CLAUDE_PROJECT_DIR: project }, 'linux');
  assert.equal(layers[0].hooks.sessionAutoAdopt, false);
  assert.equal(layers[0].hooks.other, true);
  assert.equal(layers[1].hooks.sessionAutoAdopt, true);
  // For this key `false` is sticky: the overlay lives in a directory a session can
  // write, so an overlay `true` must not be able to switch back on what the
  // operator switched off globally.
  assert.equal(mod.createAutoAdopter({ core: stubCore({}).core, sweep: stubSweep().sweep, platform: 'linux' })
    .autoAdoptEnabled({ HOME: home, CLAUDE_PROJECT_DIR: project }), false);
  assert.equal(mod.configLayers({ HOME: home, CLAUDE_PROJECT_DIR: project }, 'linux').length, 2);

  write(globalFile, { hooks: { sessionAutoAdopt: true } });
  write(projectFile, { hooks: { sessionAutoAdopt: false } });
  assert.equal(mod.createAutoAdopter({ core: stubCore({}).core, sweep: stubSweep().sweep, platform: 'linux' })
    .autoAdoptEnabled({ HOME: home, CLAUDE_PROJECT_DIR: project }), false);

  // An explicit ZENSU_CONFIG is ONE layer, read verbatim: the project overlay above
  // still says false and must not reach the decision.
  write(explicit, { hooks: { sessionAutoAdopt: true } });
  assert.equal(mod.createAutoAdopter({ core: stubCore({}).core, sweep: stubSweep().sweep, platform: 'linux' })
    .autoAdoptEnabled({ ZENSU_CONFIG: explicit, HOME: home, CLAUDE_PROJECT_DIR: project }), true);
  assert.equal(mod.configLayers({ ZENSU_CONFIG: explicit, HOME: home, CLAUDE_PROJECT_DIR: project }, 'linux').length, 1);

  write(projectFile, '{ not json');
  assert.equal(mod.createAutoAdopter({ core: stubCore({}).core, sweep: stubSweep().sweep, platform: 'linux' })
    .autoAdoptEnabled({ HOME: home, CLAUDE_PROJECT_DIR: project }), true);

  write(projectFile, { hooks: { sessionAutoAdopt: 'false' } });
  assert.equal(mod.createAutoAdopter({ core: stubCore({}).core, sweep: stubSweep().sweep, platform: 'linux' })
    .autoAdoptEnabled({ HOME: home, CLAUDE_PROJECT_DIR: project }), true);

  assert.equal(mod.createAutoAdopter({ core: stubCore({}).core, sweep: stubSweep().sweep, platform: 'linux' })
    .autoAdoptEnabled({}), true);

  // A `__proto__` key is an ordinary own key of the parsed layer, never the key the
  // decision reads, so it neither disables the path nor pollutes a prototype.
  write(projectFile, '{"hooks":{"__proto__":{"sessionAutoAdopt":false}}}');
  assert.equal(mod.createAutoAdopter({ core: stubCore({}).core, sweep: stubSweep().sweep, platform: 'linux' })
    .autoAdoptEnabled({ HOME: home, CLAUDE_PROJECT_DIR: project }), true);
  assert.equal({}.sessionAutoAdopt, undefined);

  // No HOME, no global layer: joined onto an empty string the path would be
  // RELATIVE and resolve against the hook's working directory.
  const stat = [];
  const recorder = { statSync: (file) => { stat.push(file); throw Object.assign(new Error('absent'), { code: 'ENOENT' }); } };
  assert.deepEqual(mod.configLayers({ HOME: '', CLAUDE_PROJECT_DIR: project }, 'linux', recorder).length, 1);
  assert.deepEqual(stat, [path.join(project, '.zensu', 'config.json')]);
  assert.equal(mod.configLayers({}, 'linux', recorder).length, 0);
  fs.rmSync(root, { recursive: true, force: true });
});

// The strict shell reader guards the capability grant with the same sticky rule over
// the same files; the two candidate sets are pinned against each other here, because
// nothing else compares them. The shell program is extracted from its carrier and
// run in a sandbox with a stubbed environment.
test('the candidate files equal those of _ZENSU_STRICT_JS in zensu-config.sh', () => {
  const vm = require('node:vm');
  const shell = fs.readFileSync(path.join(LIB, 'zensu-config.sh'), 'utf8');
  const match = /^_ZENSU_STRICT_JS='([^']*)'$/m.exec(shell);
  assert.ok(match, '_ZENSU_STRICT_JS must be a single-quoted one-line assignment');
  const shellCands = (env) => {
    const sandbox = { process: { env }, require };
    vm.runInNewContext(`${match[1]}; globalThis.__out = cands();`, sandbox);
    return JSON.parse(JSON.stringify(sandbox.__out));
  };
  const moduleCands = (env) => {
    const stat = [];
    const recorder = { statSync: (file) => { stat.push(file); throw Object.assign(new Error('absent'), { code: 'ENOENT' }); } };
    mod.configLayers(env, 'linux', recorder);
    return stat;
  };
  for (const env of [
    { HOME: '/h', CLAUDE_PROJECT_DIR: '/p' },
    { HOME: '/h' },
    { CLAUDE_PROJECT_DIR: '/p' },
    { HOME: '', CLAUDE_PROJECT_DIR: '/p' },
    { ZENSU_CONFIG: '/explicit.json', HOME: '/h', CLAUDE_PROJECT_DIR: '/p' },
    {},
  ]) {
    assert.deepEqual(
      moduleCands(env).map((file) => path.normalize(file)),
      shellCands(env).map((file) => path.normalize(file)),
      JSON.stringify(env),
    );
  }
});

test('the renderers that read the core are built over the injected core', () => {
  const bare = mod.createAutoAdopter({ core: {}, sweep: stubSweep().sweep, readConfig: () => ({}) });
  // A core without the version shape renders no version it cannot judge.
  assert.equal(bare.safeVersion('0.20.0'), '(unreadable)');
  // ...and a core without the provenance vocabulary takes the conditional pointer.
  assert.match(bare.doctorPointer({ outcome: 'adopted', provenance: 'recorded' }), /when a workflow document recorded it/);
  assert.match(bare.operatorLine({ recorded: '0.20.0', executing: '0.21.1' }), /\(\(unreadable\) -> \(unreadable\)\)/);
  const real = mod.createAutoAdopter({ core: realCore, sweep: stubSweep().sweep, readConfig: () => ({}) });
  assert.equal(real.safeVersion('0.20.0'), '0.20.0');
  assert.match(real.operatorLine({ recorded: '0.20.0', executing: '0.21.1' }), /\(0\.20\.0 -> 0\.21\.1\)/);
  assert.equal(mod.safeVersion('0.20.0'), '0.20.0');
});

test('a sibling adoption whose sweep here was refused says so in the served notice, and a clean one does not', () => {
  const base = { outcome: 'already-served', reason: 'adopted-concurrently', recorded: '0.20.0', executing: '0.21.1' };
  const clean = mod.renderAdoptionNotice({ ...base, leases: { discarded: 0, failed: [], unsafe: '' } }, { where: 'on this tool call' });
  assert.doesNotMatch(clean, /lease/);
  const refused = mod.renderAdoptionNotice({ ...base, leases: { discarded: 0, failed: [], unsafe: 'locked' } }, { where: 'on this tool call' });
  assert.match(refused, /serves the adopted record \(the review-evidence lease sweep was REFUSED \(locked\)/);
  const stuck = mod.renderAdoptionNotice({ ...base, leases: { discarded: 1, failed: ['a'], unsafe: '' } }, { where: 'on this tool call' });
  assert.match(stuck, /left STUCK/);
});

test('the default instance is wired to the real core and sweep', () => {
  assert.equal(typeof mod.adoptForHook, 'function');
  assert.equal(typeof mod.previewAdoption, 'function');
  assert.equal(typeof mod.autoAdoptEnabled, 'function');
  const verdict = mod.adoptForHook({ executingPluginRoot: '', pluginData: '', recordsDir: '', sessionId: '' });
  assert.equal(verdict.outcome, 'unavailable');
  assert.equal(verdict.reason, 'invalid-request');
});

// The crash-resume shape belongs to the PREVIEW, so every consumer of it agrees:
// the hook binder, the read-only report and --confirm. It was asked by the binder
// alone, which left the report answering ADOPTABLE for a state the deny named as a
// refusal and told the reader that report would name the file.
test('the preview names a blocking superseded file, ahead of the opt-out, and only for a record it could adopt', () => {
  const seen = [];
  const present = { lstatSync: (file) => { seen.push(file); return {}; } };
  const overrides = { supersededRecordFile: realCore.supersededRecordFile };
  const blocked = adopter(overrides, null, { fs: present });
  const verdict = blocked.instance.previewAdoption(REQUEST);
  assert.equal(verdict.outcome, 'refused');
  assert.equal(verdict.reason, 'superseded-record-exists');
  const expected = path.join(REQUEST.recordsDir, 'scv1_session-id.superseded-0.20.0.json');
  assert.equal(verdict.supersededFile, expected);
  assert.deepEqual(seen, [expected]);
  assert.equal(verdict.recorded, '0.20.0', 'the state travels with the refusal');
  // adoptForHook stops at the preview: adoptContext is never reached.
  assert.equal(blocked.instance.adoptForHook(REQUEST).reason, 'superseded-record-exists');
  assert.equal(blocked.calls.adopt, 0);

  // Ahead of the opt-out: a refusal keeps its own reason under the opt-out too.
  const { core } = stubCore(overrides);
  const optedOut = mod.createAutoAdopter({
    core, sweep: stubSweep().sweep, fs: present, readConfig: () => ({ hooks: { sessionAutoAdopt: false } }),
  });
  assert.equal(optedOut.previewAdoption(REQUEST).reason, 'superseded-record-exists');

  // Absent file: the ordinary verdict, untouched.
  const absent = { lstatSync: () => { const e = new Error('ENOENT'); e.code = 'ENOENT'; throw e; } };
  assert.equal(adopter(overrides, null, { fs: absent }).instance.previewAdoption(REQUEST).outcome, 'adoptable');

  // A record the probe REFUSES is never asked about: the refusal is the answer.
  const refused = adopter({
    ...overrides,
    adoptableRecord: () => ({ ok: false, reason: 'executing-runtime-older', recorded: '0.20.0', executing: '0.19.0' }),
  }, null, { fs: { lstatSync: () => { throw new Error('must not be asked'); } } });
  assert.equal(refused.instance.previewAdoption(REQUEST).reason, 'executing-runtime-older');

  // A core that predates the shared name answers the ordinary verdict.
  assert.equal(adopter({}, null, { fs: present }).instance.previewAdoption(REQUEST).outcome, 'adoptable');
});

test('a DANGLING link at the superseded name blocks too: lstat, never stat or existsSync', () => {
  // adoptContext copies with COPYFILE_EXCL, which a dangling link at that name trips
  // as well. A followed link answers "absent" for exactly the file that refuses the
  // copy, so swapping lstatSync for statSync here has to fail — and against a stub
  // filesystem it would not.
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-auto-adopt-dangling-'));
  try {
    const recordsDir = path.join(root, 'records');
    fs.mkdirSync(recordsDir);
    const name = path.join(recordsDir, 'scv1_session-id.superseded-0.20.0.json');
    try {
      fs.symlinkSync(path.join(root, 'no-such-target.json'), name);
    } catch (error) {
      // A host that cannot create a symlink cannot produce the state either.
      if (error && (error.code === 'EPERM' || error.code === 'EACCES')) return;
      throw error;
    }
    assert.equal(fs.existsSync(name), false, 'the fixture is a DANGLING link');
    const { core } = stubCore({ supersededRecordFile: realCore.supersededRecordFile });
    const instance = mod.createAutoAdopter({ core, sweep: stubSweep().sweep, readConfig: () => ({}) });
    const verdict = instance.previewAdoption({ ...REQUEST, recordsDir });
    assert.equal(verdict.reason, 'superseded-record-exists');
    assert.equal(verdict.supersededFile, name);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('the superseded name refuses a version that is not of the safe shape', () => {
  // The version reaches a FILENAME. adoptContext screens it before calling; the
  // preview calls the same function with a value read off a probe, so the function
  // enforces its own precondition instead of trusting both callers to.
  assert.equal(path.basename(realCore.supersededRecordFile('/r', 'scv1_k', '0.20.0')), 'scv1_k.superseded-0.20.0.json');
  for (const hostile of ['../../x', 'a/b', '', 'x'.repeat(65), 7, null, undefined]) {
    assert.throws(() => realCore.supersededRecordFile('/r', 'scv1_k', hostile), /safe shape/, JSON.stringify(hostile));
  }
  // ...and the preview turns that refusal into "no conflict established", never a throw.
  const { core } = stubCore({
    supersededRecordFile: realCore.supersededRecordFile,
    adoptableRecord: () => ({ ok: true, recorded: '../../x', executing: '0.21.1', context: {} }),
  });
  const instance = mod.createAutoAdopter({
    core, sweep: stubSweep().sweep, readConfig: () => ({}), fs: { lstatSync: () => ({}) },
  });
  assert.equal(instance.previewAdoption(REQUEST).outcome, 'adoptable');
});

test('the observed version reaches an already-served verdict through the request, and nowhere else', () => {
  const served = { adoptableRecord: () => ({ ok: false, reason: 'already-served', recorded: '0.21.1', executing: '0.21.1' }) };
  const observed = adopter(served).instance.adoptForHook({ ...REQUEST, observedRecorded: '0.20.0' });
  assert.equal(observed.outcome, 'already-served');
  assert.equal(observed.recorded, '0.20.0');
  // Nobody observed it: null, never the re-minted record's own version.
  assert.equal(adopter(served).instance.adoptForHook(REQUEST).recorded, null);
  for (const junk of ['', 7, null, {}]) {
    assert.equal(adopter(served).instance.adoptForHook({ ...REQUEST, observedRecorded: junk }).recorded, null);
  }
  // It is an observation about a SIBLING's adoption. A record this process adopts
  // names the version the adoption itself measured, whatever the caller handed in.
  assert.equal(adopter({}).instance.adoptForHook({ ...REQUEST, observedRecorded: '0.1.0' }).recorded, '0.20.0');
});

test('the operator line and the kept name are screens: a basename, two versions, the lease clause', () => {
  const adoption = {
    outcome: 'adopted', recorded: '0.20.0', executing: '0.21.1', provenance: 'no-workflow-document',
    supersededFile: '/private/records/scv1_x.superseded-0.20.0.json',
    leases: { discarded: 1, failed: [], unsafe: '' },
  };
  assert.equal(mod.keptName(adoption), 'scv1_x.superseded-0.20.0.json');
  assert.equal(mod.keptName({}), '(unknown)');
  assert.equal(mod.keptName(null), '(unknown)');
  const line = mod.operatorLine(adoption);
  assert.equal(line, 'adopted the Session Control record (0.20.0 -> 0.21.1); previous record kept as '
    + 'scv1_x.superseded-0.20.0.json; provenance no-workflow-document; '
    + '1 review-evidence lease(s) from before the update set aside, so a review that was in flight must be re-gathered');
  assert.doesNotMatch(line, /\/private\//, 'the path never reaches an operator line');
  const hostile = mod.operatorLine({ recorded: 'x\ny', executing: 'a"b', provenance: '/etc/passwd', supersededFile: 7, leases: null });
  assert.match(hostile, /\(\(unreadable\) -> \(unreadable\)\)/);
  assert.match(hostile, /kept as \(unknown\); provenance \(unrenderable\);/);
  assert.doesNotThrow(() => mod.operatorLine(null));
});

test('a failed provenance write keeps its cause: the verdict carries it and every renderer prints it', () => {
  const unrecorded = { provenance: realCore.ADOPTION_PROVENANCE.UNAVAILABLE, provenanceCause: 'EACCES lock busy' };
  const verdict = adopter({
    adoptContext: () => ({
      context: { plugin_root: '/plugins/zensu/0.21.1' }, supersededFile: '/records/scv1_x.superseded-0.20.0.json',
      recorded: '0.20.0', executing: '0.21.1', projectRoot: '/work/project', orphanedProjectRoot: false,
      prunedPluginRoot: false, ...unrecorded,
    }),
  }).instance.adoptForHook(REQUEST);
  assert.equal(verdict.provenance, 'unavailable');
  assert.equal(verdict.provenanceCause, 'EACCES lock busy');
  assert.equal(adopter({}).instance.adoptForHook(REQUEST).provenanceCause, null);
  assert.equal(mod.provenanceText(verdict), 'unavailable (EACCES lock busy)');
  assert.equal(mod.provenanceText({ provenance: 'recorded' }), 'recorded');
  assert.equal(mod.provenanceText({ provenance: 'unavailable', provenanceCause: 'ENOENT /Users/someone/x' }), 'unavailable ((unrenderable))');
  assert.match(mod.operatorLine(verdict), /; provenance unavailable \(EACCES lock busy\); /);
  assert.match(mod.renderAdoptionNotice(verdict, { where: 'on this tool call' }), /; provenance unavailable \(EACCES lock busy\); /);
});

test('the notice says what /zensu:doctor can actually show, per provenance', () => {
  // The doctor renders the RUNTIME_ADOPTED history entry and nothing else, so it has
  // an adoption to show only when a workflow document recorded one.
  assert.equal(realCore.ADOPTION_PROVENANCE.RECORDED, 'recorded');
  assert.equal(realCore.ADOPTION_PROVENANCE.NO_DOCUMENT, 'no-workflow-document');
  assert.equal(realCore.ADOPTION_PROVENANCE.UNAVAILABLE, 'unavailable');
  const recorded = mod.doctorPointer({ outcome: 'adopted', provenance: realCore.ADOPTION_PROVENANCE.RECORDED });
  assert.match(recorded, /shows the adoption in its session-state block/);
  for (const provenance of [realCore.ADOPTION_PROVENANCE.NO_DOCUMENT, realCore.ADOPTION_PROVENANCE.UNAVAILABLE, null]) {
    const pointer = mod.doctorPointer({ outcome: 'adopted', provenance });
    assert.match(pointer, /has no entry for it and the kept record is its evidence/, String(provenance));
  }
  // A sibling's adoption carries no provenance here: conditional, never a claim.
  assert.match(mod.doctorPointer({ outcome: 'already-served' }), /when a workflow document recorded it/);
  const base = {
    outcome: 'adopted', recorded: '0.20.0', executing: '0.21.1', supersededFile: '/r/k.superseded-0.20.0.json',
    leases: { discarded: 0, failed: [], unsafe: '' },
  };
  assert.match(mod.renderAdoptionNotice({ ...base, provenance: 'no-workflow-document' }, { where: 'on this tool call' }),
    /has no entry for it and the kept record is its evidence; nothing else to do\.$/);
  assert.match(mod.renderAdoptionNotice({ ...base, provenance: 'recorded' }, { where: 'on this tool call' }),
    /shows the adoption in its session-state block; nothing else to do\.$/);
});

test('the gate screens and selectors are EXECUTED, not only parsed', () => {
  // The seam pin at the front of the upgrade suite compares these sentences against
  // their shell twins and pins the selector lines. It cannot see a predicate whose
  // BODY changed: `grammar.test(value)` rewritten to `true` kept every source pin
  // green. Requiring the gate must not run it — it reads stdin.
  const gate = require(path.join(LIB, 'reviewer-capability-v1.js'));
  assert.equal(gate.safeRefusal('opted-out'), 'opted-out');
  for (const hostile of ['', 'BAD"TOKEN', 'a b', 'x\ny', 'Opted-Out', 7, null, undefined, 'a'.repeat(65)]) {
    assert.equal(gate.safeRefusal(hostile), '(unknown)', JSON.stringify(hostile));
  }
  assert.equal(gate.safeVersion('0.21.1'), '0.21.1');
  assert.equal(gate.safeVersion('a"b'), '(unreadable)');
  // The VERB and the TAIL, per token class.
  for (const token of gate.ADOPTION_INCOMPLETE_REASONS) {
    assert.equal(gate.adoptionAttempt(token), 'it did not complete', token);
    assert.match(gate.adoptionTail(token), /^if a retry does not bind the session/, token);
  }
  assert.deepEqual([...gate.ADOPTION_INCOMPLETE_REASONS].sort(),
    ['adopted-concurrently', 'adoption-failed', 'lock-timeout', 'not-completed']);
  for (const token of ['executing-runtime-older', 'superseded-record-exists', '(unknown)']) {
    assert.equal(gate.adoptionAttempt(token), 'it was REFUSED', token);
    assert.match(gate.adoptionTail(token), /reports the same refusal in full/, token);
  }
  assert.equal(gate.adoptionAttempt('opted-out'), 'it was REFUSED');
  assert.match(gate.adoptionTail('opted-out'), /once the user has said yes$/);
  assert.doesNotMatch(gate.adoptionTail('opted-out'), /retries the adoption by hand/);
  // The REMEDY: a token with no arm of its own takes the generic sentence.
  assert.match(gate.adoptionRefusalRemedy('superseded-record-exists'), /moving it aside lets the adoption complete/);
  assert.match(gate.adoptionRefusalRemedy('adoption-failed'), /^Run \/zensu:adopt-session for the full report/);
  assert.match(gate.adoptionRefusalRemedy('(unknown)'), /^Run \/zensu:adopt-session for the full report/);
  assert.match(gate.adoptionRefusalRemedy('not-completed'), /so retry this call$/);
});

// The SessionStart/SubagentStart adapter's serve-or-adopt, driven with stubs. The
// upgrade suite races the adapter against a gate under a HELD lock, and there the
// loss is detected under the lock, where the verdict still carries the version the
// probe read — so the adapter's own observation is never the source in that row.
// The probe-time loss, where a sibling finished first, is only reachable here.
test('the adapter hands the version it observed to the module, and announces a sibling adoption with it', () => {
  const adapter = require(path.join(LIB, 'claude-session-control-v1.js'));
  assert.equal(typeof adapter.serveOrAdopt, 'function');
  let reads = 0;
  const core = {
    // First read: the record as minted by 0.20.0. Second read: the sibling's re-mint.
    readContext: () => { reads += 1; return { plugin_version: reads === 1 ? '0.20.0' : '0.21.1', plugin_data: '/data' }; },
    servesRecordedRuntime: (context) => context.plugin_version === '0.21.1',
  };
  const requests = [];
  const served = stubCore({
    adoptableRecord: () => ({ ok: false, reason: 'already-served', recorded: '0.21.1', executing: '0.21.1' }),
  });
  const instance = mod.createAutoAdopter({ core: served.core, sweep: stubSweep().sweep, readConfig: () => ({}) });
  const autoAdopt = { ...mod, adoptForHook: (request) => { requests.push(request); return instance.adoptForHook(request); } };
  const result = adapter.serveOrAdopt({ recordsDir: '/data/records' }, '/plugins/zensu/0.21.1', '/data', 'session-id',
    'SessionStart context', 'session', { core, autoAdopt });
  assert.equal(reads, 2, 'one failed serve, one strict re-read');
  assert.equal(requests.length, 1);
  assert.equal(requests[0].observedRecorded, '0.20.0');
  assert.equal(requests[0].respectOptOut, true);
  assert.equal(result.adoption.outcome, 'already-served');
  assert.equal(result.adoption.recorded, '0.20.0');
  assert.match(mod.renderAdoptionNotice(result.adoption, { where: 'at this SessionStart' }),
    /updated from 0\.20\.0 to 0\.21\.1 while this session was running; its Session Control record was adopted automatically by a sibling hook/);

  // A record that serves at once is returned with no adoption and no module call.
  const healthy = adapter.serveOrAdopt({ recordsDir: '/data/records' }, '/p', '/data', 'session-id', 'label', 'session', {
    core: { readContext: () => ({ plugin_version: '0.21.1', plugin_data: '/data' }), servesRecordedRuntime: () => true },
    autoAdopt: { ...mod, adoptForHook: () => { throw new Error('must not be called'); } },
  });
  assert.equal(healthy.adoption, null);
});

test('the adapter names an adoption it performed when the strict re-read still fails, and a refusal by its token', () => {
  const adapter = require(path.join(LIB, 'claude-session-control-v1.js'));
  const core = {
    readContext: () => ({ plugin_version: '0.20.0', plugin_data: '/data' }),
    servesRecordedRuntime: () => false,
  };
  const adopting = mod.createAutoAdopter({ core: stubCore({}).core, sweep: stubSweep().sweep, readConfig: () => ({}) });
  assert.throws(
    () => adapter.serveOrAdopt({ recordsDir: '/data/records' }, '/p', '/data', 'session-id', 'resume context', 'session',
      { core, autoAdopt: { ...mod, adoptForHook: adopting.adoptForHook } }),
    /resume context: adopted the Session Control record \(0\.20\.0 -> 0\.21\.1\); previous record kept as scv1_x\.superseded-0\.20\.0\.json; provenance recorded; 2 review-evidence lease\(s\).* — but the strict re-read still fails: /,
  );
  const refusing = mod.createAutoAdopter({
    core: stubCore({ adoptableRecord: () => ({ ok: false, reason: 'executing-runtime-older', recorded: '0.20.0', executing: '0.19.0' }) }).core,
    sweep: stubSweep().sweep,
    readConfig: () => ({}),
  });
  assert.throws(
    () => adapter.serveOrAdopt({ recordsDir: '/data/records' }, '/p', '/data', 'session-id', 'resume context', 'session',
      { core, autoAdopt: { ...mod, adoptForHook: refusing.adoptForHook } }),
    /resume context: automatic adoption refused \(executing-runtime-older\); /,
  );
});

test('the adapter loads the adoption module only after the strict serve fails', () => {
  const adapter = require(path.join(LIB, 'claude-session-control-v1.js'));
  let loads = 0;
  const healthy = adapter.serveOrAdopt({ recordsDir: '/data/records' }, '/p', '/data', 'session-id', 'label', 'session', {
    core: { readContext: () => ({ plugin_version: '0.21.1', plugin_data: '/data' }), servesRecordedRuntime: () => true },
    loadAutoAdopt: () => { loads += 1; throw new Error('must not be loaded'); },
  });
  assert.equal(healthy.adoption, null);
  assert.equal(loads, 0);
  const refusing = mod.createAutoAdopter({
    core: stubCore({ adoptableRecord: () => ({ ok: false, reason: 'executing-runtime-older', recorded: '0.20.0', executing: '0.19.0' }) }).core,
    sweep: stubSweep().sweep,
    readConfig: () => ({}),
  });
  assert.throws(
    () => adapter.serveOrAdopt({ recordsDir: '/data/records' }, '/p', '/data', 'session-id', 'resume context', 'session', {
      core: { readContext: () => ({ plugin_version: '0.20.0', plugin_data: '/data' }), servesRecordedRuntime: () => false },
      loadAutoAdopt: () => { loads += 1; return { ...mod, adoptForHook: refusing.adoptForHook }; },
    }),
    /resume context: automatic adoption refused \(executing-runtime-older\); /,
  );
  assert.equal(loads, 1);
});

test('an adapter tree without the adoption module still loads, and a failed serve names the missing module', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-adapter-lean-'));
  try {
    for (const file of ['claude-session-control-v1.js', 'session-control-core-v1.js', 'claude-path-v1.js', 'claude-principal-v1.js']) {
      fs.copyFileSync(path.join(LIB, file), path.join(root, file));
    }
    const adapter = require(path.join(root, 'claude-session-control-v1.js'));
    assert.equal(typeof adapter.serveOrAdopt, 'function');
    let thrown = null;
    try {
      adapter.serveOrAdopt({ recordsDir: '/data/records' }, '/p', '/data', 'session-id', 'resume context', 'session', {
        core: { readContext: () => ({ plugin_version: '0.20.0', plugin_data: '/data' }), servesRecordedRuntime: () => false },
      });
    } catch (error) {
      thrown = error;
    }
    assert.ok(thrown, 'a failed serve with no adoption module must still fail the hook');
    assert.match(thrown.message, /resume context: automatic adoption unavailable \(Cannot find module '\.\/session-auto-adopt-v1\.js'\); /);
    assert.match(thrown.message, /plugin root is neither the session's plugin nor a compatible upgrade of it/);
    assert.doesNotMatch(thrown.message, /Require stack/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('the confined sentence names the version pair and never the kept record or a command', () => {
  // A deny after an adoption reaches confined principals too. The full operator line
  // names the kept basename and, for a refused sweep, /zensu:adopt-session --confirm,
  // which writes the immutable record; the confined form carries neither.
  const refusedSweep = {
    outcome: 'adopted', reason: 'adopted', recorded: '0.20.0', executing: '0.21.1',
    supersededFile: '/records/scv1_x.superseded-0.20.0.json', provenance: 'recorded',
    leases: { discarded: 0, failed: [], unsafe: 'locked', unsafeAt: '/x' },
  };
  const full = mod.operatorLine(refusedSweep);
  assert.match(full, /scv1_x\.superseded-0\.20\.0\.json/);
  assert.match(full, /--confirm/);
  const confined = mod.confinedOperatorLine(refusedSweep);
  assert.equal(confined, 'adopted the Session Control record (0.20.0 -> 0.21.1) under the running installation');
  assert.doesNotMatch(confined, /superseded|--confirm|\/zensu:/);
  assert.match(mod.confinedOperatorLine({ recorded: 'x\ny', executing: '0.21.1' }), /\(\(unreadable\) -> 0\.21\.1\)/);
});

test('a served-completion sweep is reported when it moved or failed, and stays unsaid when clean', () => {
  const served = (leases) => ({ outcome: 'already-served', reason: 'already-served', recorded: null, executing: '0.21.1', supersededFile: null, provenance: null, leases });
  assert.equal(mod.servedSweepLine(served({ discarded: 0, failed: [], unsafe: '', unsafeAt: '' })), null);
  assert.equal(mod.servedSweepLine(served(null)), null);
  assert.equal(mod.servedSweepLine({ ...served({ discarded: 2, failed: [], unsafe: '' }), outcome: 'adopted' }), null);
  assert.match(mod.servedSweepLine(served({ discarded: 2, failed: [], unsafe: '' })), /^ran the review-evidence lease sweep while binding a record this installation already serves \(0\.21\.1\); 2 review-evidence lease\(s\) from before the update set aside/);
  assert.doesNotMatch(mod.servedSweepLine(served({ discarded: 0, failed: [], unsafe: 'locked' })), /sibling|completed/);
  assert.match(mod.servedSweepLine(served({ discarded: 0, failed: [], unsafe: 'sweep-failed' })), /lease sweep was REFUSED \(sweep-failed\)/);
  assert.equal(mod.sweepWorthReporting({ discarded: 0, failed: ['a'], unsafe: '' }), true);
  // The served NOTICE carries the clause for a sweep that moved leases, not only for
  // a refused or stuck one: a count of two set aside is a fact about the session.
  const moved = mod.renderAdoptionNotice(served({ discarded: 2, failed: [], unsafe: '' }), { where: 'on this tool call' });
  assert.match(moved, /serves the adopted record \(2 review-evidence lease\(s\) from before the update set aside/);
  const clean = mod.renderAdoptionNotice(served({ discarded: 0, failed: [], unsafe: '' }), { where: 'on this tool call' });
  assert.doesNotMatch(clean, /review-evidence lease/);
});

test('the notice closes on the deny that followed it, and an orphaned adoption closes on the adoption alone', () => {
  const base = {
    outcome: 'adopted', reason: 'adopted', recorded: '0.20.0', executing: '0.21.1',
    supersededFile: '/records/scv1_x.superseded-0.20.0.json', provenance: 'recorded',
    orphanedProjectRoot: false, leases: { discarded: 0, failed: [], unsafe: '', unsafeAt: '' },
  };
  assert.match(mod.renderAdoptionNotice(base, { where: 'on this tool call' }), /; nothing else to do\.$/);
  const denied = mod.renderAdoptionNotice(base, { where: 'on this tool call', denied: true });
  assert.match(denied, /session-state block; this tool call was still denied, for the reason its deny names\.$/);
  assert.doesNotMatch(denied, /nothing else to do/);
  const servedDenied = mod.renderAdoptionNotice({ ...base, outcome: 'already-served', reason: 'already-served', supersededFile: null, provenance: null, leases: null }, { where: 'on this tool call', denied: true });
  assert.match(servedDenied, /; this tool call was still denied, for the reason its deny names\.$/);
  assert.doesNotMatch(servedDenied, /nothing else to do/);
  const orphan = mod.renderAdoptionNotice({ ...base, orphanedProjectRoot: true }, { where: 'on this tool call' });
  assert.match(orphan, /project root is still gone/);
  assert.match(orphan, /; nothing else to do for the adoption itself\.$/);
  const orphanDenied = mod.renderAdoptionNotice({ ...base, orphanedProjectRoot: true }, { where: 'on this tool call', denied: true });
  assert.match(orphanDenied, /; this tool call was still denied, for the reason its deny names\.$/);
});

test('the adapter names the lease sweep of a served answer when the strict re-read still fails, and rethrows the read error when the sweep was clean', () => {
  const adapter = require(path.join(LIB, 'claude-session-control-v1.js'));
  const core = {
    readContext: () => { throw new Error('session-control-v1: context project root does not exist'); },
    servesRecordedRuntime: () => true,
  };
  const servedWith = (leases) => ({
    ...mod,
    adoptForHook: () => ({ outcome: 'already-served', reason: 'already-served', recorded: null, executing: '0.21.1', supersededFile: null, provenance: null, leases, error: null }),
  });
  assert.throws(
    () => adapter.serveOrAdopt({ recordsDir: '/data/records' }, '/p', '/data', 'session-id', 'resume context', 'session',
      { core, autoAdopt: servedWith({ discarded: 0, failed: [], unsafe: 'source', unsafeAt: '/x' }) }),
    /resume context: ran the review-evidence lease sweep while binding a record this installation already serves \(0\.21\.1\); the review-evidence lease sweep was REFUSED \(source\).* — but the strict re-read still fails: session-control-v1: context project root does not exist/,
  );
  assert.throws(
    () => adapter.serveOrAdopt({ recordsDir: '/data/records' }, '/p', '/data', 'session-id', 'resume context', 'session',
      { core, autoAdopt: servedWith({ discarded: 0, failed: [], unsafe: '', unsafeAt: '' }) }),
    (error) => error.message === 'session-control-v1: context project root does not exist',
  );
});
