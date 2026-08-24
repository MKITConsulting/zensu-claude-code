'use strict';

// WHAT THIS PINS. `fixture-mutation-watch.js` decides, per filesystem event,
// whether that event is evidence that the immutable promptfoo fixture was
// mutated. It has TWO watch backends — a recursive one (`fs.watch(root,
// {recursive:true})`, which macOS serves with FSEvents) and a per-directory
// fallback — and they used to disagree about `.git`.
//
// THE DEFECT THIS FILE EXISTS FOR. On a loaded macOS host the recursive backend
// delivers events that are not evidence of anything the run did: writes the
// WRAPPER ITSELF completed before the watch existed, events coalesced upward
// onto a parent directory, events naming the watched root rather than an entry
// in it, and events for writes the sandbox denied. Each one marked the fixture
// dirty, so the wrapper attested `tracked_clean:false` against its own setup and
// `test-claude-promptfoo-wrapper.sh` P13-S8 failed with rc=3 — only under load,
// which is why it read as an unexplained flake. Measured here: 8 of 8 concurrent
// runs failed under 24 busy loops, 0 of 8 idle.
//
// FOUR SHAPES WERE OBSERVED, and they are not one bug:
//   `.git/index.lock`, `.git/COMMIT_EDITMSG`, `.git/objects/**`, and garbled
//     names (`.git/t7aB5ka`, `.git/ä`) — backlog from `git init`/`add`/`commit`,
//     which the wrapper runs BEFORE starting the watcher. 17 such events were
//     logged arriving after the watch was established.
//   `claude-eval-XXXXXX` — the watched root's own basename, which is what libuv
//     reports for an event on the watched directory itself.
//   `.zensu` — the parent of `.zensu/logs` and `.zensu/state`, both of which the
//     wrapper PERMITS the run to write. Every allowed write can coalesce upward.
//   `marker.txt` — a real fixture file whose content was provably unchanged;
//     a denied write or a stale event, not a mutation.
//
// TWO DIFFERENT DISCRIMINATORS, deliberately. The first three name something
// that is not a fixture entry the run could have mutated without moving the
// manifest, so the manifest adjudicates them — which is what the per-directory
// backend already did for `.git`, and the recursive one did not. `.git`
// internals are excluded from the manifest by design (`fixture-manifest.js`
// EXCLUDED_PATHS) and git STATE is covered semantically instead: HEAD,
// packed-refs, the checked-out ref, and `git ls-files -v --stage -z`.
//
// The fourth CANNOT use the manifest. A transient mutation — written and
// restored byte-for-byte before the run ends — leaves the manifest equal, and
// catching it is the entire reason the event marker exists beside the manifest
// comparison (P13-S6). Ordinary fixture paths are therefore separated by the
// entry's own ctime/mtime against the watcher's start: a denied write leaves the
// inode untouched, a restore does not. ctime is what makes that sound — `utimes`
// backdates mtime without privileges, ctime needs root. That argument is POSIX:
// on Windows the same field is the creation time and can be set, so the gate
// there rests on mtime alone. Accepted because the wrapper's `init_git` path
// requires `sandbox-exec` or `bwrap` and exits 69 without one, so it never runs
// on Windows, and this suite is in the `excluded` list of
// `tests/profiles/windows-native-structure.v1.json`. Say "POSIX", not "sound
// everywhere", if this ever moves.
//
// RESIDUAL, measured and not closed. Under the harness that failed 8 of 8 before
// the fix, 128 runs at a heavier setting (40 busy loops, 16 concurrent) produced
// ONE failure whose cause was not established: a further 224 instrumented runs at
// the same setting could not reproduce it. Treat this as "the observed shapes are
// closed", never as "the watcher cannot false-positive".
//
// WHY THIS LEVEL. A behavioral test of the recursive backend is not available:
// measured on macOS, the same backlog that causes the defect also swallows a
// `.git` write performed while the watcher is live, so an end-to-end probe
// observes neither the bug nor the fix reliably. The decision function and the
// single-implementation property are both deterministic, so they are pinned
// here; the fallback backend's end-to-end behavior stays pinned by P13-S7/S10/S11,
// and P13-S6 is what proves the timestamp gate did not cost transient detection.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');

const WATCHER = path.join(__dirname, '..', '..', 'scripts', 'fixture-mutation-watch.js');
const { RUN_OWNED, classifyFixtureEvent, runOwned } = require(WATCHER);
const SOURCE = fs.readFileSync(WATCHER, 'utf8');

