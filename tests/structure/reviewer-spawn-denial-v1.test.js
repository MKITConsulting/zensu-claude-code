'use strict';

// Pins hooks/lib/reviewer-spawn-denial-v1.js: the transcript scanner that tells
// the Stop chain-enforcer whether the host permission layer refused the reviewer
// spawn it is about to demand again. The properties that matter here cannot be
// observed from the shell suite: a denial is only ever read out of a tool_result
// keyed to a real Agent spawn (never out of model prose that quotes the same
// sentence), a later successful spawn outranks an earlier refusal, and every
// failure mode degrades to "no detection" rather than to a false positive.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const denial = require(path.join(__dirname, '..', '..', 'hooks', 'lib', 'reviewer-spawn-denial-v1.js'));

const CLASSIFIER_TEXT =
  'Permission for this action was denied by the Claude Code auto mode classifier. Reason: Blocked by classifier.';
const GENERIC_TEXT = 'Permission for this action has been denied. Reason: user rejected.';
const REVIEWER = 'zensu:code-reviewer';

function toolUse(id, subagentType, name) {
  return {
    type: 'assistant',
    message: {
      content: [{
        type: 'tool_use',
        id: id,
        name: name || 'Agent',
        input: { subagent_type: subagentType, prompt: 'REVIEW-TICKET: rt_x' },
      }],
    },
  };
}

function toolResult(id, content, isError) {
  return {
    type: 'user',
    message: {
      content: [{
        type: 'tool_result',
        tool_use_id: id,
        is_error: isError === true,
        content: content,
      }],
    },
  };
}

function assistantText(text) {
  return { type: 'assistant', message: { content: [{ type: 'text', text: text }] } };
}

let tmpRoot;
let seq = 0;

test.before(() => {
  tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-denial-'));
});

test.after(() => {
  if (tmpRoot) fs.rmSync(tmpRoot, { recursive: true, force: true });
});

function transcript(entries, trailingNewline) {
  seq += 1;
  const file = path.join(tmpRoot, 'transcript-' + seq + '.jsonl');
  const body = entries.map((e) => (typeof e === 'string' ? e : JSON.stringify(e))).join('\n');
  fs.writeFileSync(file, trailingNewline === false ? body : body + '\n');
  return file;
}

test('a classifier denial keyed to a reviewer spawn reports blocked', () => {
  const file = transcript([
    toolUse('t1', REVIEWER),
    toolResult('t1', CLASSIFIER_TEXT, true),
  ]);
  const report = denial.scanTranscript(file);
  assert.equal(report.status, 'blocked');
  assert.equal(report.kind, 'auto-mode-classifier');
  assert.equal(report.toolName, 'Agent');
  assert.equal(report.subagentType, REVIEWER);
  assert.equal(report.spawns, 1);
  assert.equal(report.denials, 1);
});

test('the generic host denial is recognized as its own kind', () => {
  const file = transcript([
    toolUse('t1', REVIEWER),
    toolResult('t1', GENERIC_TEXT, true),
  ]);
  const report = denial.scanTranscript(file);
  assert.equal(report.status, 'blocked');
  assert.equal(report.kind, 'permission-denied');
});

test('the Task spelling of the spawn tool is recognized', () => {
  const file = transcript([
    toolUse('t1', REVIEWER, 'Task'),
    toolResult('t1', CLASSIFIER_TEXT, true),
  ]);
  const report = denial.scanTranscript(file);
  assert.equal(report.status, 'blocked');
  assert.equal(report.toolName, 'Task');
});

test('a tool_result carrying denial-shaped content in an array block still counts', () => {
  const file = transcript([
    toolUse('t1', REVIEWER),
    toolResult('t1', [{ type: 'text', text: CLASSIFIER_TEXT }], true),
  ]);
  assert.equal(denial.scanTranscript(file).status, 'blocked');
});

test('assistant prose quoting the denial sentence never reports blocked', () => {
  const file = transcript([
    assistantText('The spawn failed: ' + CLASSIFIER_TEXT),
    assistantText('Permission for this action has been denied. Reason: quoted in a plan.'),
  ]);
  const report = denial.scanTranscript(file);
  assert.equal(report.status, 'none');
  assert.equal(report.spawns, 0);
  assert.equal(report.denials, 0);
});

// The bite: for an Agent call the tool_result body IS the subagent's returned
// message. A reviewer reviewing this very module quotes the literals, so keying
// on tool_use_id alone would read its report as a refusal and abandon the chain.
test('a successful reviewer result that quotes a marker reports clear', () => {
  const file = transcript([
    toolUse('t1', REVIEWER),
    toolResult('t1', 'VERDICT: PASS\nThe module matches "' + CLASSIFIER_TEXT + '" as a prefix.', false),
  ]);
  const report = denial.scanTranscript(file);
  assert.equal(report.status, 'clear');
  assert.equal(report.denials, 0);
});

