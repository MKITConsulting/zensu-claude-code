'use strict';

// Executable coverage for the `run_step` diagnostic wrapper embedded in the
// "Draft, attach, publish, and verify immutable release" step of
// .github/workflows/release.yml.
//
// Why this file exists: the wrapper's entire value is behavioural, and
// tests/structure/test-immutable-marketplace-release.sh can only grep the YAML
// as source text. A wrapper that is present but broken passes every grep and
// fails during a real release — which is exactly what happened: the annotation
// was emitted on fd 1 while both `gh api` call sites carried a trailing
// `>/dev/null`, so the annotation the change exists to produce was discarded at
// the one call that flips a release live. A grep pin matched the call site and
// stayed green. Only executing the wrapper catches that class.
//
// Driven from tests/structure/test-immutable-marketplace-release.sh so it lands
// in ciStructureTests; tests/run-all.sh discovers only test-*.sh.
//
// TWO fidelity bounds, stated rather than left implied:
//   * The body is driven WITHOUT `set -e`, because every case observes `rc=$?`
//     after the call. Production runs `set -euo pipefail`, so the abort-on-failure
//     behaviour the step relies on is NOT exercised here — say unverified, not
//     covered.
//   * The harness opens fd 3 the way the step body does (`exec 3>&1`). The wrapper
//     writes its annotation there, so a harness that omits it would see no
//     annotation at all and every case below would fail for the wrong reason.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const WORKFLOW = path.join(ROOT, '.github', 'workflows', 'release.yml');

