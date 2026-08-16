'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const core = require(path.join(__dirname, '..', '..', 'hooks', 'lib', 'session-control-core-v1.js'));

const { runtimeLineageCompatible, servesRecordedRuntime } = core;

test('AC-011 an equal version is its own lineage', () => {
  assert.equal(runtimeLineageCompatible('0.17.2', '0.17.2'), true);
  assert.equal(runtimeLineageCompatible('1.4.0', '1.4.0'), true);
});

test('AC-011 a forward patch inside the same zero-major minor is compatible', () => {
  assert.equal(runtimeLineageCompatible('0.17.0', '0.17.1'), true);
  assert.equal(runtimeLineageCompatible('0.17.0', '0.17.12'), true);
});

test('AC-011 a minor change is breaking while major is zero', () => {
  assert.equal(runtimeLineageCompatible('0.17.2', '0.18.0'), false);
  assert.equal(runtimeLineageCompatible('0.17.0', '0.16.1'), false);
  // The clause that carries the whole zero-major rule: without it the shared
  // major would make these two count as one lineage.
  assert.equal(runtimeLineageCompatible('0.9.2', '0.17.2'), false);
});

test('AC-011 a patch-forward step is compatible at every major', () => {
  assert.equal(runtimeLineageCompatible('1.2.3', '1.2.4'), true);
  assert.equal(runtimeLineageCompatible('0.0.1', '0.0.2'), true);
  assert.equal(runtimeLineageCompatible('0.0.2', '0.0.1'), false);
});

test('AC-011 a minor change is forward-compatible once major is non-zero', () => {
  assert.equal(runtimeLineageCompatible('1.2.0', '1.3.0'), true);
  assert.equal(runtimeLineageCompatible('1.3.0', '1.2.9'), false);
  assert.equal(runtimeLineageCompatible('1.9.9', '2.0.0'), false);
  assert.equal(runtimeLineageCompatible('2.0.0', '1.9.9'), false);
});

test('AC-011 a downgrade never binds', () => {
  assert.equal(runtimeLineageCompatible('0.17.3', '0.17.1'), false);
  assert.equal(runtimeLineageCompatible('0.17.3', '0.17.2'), false);
});

test('AC-011 only a strict X.Y.Z spelling is a lineage claim', () => {
  for (const spelling of [
    '0.17',
    '0.17.0.1',
    'v0.17.0',
    '0.17.0-rc.1',
    '0.17.0+build.5',
    '0.017.0',
    '00.17.0',
    ' 0.17.0',
    '0.17.0 ',
    '',
    // The anchoring itself: the pattern carries no `m` flag, so an embedded
    // newline must not let a second line satisfy it. Nothing else records that,
    // and a port to a language whose `$` matches before a trailing newline would
    // pass this suite unchanged without them.
    '0.17.0\n',
    '\n0.17.0',
    '0.17.0\n99.0.0',
    '0.17.0\t',
    // Components are bounded so the numeric comparison stays exact. Without the
    // bound these two tie under Number() and the downgrade below is accepted.
    '0.17.9007199254740993',
    '9007199254740993.0.0',
  ]) {
    assert.equal(
      runtimeLineageCompatible(spelling, '0.17.0'),
      false,
      `recorded ${JSON.stringify(spelling)} must not parse as a lineage`,
    );
    assert.equal(
      runtimeLineageCompatible('0.17.0', spelling),
      false,
      `executing ${JSON.stringify(spelling)} must not parse as a lineage`,
    );
  }
});

test('AC-011 a non-string version is refused rather than coerced', () => {
  for (const value of [undefined, null, 0.17, {}, [], ['0.17.0'], new String('0.17.0')]) {
    assert.equal(runtimeLineageCompatible(value, '0.17.0'), false);
    assert.equal(runtimeLineageCompatible('0.17.0', value), false);
  }
});

test('AC-011 an over-long component cannot tie a downgrade into compatibility', () => {
  // The defect the digit bound closes: Number('…93') === Number('…92'), so an
  // unbounded pattern would let the loop tie and answer true for a DOWNGRADE.
  assert.equal(
    runtimeLineageCompatible('0.17.9007199254740993', '0.17.9007199254740992'),
    false,
  );
  // The largest spelling the bound still admits must keep working normally.
  assert.equal(runtimeLineageCompatible('0.17.999999999', '0.17.999999999'), true);
  assert.equal(runtimeLineageCompatible('0.17.999999998', '0.17.999999999'), true);
  assert.equal(runtimeLineageCompatible('0.17.999999999', '0.17.999999998'), false);
  assert.equal(runtimeLineageCompatible('0.17.1000000000', '0.17.1000000000'), false);
});