// Pins condition 2 on its own: with the same body the host would send, only the
// error flag separates a refusal from a report. Deleting the `is_error` check
// must fail HERE, not somewhere the prefix test would have caught anyway.
test('a result whose body STARTS with a marker but is not an error reports clear', () => {
  const file = transcript([
    toolUse('t1', REVIEWER),
    toolResult('t1', CLASSIFIER_TEXT, false),
  ]);
  const report = denial.scanTranscript(file);
  assert.equal(report.status, 'clear');
  assert.equal(report.denials, 0);
});

// `errored`, NOT `clear`. The prefix rule still refuses to call this a denial —
// that is condition 3 doing its job — but the host's own error flag is set, so
// this is a refusal shape the module does not recognize, not a spawn that came
// back fine. Reporting `clear` here would have the enforcer RETIRE a note an
// earlier recognized refusal wrote, deleting a correct diagnosis.
test('an errored reviewer result that only mentions a marker mid-text reports errored', () => {
  const file = transcript([
    toolUse('t1', REVIEWER),
    toolResult('t1', 'Agent failed. Context: ' + CLASSIFIER_TEXT, true),
  ]);
  const report = denial.scanTranscript(file);
  assert.equal(report.status, 'errored');
  assert.equal(report.denials, 0);
});

// The other half of the same rule, with no marker text at all: any errored
// reviewer result is `errored`. This is the shape a subagent crash or a
// transport failure takes, and it is the one that used to erase the note.
test('an errored reviewer result with no marker at all reports errored', () => {
  const file = transcript([
    toolUse('t1', REVIEWER),
    toolResult('t1', 'Error: connection reset by peer', true),
  ]);
  const report = denial.scanTranscript(file);
  assert.equal(report.status, 'errored');
  assert.equal(report.denials, 0);
});

// The discriminator for the fix: same body, flag flipped. Only the flag decides
// between the verdict the enforcer acts on and the one it must ignore.
test('the error flag alone separates errored from clear', () => {
  const body = 'Agent failed. Context: ' + CLASSIFIER_TEXT;
  const errored = transcript([toolUse('t1', REVIEWER), toolResult('t1', body, true)]);
  const clean = transcript([toolUse('t1', REVIEWER), toolResult('t1', body, false)]);
  assert.equal(denial.scanTranscript(errored).status, 'errored');
  assert.equal(denial.scanTranscript(clean).status, 'clear');
});

// A recognized refusal followed by an unrecognized error must NOT read as clear:
// this is the exact sequence that deleted the note — refusal, user applies the
// permission, retry dies for an unrelated reason.
test('an unrecognized error after a real denial reports errored, never clear', () => {
  const file = transcript([
    toolUse('t1', REVIEWER),
    toolResult('t1', CLASSIFIER_TEXT, true),
    toolUse('t2', REVIEWER),
    toolResult('t2', 'Error: subagent terminated unexpectedly', true),
  ]);
  const report = denial.scanTranscript(file);
  assert.equal(report.status, 'errored');
  assert.equal(report.denials, 1);
});

test('a denial keyed to a different subagent is not a reviewer denial', () => {
  const file = transcript([
    toolUse('t1', 'zensu:review-aspect'),
    toolResult('t1', CLASSIFIER_TEXT, true),
  ]);
  assert.equal(denial.scanTranscript(file).status, 'none');
});

test('a denial keyed to a non-spawn tool is ignored', () => {
  const file = transcript([
    {
      type: 'assistant',
      message: { content: [{ type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'ls' } }] },
    },
    toolResult('t1', CLASSIFIER_TEXT, true),
  ]);
  assert.equal(denial.scanTranscript(file).status, 'none');
});

test('a tool_result whose id matches no recorded spawn is ignored', () => {
  const file = transcript([toolResult('orphan', CLASSIFIER_TEXT, true)]);
  assert.equal(denial.scanTranscript(file).status, 'none');
});

test('a spawn that returned a review outranks an earlier denial', () => {
  const file = transcript([
    toolUse('t1', REVIEWER),
    toolResult('t1', CLASSIFIER_TEXT, true),
    toolUse('t2', REVIEWER),
    toolResult('t2', 'VERDICT: PASS', false),
  ]);
  const report = denial.scanTranscript(file);
  assert.equal(report.status, 'clear');
  assert.equal(report.kind, '');
  assert.equal(report.spawns, 2);
  assert.equal(report.denials, 1);
});

test('a denial after an earlier successful spawn reports blocked again', () => {
  const file = transcript([
    toolUse('t1', REVIEWER),
    toolResult('t1', 'VERDICT: PASS', false),
    toolUse('t2', REVIEWER),
    toolResult('t2', CLASSIFIER_TEXT, true),
  ]);
  assert.equal(denial.scanTranscript(file).status, 'blocked');
});