test('requiring the watcher does not start it', () => {
  assert.equal(typeof classifyFixtureEvent, 'function');
  assert.equal(typeof runOwned, 'function');
  assert.ok(Array.isArray(RUN_OWNED));
});

test('.git itself is gated behind the manifest, never marked outright', () => {
  assert.equal(classifyFixtureEvent('.git'), 'git-gated');
});

test('every observed git-churn shape is gated', () => {
  for (const observed of [
    '.git/index.lock',
    '.git/COMMIT_EDITMSG',
    '.git/config',
    '.git/config.lock',
    '.git/refs',
    '.git/refs/heads/main',
    '.git/hooks/push-to-checkout.sample',
    '.git/objects/ab/cdef0123456789',
    '.git/objects/05/tmp_obj_Ssxuoj',
  ]) {
    assert.equal(classifyFixtureEvent(observed), 'git-gated', observed);
  }
});

test('a garbled recursive-backend filename under .git is still gated', () => {
  // Both spellings were emitted by libuv/FSEvents in the measured backlog.
  assert.equal(classifyFixtureEvent('.git/t7aB5ka'), 'git-gated');
  assert.equal(classifyFixtureEvent('.git/ä'), 'git-gated');
});

test('the .git prefix is anchored on the separator', () => {
  // `.gitignore` and `.github/` are ordinary tracked fixture content. A
  // startsWith('.git') without the separator would silently stop protecting them.
  assert.equal(classifyFixtureEvent('.gitignore'), 'mutation');
  assert.equal(classifyFixtureEvent('.gitattributes'), 'mutation');
  assert.equal(classifyFixtureEvent('.github/workflows/ci.yml'), 'mutation');
  assert.equal(classifyFixtureEvent('.gitmodules'), 'mutation');
});

test('a nested .git below the root is ordinary content, not gated', () => {
  // The gate is anchored at the fixture root. A submodule-shaped path deeper in
  // the tree is content the fixture is asserting about, so it must still mark.
  assert.equal(classifyFixtureEvent('vendor/dep/.git/config'), 'mutation');
});

test('every run-owned entry is ignored, as itself and as a parent', () => {
  for (const entry of RUN_OWNED) {
    assert.equal(classifyFixtureEvent(entry), 'ignore', entry);
    assert.equal(classifyFixtureEvent(`${entry}/nested/file.log`), 'ignore', entry);
  }
});

test('run-owned prefixes are anchored, so a sibling still marks', () => {
  assert.equal(classifyFixtureEvent('.verify-runtimex'), 'mutation');
  assert.equal(classifyFixtureEvent('.zensu/logsx/a'), 'mutation');
  assert.equal(classifyFixtureEvent('.zensu/hook-events.log.bak'), 'mutation');
});

test('ordinary fixture content marks', () => {
  assert.equal(classifyFixtureEvent('marker.txt'), 'mutation');
  assert.equal(classifyFixtureEvent('.zensu/autopilot.yaml'), 'mutation');
  assert.equal(classifyFixtureEvent('src/nested/deep/file.ts'), 'mutation');
});

test('runOwned and classifyFixtureEvent agree on the ignore set', () => {
  for (const probe of [
    '.zensu/logs',
    '.zensu/logs/run.log',
    '.zensu/autopilot.yaml',
    '.git/config',
    'marker.txt',
  ]) {
    assert.equal(runOwned(probe), classifyFixtureEvent(probe) === 'ignore', probe);
  }
});