test('servesRecordedRuntime answers false for a malformed context instead of throwing', () => {
  // The seam is exported cross-host, so a port may hand it something it built
  // itself. "Never throws" has to hold for that too, in a fail-closed path.
  for (const value of [undefined, null, 'context', 42, []]) {
    assert.equal(servesRecordedRuntime(value, '/anywhere', 'claude'), false);
  }
});

function installManifest(root, version, directory = '.claude-plugin') {
  fs.mkdirSync(path.join(root, directory), { recursive: true });
  fs.writeFileSync(
    path.join(root, directory, 'plugin.json'),
    `${JSON.stringify({ name: 'zensu', version })}\n`,
  );
  return fs.realpathSync.native(root);
}

test('servesRecordedRuntime short-circuits on an equal root without reading a manifest', () => {
  const temp = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-lineage-')));
  try {
    // No manifest is written at all: an equal root must answer true before any
    // filesystem read, so a runtime whose manifest is unreadable still binds to
    // its own record.
    const root = path.join(temp, 'same');
    fs.mkdirSync(root);
    const context = { plugin_root: root, plugin_version: '0.17.2', host: 'claude' };
    assert.equal(servesRecordedRuntime(context, root, 'claude'), true);
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
});

test('servesRecordedRuntime reads the EXECUTING root manifest, not the recorded one', () => {
  const temp = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-lineage-')));
  try {
    const recorded = installManifest(path.join(temp, 'recorded'), '0.17.0');
    const compatible = installManifest(path.join(temp, 'compatible'), '0.17.1');
    const breaking = installManifest(path.join(temp, 'breaking'), '0.18.0');
    const older = installManifest(path.join(temp, 'older'), '0.16.1');
    const context = { plugin_root: recorded, plugin_version: '0.17.0', host: 'claude' };

    assert.equal(servesRecordedRuntime(context, compatible, 'claude'), true);
    assert.equal(servesRecordedRuntime(context, breaking, 'claude'), false);
    assert.equal(servesRecordedRuntime(context, older, 'claude'), false);

    // The recorded VERSION is the record's own field, never re-read from the
    // recorded root — a record whose version disagrees with its own manifest is
    // judged on the record, which is what readContextInternal already validated.
    const drifted = { ...context, plugin_version: '0.18.0' };
    assert.equal(servesRecordedRuntime(drifted, compatible, 'claude'), false);
    assert.equal(servesRecordedRuntime(drifted, breaking, 'claude'), true);
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
});

test('servesRecordedRuntime denies an unidentifiable executing root without throwing', () => {
  const temp = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-lineage-')));
  try {
    const recorded = installManifest(path.join(temp, 'recorded'), '0.17.0');
    const context = { plugin_root: recorded, plugin_version: '0.17.0', host: 'claude' };

    // Each call site owns its own deny message, so this predicate must answer
    // rather than raise: an escaping manifest error would overwrite every
    // site's diagnosis with the same unrelated one.
    const missing = path.join(temp, 'no-manifest');
    fs.mkdirSync(missing);
    assert.equal(servesRecordedRuntime(context, missing, 'claude'), false);

    const foreign = path.join(temp, 'foreign');
    fs.mkdirSync(path.join(foreign, '.claude-plugin'), { recursive: true });
    fs.writeFileSync(
      path.join(foreign, '.claude-plugin', 'plugin.json'),
      `${JSON.stringify({ name: 'not-zensu', version: '0.17.1' })}\n`,
    );
    assert.equal(servesRecordedRuntime(context, foreign, 'claude'), false);

    const malformed = path.join(temp, 'malformed');
    fs.mkdirSync(path.join(malformed, '.claude-plugin'), { recursive: true });
    fs.writeFileSync(path.join(malformed, '.claude-plugin', 'plugin.json'), '{not json');
    assert.equal(servesRecordedRuntime(context, malformed, 'claude'), false);

    const versionless = path.join(temp, 'versionless');
    fs.mkdirSync(path.join(versionless, '.claude-plugin'), { recursive: true });
    fs.writeFileSync(
      path.join(versionless, '.claude-plugin', 'plugin.json'),
      `${JSON.stringify({ name: 'zensu' })}\n`,
    );
    assert.equal(servesRecordedRuntime(context, versionless, 'claude'), false);

    const absent = path.join(temp, 'absent');
    assert.equal(servesRecordedRuntime(context, absent, 'claude'), false);

    // The swallowed exception must never widen to the equal-root short circuit:
    // a recorded root that is itself gone still binds to itself, and only to
    // itself.
    assert.equal(servesRecordedRuntime(context, recorded, 'claude'), true);
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
});