function extractRunStep() {
  const lines = fs.readFileSync(WORKFLOW, 'utf8').split('\n');
  const start = lines.findIndex((l) => /^\s*run_step\(\) \{\s*$/.test(l));
  assert.ok(start !== -1, 'run_step() definition not found in release.yml');
  const indent = lines[start].match(/^(\s*)/)[1];
  const end = lines.findIndex((l, i) => i > start && l === `${indent}}`);
  assert.ok(end !== -1, 'run_step() closing brace not found');
  return lines
    .slice(start, end + 1)
    .map((l) => (l.startsWith(indent) ? l.slice(indent.length) : l))
    .join('\n');
}

function drive(script) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'run-step-'));
  const file = path.join(dir, 'drive.sh');
  fs.writeFileSync(
    file,
    `set -uo pipefail\nexec 3>&1\n${extractRunStep()}\n${script}\n`,
  );
  try {
    return spawnSync('bash', [file], { encoding: 'utf8' });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

const FAILING = `bash -c 'echo payload; echo "HTTP 404: Not Found" >&2; exit 22'`;
const OK = `bash -c 'echo payload; echo notice >&2; exit 0'`;

test('a succeeding command passes stdout and stderr through and returns 0', () => {
  const r = drive(`run_step "asset upload" ${OK}; echo "rc=$?"`);
  assert.match(r.stdout, /payload/);
  assert.match(r.stderr, /notice/);
  assert.match(r.stdout, /rc=0/);
  assert.doesNotMatch(r.stdout + r.stderr, /::error::/);
});

test('a failing command annotates itself with label, exit code and first stderr line', () => {
  const r = drive(`run_step "asset upload" ${FAILING}; echo "rc=$?"`);
  assert.match(r.stdout, /::error::asset upload failed \(exit 22\): HTTP 404: Not Found/);
  assert.match(r.stdout, /rc=22/);
});

test('a failing command replays its full stderr on fd 2', () => {
  const r = drive(`run_step "asset upload" ${FAILING}; true`);
  assert.match(r.stderr, /--- stderr of: /);
  assert.match(r.stderr, /HTTP 404: Not Found/);
});

// --quiet suppresses the WRAPPED command's stdout. Since the annotation moved to
// fd 3 this is a payload-noise control rather than a correctness one, but the
// property still has to hold: suppressing output must never suppress the report.
test('--quiet suppresses the wrapped stdout but never the annotation', () => {
  const r = drive(`run_step --quiet "publishing draft" ${FAILING}; echo "rc=$?"`);
  assert.doesNotMatch(r.stdout, /payload/);
  assert.match(r.stdout, /::error::publishing draft failed \(exit 22\): HTTP 404: Not Found/);
  assert.match(r.stdout, /rc=22/);
});

// The regression this file exists for, in its general form. A caller's redirect
// on the run_step SIMPLE COMMAND used to take the annotation with it, because the
// annotation shared fd 1 with the wrapped command's payload. On fd 3 it cannot.
test("a caller's stdout redirect cannot reach the annotation", () => {
  const r = drive(`run_step "publishing draft" ${FAILING} >/dev/null; echo "rc=$?"`);
  assert.doesNotMatch(r.stdout, /payload/);
  assert.match(r.stdout, /::error::publishing draft failed \(exit 22\): HTTP 404: Not Found/);
  assert.match(r.stdout, /rc=22/);
});

test('run_step refuses a call with no command instead of dying on an unbound variable', () => {
  const r = drive(`run_step; echo "rc=$?"`);
  assert.match(r.stdout, /::error::run_step called without a label and a command/);
  assert.match(r.stdout, /rc=2/);
  assert.doesNotMatch(r.stderr, /unbound variable/);
});

test('--quiet still returns 0 for a succeeding command', () => {
  const r = drive(`run_step --quiet "publishing draft" ${OK}; echo "rc=$?"`);
  assert.doesNotMatch(r.stdout, /payload/);
  assert.match(r.stdout, /rc=0/);
  assert.doesNotMatch(r.stdout + r.stderr, /::error::/);
});

// A command that fails writing only to stdout has no first stderr line. The
// annotation must still name the operation rather than going silent.
test('a failure with no stderr still annotates, with the explicit fallback', () => {
  const r = drive(`run_step "draft creation" bash -c 'echo only-stdout; exit 3'; true`);
  assert.match(r.stdout, /::error::draft creation failed \(exit 3\): no stderr output/);
});

// The annotation carries a remote-influenced string. head -1 is what keeps a
// crafted multi-line stderr from opening a second workflow command, so it is a
// control rather than cosmetics.
test('only the first stderr line reaches the annotation', () => {
  const r = drive(
    `run_step "publishing draft" bash -c 'printf "first\\n::notice::injected\\n" >&2; exit 4'; true`,
  );
  const annotations = r.stdout.split('\n').filter((l) => l.startsWith('::'));
  assert.strictEqual(annotations.length, 1);
  assert.match(annotations[0], /^::error::publishing draft failed \(exit 4\): first$/);
});

// The wrapper anchors its temp file under RUNNER_TEMP, so point that at an
// empty directory and count only the wrapper's own files. Counting entries in
// the ambient temp dir measures every other process on the machine instead.
test('the wrapper removes its temp file on both the success and the failure path', () => {
  const r = drive(
    `export RUNNER_TEMP="$(mktemp -d)"\n` +
      `run_step "a" ${OK} >/dev/null 2>&1\n` +
      `run_step "b" ${FAILING} >/dev/null 2>&1\n` +
      `left="$(find "$RUNNER_TEMP" -name 'release-run-step.*' | wc -l | tr -d ' ')"\n` +
      `rm -rf "$RUNNER_TEMP"\n` +
      `echo "left=$left"`,
  );
  assert.match(r.stdout, /left=0/);
});

test('the wrapper honours RUNNER_TEMP for its temp file', () => {
  const r = drive(
    `export RUNNER_TEMP="$(mktemp -d)"\n` +
      `run_step "a" bash -c 'find "$RUNNER_TEMP" -name "release-run-step.*" | wc -l | tr -d " "'\n` +
      `rm -rf "$RUNNER_TEMP"`,
  );
  assert.match(r.stdout, /^1$/m);
});