test('a spawn with no result yet is neither blocked nor clear', () => {
  const file = transcript([toolUse('t1', REVIEWER)]);
  const report = denial.scanTranscript(file);
  assert.equal(report.status, 'none');
  assert.equal(report.spawns, 1);
});

test('an explicit subagentType option selects what counts as the reviewer', () => {
  const file = transcript([
    toolUse('t1', 'custom:reviewer'),
    toolResult('t1', CLASSIFIER_TEXT, true),
  ]);
  assert.equal(denial.scanTranscript(file).status, 'none');
  const report = denial.scanTranscript(file, { subagentType: 'custom:reviewer' });
  assert.equal(report.status, 'blocked');
  assert.equal(report.subagentType, 'custom:reviewer');
});

test('garbage lines, blank lines and a missing trailing newline are tolerated', () => {
  const file = transcript([
    '',
    'not json at all',
    '{"broken":',
    JSON.stringify(toolUse('t1', REVIEWER)),
    JSON.stringify(toolResult('t1', CLASSIFIER_TEXT, true)),
  ], false);
  assert.equal(denial.scanTranscript(file).status, 'blocked');
});

test('an empty transcript, a missing path and a directory all degrade safely', () => {
  const empty = transcript([], false);
  fs.writeFileSync(empty, '');
  assert.equal(denial.scanTranscript(empty).status, 'none');
  assert.equal(denial.scanTranscript(path.join(tmpRoot, 'absent.jsonl')).status, 'unreadable');
  assert.equal(denial.scanTranscript(tmpRoot).status, 'unreadable');
  assert.equal(denial.scanTranscript('').status, 'none');
  assert.equal(denial.scanTranscript(undefined).status, 'none');
  assert.equal(denial.scanTranscript(null).status, 'none');
  assert.equal(denial.scanTranscript(42).status, 'none');
  assert.equal(denial.scanTranscript('/tmp/a' + String.fromCharCode(0) + 'b').status, 'unreadable');
});

// Both run on the Stop path with no timeout above them: a FIFO would block the
// open forever, and a symlink is a shape the host never hands over, so the
// scanner refuses each before opening rather than after.
test('a symlinked transcript is refused rather than followed', (t) => {
  if (process.platform === 'win32') return t.skip('symlink creation is not reliable on win32');
  const real = transcript([
    toolUse('t1', REVIEWER),
    toolResult('t1', CLASSIFIER_TEXT, true),
  ]);
  const link = path.join(tmpRoot, 'linked-transcript.jsonl');
  try {
    fs.symlinkSync(real, link);
  } catch (e) {
    return t.skip('symlink creation unavailable: ' + e.code);
  }
  assert.ok(fs.lstatSync(link).isSymbolicLink(), 'precondition: the link is a symlink');
  assert.equal(denial.scanTranscript(real).status, 'blocked');
  assert.equal(denial.scanTranscript(link).status, 'unreadable');
});

// This exercises the lstat SHAPE GUARD, not O_NONBLOCK. `!pre.isFile()` answers
// for a FIFO before readTail ever reaches the open, so the flag composition is
// unreachable from here — see the flag test below, which asserts it directly.
// The timeout stays: if the guard is ever removed, a writerless FIFO would hang
// the open, and an unbounded case would hang CI instead of failing it.
test('a FIFO transcript is refused by the lstat shape guard, before any open', { timeout: 5000 }, (t) => {
  if (process.platform === 'win32') return t.skip('no mkfifo on win32');
  const fifo = path.join(tmpRoot, 'fifo-transcript');
  try {
    require('node:child_process').execFileSync('mkfifo', [fifo]);
  } catch (e) {
    return t.skip('mkfifo unavailable');
  }
  assert.ok(fs.lstatSync(fifo).isFIFO(), 'precondition: the path is a FIFO');
  assert.equal(denial.scanTranscript(fifo).status, 'unreadable');
});

// The open flags have no behavioral test that can reach them — both the symlink
// and the FIFO case are answered by the lstat guard first — so they are pinned
// on the composition itself. Without this, deleting either flag leaves the whole
// suite green while the TOCTOU window between lstat and open reopens.
test('the read flags carry O_NONBLOCK, and O_NOFOLLOW off win32', () => {
  const flags = denial.readOnlyFlags();
  assert.equal(typeof flags, 'number');
  assert.equal(flags & fs.constants.O_ACCMODE, fs.constants.O_RDONLY);
  if (Number.isInteger(fs.constants.O_NONBLOCK)) {
    assert.notEqual(flags & fs.constants.O_NONBLOCK, 0, 'O_NONBLOCK must be set');
  }
  if (process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW)) {
    assert.notEqual(flags & fs.constants.O_NOFOLLOW, 0, 'O_NOFOLLOW must be set off win32');
  }
});

