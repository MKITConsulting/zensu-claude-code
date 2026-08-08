'use strict';

const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const MODULE_PATH = path.join(__dirname, '..', '..', 'hooks', 'lib', 'plan-payload-v1.js');
const payload = require(MODULE_PATH);

const CODES = payload.EXIT_CODES;
const NUL = String.fromCharCode(0);

const WORK = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-plan-payload-'));
process.on('exit', () => { try { fs.rmSync(WORK, { recursive: true, force: true }); } catch (_) {} });

function fixture(name, contents) {
  const target = path.join(WORK, name);
  fs.writeFileSync(target, contents);
  return target;
}

function refusalOf(run) {
  try {
    run();
  } catch (error) {
    return payload.exitCodeOf(error);
  }
  return null;
}

const CAPABILITY_CODES = new Set(['EPERM', 'EACCES', 'ENOSYS', 'EOPNOTSUPP', 'ENOTSUP']);

// Returns null when the operation SUCCEEDED, and the errno string when the
// platform cannot perform it. Anything that is not a capability refusal is
// re-thrown, so a broken fixture cannot look like a platform limitation and
// silently delete the assertions behind it.
function attempt(make) {
  try {
    make();
    return null;
  } catch (error) {
    if (error && CAPABILITY_CODES.has(error.code)) return error.code;
    throw error;
  }
}

test('the source table is the frozen precedence contract', () => {
  assert.deepEqual(
    payload.PLAN_SOURCES.map((source) => [source.container, source.key, source.kind]),
    [
      ['toolResponse', 'plan', 'text'],
      ['toolResponse', 'filePath', 'file'],
      ['toolInput', 'plan', 'text'],
      ['toolInput', 'planFilePath', 'file'],
    ],
  );
  assert.ok(Object.isFrozen(payload.PLAN_SOURCES));
  for (const source of payload.PLAN_SOURCES) assert.ok(Object.isFrozen(source));
  for (const source of payload.PLAN_SOURCES) {
    assert.ok(payload.CONTAINERS.some((entry) => entry.name === source.container));
    assert.ok(source.kind === 'text' || source.kind === 'file');
  }
  assert.ok(Object.isFrozen(payload.CONTAINERS));
  for (const entry of payload.CONTAINERS) {
    assert.ok(Object.isFrozen(entry));
    assert.equal(typeof entry.strict, 'boolean');
    assert.ok(typeof entry.name === 'string' && entry.name !== '');
  }
  for (const source of payload.PLAN_SOURCES) {
    assert.ok(typeof source.key === 'string' && source.key !== '');
  }
});