// The three checks below are the actual regression guard. The bug was not a
// wrong rule — the per-directory backend had the right rule all along — it was
// a SECOND, weaker copy of the rule in the recursive backend. Pinning the rule
// alone would not catch its reintroduction, so the single-implementation
// property is asserted at source level.
test('both watch backends route their events through one decision', () => {
  const callbacks = SOURCE.match(/fs\.watch\(/g) || [];
  assert.equal(callbacks.length, 2, 'expected exactly two fs.watch call sites');
  assert.equal((SOURCE.match(/const handleEvent = /g) || []).length, 1);
  assert.equal((SOURCE.match(/handleEvent\(/g) || []).length, 2,
    'expected exactly one handleEvent call per backend');
});

test('the .git rule is spelled exactly once', () => {
  assert.equal((SOURCE.match(/'\.git\/'/g) || []).length, 1,
    'a second .git test means a backend is deciding on its own again');
  assert.equal((SOURCE.match(/=== '\.git'/g) || []).length, 1);
});

test('the gated classes are adjudicated by the manifest, not by the path', () => {
  const body = SOURCE.slice(SOURCE.indexOf('const handleEvent'), SOURCE.indexOf('const watchDirectory'));
  for (const gated of ['root-self', 'git-gated', 'ancestor-gated']) {
    assert.match(body, new RegExp(`case '${gated}':`), gated);
  }
  const gate = SOURCE.slice(SOURCE.indexOf('const gateOnManifest'), SOURCE.indexOf('const markIfTouchedSinceStart'));
  assert.match(gate, /digest\(root\) !== baseline/);
  assert.match(gate, /mark\('manifest-unreadable'\)/);
  assert.equal((SOURCE.match(/const gateOnManifest = /g) || []).length, 1);
});

test('an ordinary fixture path is marked only when the entry was touched after start', () => {
  // The manifest cannot adjudicate this class: a TRANSIENT mutation — written
  // and restored byte-for-byte before the run ends — leaves the manifest equal
  // and is exactly what the marker exists to catch (P13-S6). The discriminator
  // is therefore the entry's own timestamps against the watcher's start.
  const body = SOURCE.slice(SOURCE.indexOf('const markIfTouchedSinceStart'), SOURCE.indexOf('const handleEvent'));
  assert.match(body, /info\.ctimeMs < startedAt && info\.mtimeMs < startedAt/);
  assert.match(body, /catch \(_error\) \{ mark\(relativePath\); return true; \}/,
    'an unreadable entry must fail closed, because a deletion is a mutation');
  assert.match(SOURCE, /const startedAt = Date\.now\(\);/);
  // ctime is load-bearing and mtime alone is not: `utimes` can backdate mtime
  // without privileges, ctime cannot. Both are read so the check only ever marks
  // more, never less.
  assert.ok(SOURCE.indexOf('const startedAt') < SOURCE.indexOf('const root = fs.realpathSync'),
    'start must be captured before anything this process does to the fixture');
});

test('every false positive measured under load is now a non-mutation class', () => {
  // The four shapes this fix was built from, each reproduced on macOS under
  // concurrent load with the fixture content provably unchanged.
  const root = 'claude-eval-Ow10PR';
  assert.equal(classifyFixtureEvent('.git/index.lock', root), 'git-gated');
  assert.equal(classifyFixtureEvent(root, root), 'root-named');
  assert.equal(classifyFixtureEvent('.zensu', root), 'ancestor-gated');
  // The fourth, `marker.txt`, stays a `mutation` by classification and is
  // separated at the timestamp gate instead — see the test above. Classifying it
  // as gated would have traded the flake for a hole in transient detection.
  assert.equal(classifyFixtureEvent('marker.txt', root), 'mutation');
});

test('an event naming the watch root itself is not a path inside it', () => {
  assert.equal(classifyFixtureEvent(''), 'root-self');
  assert.equal(classifyFixtureEvent('.'), 'root-self');
  assert.equal(classifyFixtureEvent('claude-eval-X', 'claude-eval-X'), 'root-named');
});

test('the root name only gates when it is supplied', () => {
  // The per-directory backend composes its own relative path and can legitimately
  // report a child whose name equals the root's; without a root name the old
  // meaning must survive unchanged.
  assert.equal(classifyFixtureEvent('claude-eval-X'), 'mutation');
  assert.equal(classifyFixtureEvent('claude-eval-X', ''), 'mutation');
});

test('a directory that contains a run-owned subtree is gated, its content is not', () => {
  // `.zensu` is the parent of `.zensu/logs` and `.zensu/state`, which the wrapper
  // permits the run to write. Every allowed write can be coalesced upward into an
  // event naming `.zensu`, so that name alone is not evidence of a mutation.
  assert.equal(classifyFixtureEvent('.zensu'), 'ancestor-gated');
  assert.equal(classifyFixtureEvent('.zensu/logs'), 'ignore');
  assert.equal(classifyFixtureEvent('.zensu/logs/run.log'), 'ignore');
  assert.equal(classifyFixtureEvent('.zensu/autopilot.yaml'), 'mutation');
  assert.equal(classifyFixtureEvent('.zensux'), 'mutation');
});

test('the ancestor set is derived from RUN_OWNED, never hand-listed', () => {
  // Adding a run-owned entry under a new parent must gate that parent too.
  const ancestors = new Set();
  for (const entry of RUN_OWNED) {
    const parts = entry.split('/');
    for (let i = 1; i < parts.length; i += 1) ancestors.add(parts.slice(0, i).join('/'));
  }
  assert.ok(ancestors.size > 0);
  for (const ancestor of ancestors) {
    assert.equal(classifyFixtureEvent(ancestor), 'ancestor-gated', ancestor);
  }
});