// The two literals are the feature's entire premise, and they were read out of
// one specific host build. Nothing else in this repo can notice a reword — the
// scanner just stops matching and every check stays green. Pinning the version
// against the header forces a human to re-verify when either is touched, rather
// than letting the constant drift away from the provenance note beside it.
test('the denial-marker provenance names the build the literals came from', () => {
  const build = denial.DENIAL_MARKERS_SOURCE_BUILD;
  assert.match(build, /^\d+\.\d+\.\d+$/);
  const src = fs.readFileSync(
    path.join(__dirname, '..', '..', 'hooks', 'lib', 'reviewer-spawn-denial-v1.js'), 'utf8');
  const header = src.slice(0, src.indexOf('const fs = require'));
  assert.ok(
    header.includes('(' + build + ')'),
    'the module header must name build ' + build + ' beside the literals it describes');
});

test('only the tail of an oversized transcript is scanned', () => {
  seq += 1;
  const file = path.join(tmpRoot, 'huge-' + seq + '.jsonl');
  const filler = JSON.stringify(assistantText('x'.repeat(4096))) + '\n';
  const head = JSON.stringify(toolUse('t1', REVIEWER)) + '\n'
    + JSON.stringify(toolResult('t1', CLASSIFIER_TEXT, true)) + '\n';
  fs.writeFileSync(file, head);
  const chunk = filler.repeat(256);
  let written = head.length;
  while (written < denial.MAX_TAIL_BYTES + chunk.length) {
    fs.appendFileSync(file, chunk);
    written += chunk.length;
  }
  assert.ok(fs.statSync(file).size > denial.MAX_TAIL_BYTES);
  assert.equal(denial.scanTranscript(file).status, 'none');
});

// The byte bound and the line bound are separate clamps; the oversize case
// above drives only the first. This one stays well under MAX_TAIL_BYTES so the
// only thing that can discard the denial is MAX_LINES.
test('the line clamp discards records beyond MAX_LINES even inside the byte bound', () => {
  seq += 1;
  const file = path.join(tmpRoot, 'many-lines-' + seq + '.jsonl');
  const head = JSON.stringify(toolUse('t1', REVIEWER)) + '\n'
    + JSON.stringify(toolResult('t1', CLASSIFIER_TEXT, true)) + '\n';
  const filler = '{"type":"assistant","message":{"content":[]}}\n'.repeat(denial.MAX_LINES + 10);
  fs.writeFileSync(file, head + filler);
  assert.ok(fs.statSync(file).size < denial.MAX_TAIL_BYTES, 'precondition: inside the byte bound');
  assert.equal(denial.scanTranscript(file).status, 'none');
});

test('the source carries no literal NUL byte', () => {
  const src = fs.readFileSync(
    path.join(__dirname, '..', '..', 'hooks', 'lib', 'reviewer-spawn-denial-v1.js'),
    'utf8',
  );
  assert.equal(src.split(String.fromCharCode(0)).length - 1, 0);
});

test('the denial markers are the host literals, matched as prefixes', () => {
  assert.equal(denial.DENIAL_MARKERS.length, 2);
  const kinds = denial.DENIAL_MARKERS.map((m) => m.kind);
  assert.deepEqual(kinds, ['auto-mode-classifier', 'permission-denied']);
  denial.DENIAL_MARKERS.forEach((m) => {
    assert.ok(m.text.startsWith('Permission for this action '));
    assert.ok(!/Reason:/.test(m.text));
    assert.ok(Object.isFrozen(m));
  });
  assert.ok(Object.isFrozen(denial.DENIAL_MARKERS));
  assert.deepEqual(denial.SPAWN_TOOL_NAMES.slice(), ['Agent', 'Task']);
  assert.equal(denial.REVIEWER_SUBAGENT_TYPE, REVIEWER);
});

test('the CLI prints one parsable status line and never fails', () => {
  const file = transcript([
    toolUse('t1', REVIEWER),
    toolResult('t1', CLASSIFIER_TEXT, true),
  ]);
  const { execFileSync } = require('node:child_process');
  const script = path.join(__dirname, '..', '..', 'hooks', 'lib', 'reviewer-spawn-denial-v1.js');
  const blocked = execFileSync(process.execPath, [script, '--transcript', file], { encoding: 'utf8' });
  assert.match(blocked, /^status=blocked kind=auto-mode-classifier tool=Agent spawns=1 denials=1\n$/);
  const absent = execFileSync(process.execPath, [script, '--transcript', path.join(tmpRoot, 'nope')], { encoding: 'utf8' });
  assert.match(absent, /^status=unreadable /);
  const noArgs = execFileSync(process.execPath, [script], { encoding: 'utf8' });
  assert.match(noArgs, /^status=none /);
});