test('both tables are validated at load time, not by a per-call runtime guard', () => {
  const source = fs.readFileSync(MODULE_PATH, 'utf8');
  const declaration = source.slice(0, source.indexOf('class PlanPayloadRefusal'));
  // A malformed entry must throw inside require(), which the hook maps to
  // PLAN_EVALUATION_UNAVAILABLE, rather than degrade to a silently skipped
  // source or a payload string routed into the filesystem branch.
  // Each check must be a THROWING statement, not merely present: a validator
  // wrapped in a function nobody calls would satisfy a bare substring match.
  assert.match(declaration, /if \(typeof entry\.strict !== 'boolean'\) \{\s*\n\s*throw new Error\(/);
  assert.match(declaration, /if \(typeof entry\.name !== 'string' \|\| entry\.name === ''\) \{\s*\n\s*throw new Error\(/);
  assert.match(declaration, /if \(DECLARED_CONTAINERS\.indexOf\(source\.container\) < 0\) \{\s*\n\s*throw new Error\(/);
  assert.match(declaration, /if \(typeof source\.key !== 'string' \|\| source\.key === ''\) \{\s*\n\s*throw new Error\(/);
  assert.match(declaration, /if \(source\.kind !== 'text' && source\.kind !== 'file'\) \{\s*\n\s*throw new Error\(/);
  assert.match(declaration, /plan-payload container name is declared twice/);
  // The loops must be top-level statements of the declaration region, so the
  // throws happen during require() rather than in an uncalled helper.
  assert.match(declaration, /^for \(const entry of CONTAINERS\) \{$/m);
  assert.match(declaration, /^for \(const source of PLAN_SOURCES\) \{$/m);
  assert.equal(/function validate/.test(declaration), false);
  assert.equal(/hasOwnProperty\.call\(containers/.test(source), false);
});

test('every declared container is consulted, and its drift policy comes from the declaration', () => {
  for (const entry of payload.CONTAINERS) {
    const textSource = payload.PLAN_SOURCES.find((s) => s.container === entry.name && s.kind === 'text');
    assert.ok(textSource, 'no text source declared for container ' + entry.name);
    const supplied = {};
    supplied[entry.name] = { [textSource.key]: 'plan from ' + entry.name };
    const result = payload.readPlanPayload(supplied);
    assert.equal(result.plan, 'plan from ' + entry.name);
    assert.equal(result.source.container, entry.name);

    // A strict container refuses a present non-object as drift; a lenient one
    // treats it as absence. Both directions are pinned so a new container
    // cannot silently inherit the permissive branch.
    const drifted = {};
    drifted[entry.name] = ['not-an-object'];
    const other = payload.CONTAINERS.find((c) => c.name !== entry.name);
    const otherSource = payload.PLAN_SOURCES.find((s) => s.container === other.name && s.kind === 'text');
    drifted[other.name] = { [otherSource.key]: 'fallback plan' };
    if (entry.strict) {
      assert.equal(refusalOf(() => payload.readPlanPayload(drifted)), CODES.PLAN_RESPONSE_SHAPE_REJECTED);
    } else {
      assert.equal(payload.readPlanPayload(drifted).source.container, other.name);
    }
  }
});

test('the exit-code contract is frozen, distinct, and transportable as a process status', () => {
  assert.ok(Object.isFrozen(CODES));
  const values = Object.values(CODES);
  assert.equal(new Set(values).size, values.length);
  for (const value of values) assert.ok(Number.isInteger(value) && value > 0 && value < 256);
  assert.deepEqual(CODES, {
    INVALID_PLAN_PAYLOAD: 3,
    PLAN_FILE_UNREADABLE: 8,
    PLAN_FILE_PATH_REJECTED: 10,
    PLAN_FILE_NOT_REGULAR: 11,
    PLAN_FILE_EMPTY: 12,
    PLAN_FILE_TOO_LARGE: 13,
    PLAN_FILE_SYMLINK_REJECTED: 14,
    PLAN_PAYLOAD_FIELD_TYPE_REJECTED: 15,
    PLAN_RESPONSE_SHAPE_REJECTED: 16,
  });
});

test('the module never terminates the host process', () => {
  const source = fs.readFileSync(MODULE_PATH, 'utf8');
  assert.equal(/process\.exit\s*\(/.test(source), false);
  assert.equal(/process\.abort\s*\(/.test(source), false);
});

test('exitCodeOf recognizes only a refusal carrying a table code', () => {
  assert.equal(payload.exitCodeOf(new Error('boom')), null);
  assert.equal(payload.exitCodeOf(null), null);
  assert.equal(payload.exitCodeOf({ exitCode: 3 }), null);
  assert.equal(payload.exitCodeOf(new payload.PlanPayloadRefusal(CODES.INVALID_PLAN_PAYLOAD)), 3);
  assert.equal(payload.exitCodeOf(new payload.PlanPayloadRefusal(256)), null);
  assert.equal(payload.exitCodeOf(new payload.PlanPayloadRefusal(0)), null);
  assert.equal(payload.exitCodeOf(new payload.PlanPayloadRefusal(9)), null);
});

test('a present non-object tool response is drift, not absence', () => {
  for (const shape of ['text', 7, true, ['a'], []]) {
    assert.equal(refusalOf(() => payload.normalizeToolResponse(shape)), CODES.PLAN_RESPONSE_SHAPE_REJECTED);
    assert.equal(
      refusalOf(() => payload.readPlanPayload({ toolInput: { plan: 'legacy' }, toolResponse: shape })),
      CODES.PLAN_RESPONSE_SHAPE_REJECTED,
    );
  }
  assert.deepEqual(payload.normalizeToolResponse(undefined), {});
  assert.deepEqual(payload.normalizeToolResponse(null), {});
  const response = { plan: 'x' };
  assert.equal(payload.normalizeToolResponse(response), response);
});

test('readStringField treats absence as empty and a wrong type as drift', () => {
  assert.equal(payload.readStringField({}, 'plan'), '');
  assert.equal(payload.readStringField({ plan: undefined }, 'plan'), '');
  assert.equal(payload.readStringField({ plan: null }, 'plan'), '');
  assert.equal(payload.readStringField({ plan: '' }, 'plan'), '');
  assert.equal(payload.readStringField({ plan: 'text' }, 'plan'), 'text');
  assert.equal(payload.readStringField(undefined, 'plan'), '');
  assert.equal(payload.readStringField('not-an-object', 'plan'), '');
  for (const wrong of [1, true, {}, ['a'], () => 'x']) {
    assert.equal(
      refusalOf(() => payload.readStringField({ plan: wrong }, 'plan')),
      CODES.PLAN_PAYLOAD_FIELD_TYPE_REJECTED,
    );
  }
});

test('a path is refused before any filesystem access', () => {
  assert.equal(refusalOf(() => payload.readPlanFile('relative.md')), CODES.PLAN_FILE_PATH_REJECTED);
  assert.equal(refusalOf(() => payload.readPlanFile('')), CODES.PLAN_FILE_PATH_REJECTED);
  assert.equal(refusalOf(() => payload.readPlanFile('//server/share/plan.md')), CODES.PLAN_FILE_PATH_REJECTED);
  assert.equal(refusalOf(() => payload.readPlanFile('\\\\server\\share\\plan.md')), CODES.PLAN_FILE_PATH_REJECTED);
  assert.equal(refusalOf(() => payload.readPlanFile(path.join(WORK, 'nul' + NUL + 'name.md'))), CODES.PLAN_FILE_PATH_REJECTED);
  assert.equal(refusalOf(() => payload.readPlanFile(7)), CODES.PLAN_FILE_PATH_REJECTED);
});

// A per-test `timeout` cannot bound this case: the failure mode it guards is a
// synchronous fs.openSync on a FIFO, which owns the only thread the runner's
// timer could fire on. The source pin below therefore runs BEFORE the FIFO is
// ever opened — losing O_NONBLOCK turns the case red instead of hanging it.
test('the path-refusal matrix covers every rejected file shape', (t) => {
  // Unconditional positive control for the diagnostic channel: F56 in
  // test-plan-payload-fallback.sh fails when this token is missing, so a
  // silently broken reporter cannot read as full coverage.
  t.diagnostic('ARM-PROBE ok');
  const readerSource = fs.readFileSync(MODULE_PATH, 'utf8');
  // Pin the BINDING, not just the identifier: a refactor leaving nonBlock at 0
  // while the literal survives in a comment would satisfy a loose match and
  // reinstate the hang.
  assert.match(readerSource, /^  const nonBlock = Number\.isInteger\(fs\.constants\.O_NONBLOCK\) \? fs\.constants\.O_NONBLOCK : 0;$/m);
  assert.match(readerSource, /fs\.openSync\(planPath, fs\.constants\.O_RDONLY \| noFollow \| nonBlock\)/);

  assert.equal(
    refusalOf(() => payload.readPlanFile(path.join(WORK, 'absent.md'))),
    CODES.PLAN_FILE_UNREADABLE,
  );

  const directory = path.join(WORK, 'a-directory');
  fs.mkdirSync(directory);
  assert.equal(refusalOf(() => payload.readPlanFile(directory)), CODES.PLAN_FILE_NOT_REGULAR);

  assert.equal(refusalOf(() => payload.readPlanFile(fixture('empty.md', ''))), CODES.PLAN_FILE_EMPTY);

  const oversize = fixture('oversize.md', 'x');
  fs.truncateSync(oversize, payload.PLAN_FILE_MAX_BYTES + 1);
  assert.equal(refusalOf(() => payload.readPlanFile(oversize)), CODES.PLAN_FILE_TOO_LARGE);

  // The shell siblings F17 and F54 pass-on-skip where the platform cannot make
  // links, and this suite runs inside that same Windows inventory through F56.
  // Symlinks and hard links are SEPARATE capabilities, so one missing must not
  // suppress the other's assertion.
  const target = fixture('symlink-target.md', 'plan bytes\n');
  const link = path.join(WORK, 'symlink.md');
  const symlinkGap = attempt(() => fs.symlinkSync(target, link));
  if (symlinkGap) t.diagnostic('ARM-SKIPPED symlink: ' + symlinkGap);
  else assert.equal(refusalOf(() => payload.readPlanFile(link)), CODES.PLAN_FILE_SYMLINK_REJECTED);

  const linked = fixture('hardlink-target.md', 'plan bytes\n');
  const hardlinkGap = attempt(() => fs.linkSync(linked, path.join(WORK, 'hardlink.md')));
  if (hardlinkGap) t.diagnostic('ARM-SKIPPED hardlink: ' + hardlinkGap);
  else assert.equal(refusalOf(() => payload.readPlanFile(linked)), CODES.PLAN_FILE_SYMLINK_REJECTED);

  // O_NONBLOCK is what keeps a FIFO at the plan path from hanging the hook
  // forever, and only a FIFO case makes its removal observable.
  const fifo = path.join(WORK, 'plan.fifo');
  let fifoGap = process.platform === 'win32' ? 'win32' : null;
  if (!fifoGap) {
    try {
      execFileSync('mkfifo', [fifo], { timeout: 60000, stdio: 'ignore' });
    } catch (error) {
      // ENOENT means the platform ships no mkfifo. A stalled spawn is an
      // environment condition and says so; anything else is a broken fixture
      // and must not masquerade as a capability gap.
      if (error && error.code === 'ETIMEDOUT') {
        throw new Error('mkfifo did not complete within 60s — runner stall, not a fixture defect');
      }
      if (error && (error.code === 'ENOENT' || CAPABILITY_CODES.has(error.code))) fifoGap = error.code;
      else throw error;
    }
    if (!fifoGap && !fs.lstatSync(fifo).isFIFO()) throw new Error('mkfifo produced a non-FIFO fixture');
  }
  if (fifoGap) t.diagnostic('ARM-SKIPPED fifo: ' + fifoGap);
  else assert.equal(refusalOf(() => payload.readPlanFile(fifo)), CODES.PLAN_FILE_NOT_REGULAR);

  if (symlinkGap && hardlinkGap && fifoGap) t.skip('platform provides none of symlink, hard link or FIFO');
});

test('defaultNoFollowFlag states the real per-platform contract', () => {
  const expected = process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW)
    ? fs.constants.O_NOFOLLOW
    : 0;
  assert.equal(payload.defaultNoFollowFlag(), expected);
  if (process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW)) {
    assert.notEqual(payload.defaultNoFollowFlag(), 0);
  }
});

test('the noFollow seam selects a mode, it never accepts a caller flag mask', (t) => {
  const target = fixture('seam-target.md', 'seam bytes\n');
  const BOGUS = [1, 1024, fs.constants.O_RDWR, -1, '0', true, null, undefined];
  // A legitimate read must still work for every non-zero value...
  for (const bogus of BOGUS) {
    assert.ok(payload.readPlanFile(target, { noFollow: bogus }).equals(Buffer.from('seam bytes\n')));
  }
  // ...and the symlink defence must still fire. This is the half that fails for
  // a mask-accepting implementation: with the caller's bits ORed in, neither
  // O_NOFOLLOW nor the lstat fallback runs and the link is followed.
  const link = path.join(WORK, 'seam-link.md');
  const gap = attempt(() => fs.symlinkSync(target, link));
  if (gap) t.diagnostic('ARM-SKIPPED seam-symlink: ' + gap);
  else {
    for (const bogus of BOGUS) {
      assert.equal(
        refusalOf(() => payload.readPlanFile(link, { noFollow: bogus })),
        CODES.PLAN_FILE_SYMLINK_REJECTED,
      );
    }
  }
  const source = fs.readFileSync(MODULE_PATH, 'utf8');
  assert.match(source, /^  const noFollow = \w+\.noFollow === 0 \? 0 : defaultNoFollowFlag\(\);$/m);
});

test('a short read is refused, never digested as a zero-padded buffer', () => {
  const target = fixture('short-read.md', 'plan bytes for a short read\n');
  const realReadSync = fs.readSync;
  try {
    // Deliver one byte less than asked for. Without the filled !== stat.size
    // arm the reader would digest a buffer whose tail is zeros — bytes that are
    // not the file's, which is the integrity class F23/F44 exist to protect.
    fs.readSync = function shortReadSync(descriptor, buffer, offset, length, position) {
      return realReadSync.call(fs, descriptor, buffer, offset, Math.max(0, length - 1), position);
    };
    assert.equal(refusalOf(() => payload.readPlanFile(target)), CODES.PLAN_FILE_UNREADABLE);
  } finally {
    fs.readSync = realReadSync;
  }
  assert.ok(payload.readPlanFile(target).equals(Buffer.from('plan bytes for a short read\n', 'utf8')));
});

test('a multi-byte text source is digested as UTF-8, not as a single-byte encoding', () => {
  const text = 'Café plan — naïve ✓\n\n<!-- zensu-autopilot:run_x -->\n';
  const result = payload.readPlanPayload({ toolResponse: { plan: text } });
  assert.equal(result.plan, text);
  assert.ok(result.bytes.equals(Buffer.from(text, 'utf8')));
  assert.ok(result.bytes.length > text.length);
  // A latin1/ascii/binary encoding would produce one byte per code unit.
  assert.notEqual(result.bytes.length, Buffer.byteLength(text, 'latin1'));
  const source = fs.readFileSync(MODULE_PATH, 'utf8');
  assert.match(source, /Buffer\.from\(value, 'utf8'\)/);
});

test('the O_NOFOLLOW-unavailable fallback is exercised, not merely declared', (t) => {
  const target = fixture('nofollow-target.md', 'fallback bytes\n');
  // With noFollow forced to 0 the reader must take the lstat pre-check and the
  // post-open dev/ino recheck instead of the kernel flag. Both are dead code on
  // a POSIX runner otherwise.
  assert.ok(payload.readPlanFile(target, { noFollow: 0 }).equals(Buffer.from('fallback bytes\n')));
  assert.equal(
    refusalOf(() => payload.readPlanFile(path.join(WORK, 'nofollow-absent.md'), { noFollow: 0 })),
    CODES.PLAN_FILE_UNREADABLE,
  );

  // Executing the fallback is not the same as pinning it: with an ordinary file
  // the dev/ino recheck only takes its equal branch, and the symlink refusal
  // below is also reachable through the lstat pre-check alone. Both statements
  // are therefore pinned at the source level, the way F11c pins the hook.
  const source = fs.readFileSync(MODULE_PATH, 'utf8');
  assert.match(source, /\(before\.dev !== stat\.dev \|\| before\.ino !== stat\.ino\)\) failure = EXIT_CODES\.PLAN_FILE_SYMLINK_REJECTED;/);
  assert.match(source, /fs\.fstatSync\(descriptor\)/);
  assert.match(source, /fs\.readSync\(descriptor,/);
  assert.equal(/readFileSync/.test(source), false);
  // O_NONBLOCK is what keeps a FIFO from blocking the open. The FIFO arm above
  // proves it behaviorally where the platform allows one; this pins it
  // everywhere else, including the Windows lane.
  assert.match(source, /fs\.constants\.O_NONBLOCK/);
  assert.match(source, /fs\.openSync\(planPath, fs\.constants\.O_RDONLY \| noFollow \| nonBlock\)/);

  const link = path.join(WORK, 'nofollow-link.md');
  const gap = attempt(() => fs.symlinkSync(target, link));
  if (gap) {
    t.diagnostic('ARM-SKIPPED lstat-symlink: ' + gap);
    return;
  }
  assert.equal(
    refusalOf(() => payload.readPlanFile(link, { noFollow: 0 })),
    CODES.PLAN_FILE_SYMLINK_REJECTED,
  );
});

test('an accepted plan file is returned as raw bytes at its exact size', () => {
  const contents = Buffer.from('plan ü bytes\r\n tail', 'utf8');
  const target = path.join(WORK, 'accepted.md');
  fs.writeFileSync(target, contents);
  const bytes = payload.readPlanFile(target);
  assert.ok(Buffer.isBuffer(bytes));
  assert.equal(bytes.length, contents.length);
  assert.ok(bytes.equals(contents));

  const atCeiling = fixture('at-ceiling.md', 'x');
  fs.truncateSync(atCeiling, payload.PLAN_FILE_MAX_BYTES);
  assert.equal(payload.readPlanFile(atCeiling).length, payload.PLAN_FILE_MAX_BYTES);
});

test('the response tier outranks the legacy tool_input tier', () => {
  const filePath = fixture('response-file.md', 'from response file\n');
  const inputPath = fixture('input-file.md', 'from input file\n');

  const winner = payload.readPlanPayload({
    toolInput: { plan: 'from tool_input', planFilePath: inputPath },
    toolResponse: { plan: 'from tool_response', filePath },
  });
  assert.equal(winner.plan, 'from tool_response');
  assert.ok(winner.bytes.equals(Buffer.from('from tool_response', 'utf8')));
  assert.equal(winner.source.container, 'toolResponse');
  assert.equal(winner.source.key, 'plan');

  const viaResponseFile = payload.readPlanPayload({
    toolInput: { plan: 'from tool_input', planFilePath: inputPath },
    toolResponse: { filePath },
  });
  assert.equal(viaResponseFile.plan, 'from response file\n');
  assert.ok(Buffer.isBuffer(viaResponseFile.bytes));
  assert.ok(viaResponseFile.bytes.equals(Buffer.from('from response file\n', 'utf8')));
  assert.equal(viaResponseFile.source.key, 'filePath');

  const viaInputText = payload.readPlanPayload({
    toolInput: { plan: 'from tool_input', planFilePath: inputPath },
    toolResponse: {},
  });
  assert.equal(viaInputText.plan, 'from tool_input');
  assert.equal(viaInputText.source.container, 'toolInput');

  const viaInputFile = payload.readPlanPayload({
    toolInput: { planFilePath: inputPath },
    toolResponse: {},
  });
  assert.equal(viaInputFile.plan, 'from input file\n');
  assert.equal(viaInputFile.source.key, 'planFilePath');
});

test('an empty response tier descends instead of wedging the gate', () => {
  const result = payload.readPlanPayload({
    toolInput: { plan: 'legacy plan' },
    toolResponse: { plan: '', filePath: '' },
  });
  assert.equal(result.plan, 'legacy plan');
  assert.equal(result.source.container, 'toolInput');
});

test('a payload with no plan anywhere is INVALID_PLAN_PAYLOAD', () => {
  assert.equal(refusalOf(() => payload.readPlanPayload({})), CODES.INVALID_PLAN_PAYLOAD);
  assert.equal(refusalOf(() => payload.readPlanPayload({ toolInput: {}, toolResponse: {} })), CODES.INVALID_PLAN_PAYLOAD);
  assert.equal(refusalOf(() => payload.readPlanPayload(undefined)), CODES.INVALID_PLAN_PAYLOAD);
  assert.equal(refusalOf(() => payload.readPlanPayload({ toolInput: 'text' })), CODES.INVALID_PLAN_PAYLOAD);
});

test('a losing source never suppresses a winning refusal', () => {
  assert.equal(
    refusalOf(() => payload.readPlanPayload({
      toolInput: { plan: 'legacy plan' },
      toolResponse: { filePath: path.join(WORK, 'absent.md') },
    })),
    CODES.PLAN_FILE_UNREADABLE,
  );
  assert.equal(
    refusalOf(() => payload.readPlanPayload({
      toolInput: { plan: 'legacy plan' },
      toolResponse: { plan: 42 },
    })),
    CODES.PLAN_PAYLOAD_FIELD_TYPE_REJECTED,
  );
});

test('an out-of-table refusal code cannot be minted and is never a silent status', () => {
  const source = fs.readFileSync(MODULE_PATH, 'utf8');
  assert.match(source, /function refuse\(exitCode\) \{\s*\n\s*if \(!CODE_VALUES\.includes\(exitCode\)\) \{/);
  // A frozen Set would still accept .add/.delete, so the allowlist must not be one.
  assert.equal(/new Set\(/.test(source), false);
  assert.equal(payload.exitCodeOf(new payload.PlanPayloadRefusal(512)), null);
});

test('the module keeps a small public surface', () => {
  assert.deepEqual(Object.keys(module.require(MODULE_PATH)).sort(), [
    'CONTAINERS',
    'EXIT_CODES',
    'PLAN_FILE_MAX_BYTES',
    'PLAN_SOURCES',
    'PlanPayloadRefusal',
    'defaultNoFollowFlag',
    'exitCodeOf',
    'normalizeToolResponse',
    'readPlanFile',
    'readPlanPayload',
    'readStringField',
  ]);
});
