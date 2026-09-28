---
paths:
  - "scripts/fixture-mutation-watch.js"
  - "scripts/fixture-manifest.js"
  - "tests/structure/fixture-mutation-watch.test.js"
  - "tests/structure/test-claude-promptfoo-wrapper.sh"
---

# Fixture Mutation Events (`scripts/fixture-mutation-watch.js`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

The promptfoo wrapper attests `tracked_clean` for the immutable eval fixture from TWO
independent signals: a manifest comparison (`scripts/fixture-manifest.js`, also polled every
10 ms) and a filesystem-event marker. **The marker is not redundant** — it is the only thing
that catches a TRANSIENT mutation, written and restored byte-for-byte before the run ends,
which is what `test-claude-promptfoo-wrapper.sh` P13-S6 pins.

**Both watch backends now share ONE decision, `classifyFixtureEvent`.** They did not, and
the divergence was the bug: the per-directory backend gated `.git` behind a manifest delta
while the recursive one (`fs.watch(root, {recursive:true})`, FSEvents on macOS) marked any
path outright. Under load that made the wrapper attest dirty against its own `git init` +
`git add` + `git commit` seeding, which runs BEFORE the watcher starts — P13-S8 failed with
rc=3 on 8 of 8 concurrent runs and 0 of 8 idle. Three further event shapes were measured the
same way and are gated for the same reason: the watched ROOT's own basename (what libuv
reports for an event on the watched directory itself), a directory that CONTAINS a run-owned
subtree (`.zensu`, whose children the wrapper permits the run to write, coalesced upward),
and garbled names FSEvents emits under coalescing (`.git/ä`).

**The gated classes are adjudicated by the MANIFEST; ordinary fixture paths are NOT, and
that split is load-bearing.** A manifest gate on an ordinary path would destroy transient
detection outright — the manifest is equal by definition in exactly that case. Ordinary paths
are separated by the entry's own `ctimeMs`/`mtimeMs` against the watcher's start instead: a
denied write leaves the inode untouched, a restore does not, and an unreadable entry marks
(a deletion is a mutation). Do NOT "simplify" that branch onto `gateOnManifest` — it reads as
one consistent rule and silently removes the feature P13-S6 exists for. The ctime half of the
argument is POSIX only; on Windows that field is the creation time and settable, which is
acceptable solely because the `init_git` path requires `sandbox-exec`/`bwrap` and exits 69
without one.

Moving together: `RUN_OWNED` (the ancestor set is DERIVED from it, never hand-listed),
`EXCLUDED_PATHS` and `gitControlSnapshot` in `fixture-manifest.js` (what a manifest delta can
still see is what makes gating `.git` safe), and the registered-case floor in the shell
driver. `tests/structure/fixture-mutation-watch.test.js` carries the four measured shapes and
pins the single-implementation property at SOURCE level — a rule pin alone cannot catch a
SECOND copy of the rule, which is what the bug was. The suite is local-only
(`tests/profiles/promptfoo-local-only.v1.json`, and in the `excluded` list of
`windows-native-structure.v1.json`), so none of this runs in GitHub Actions.

**Known gap, measured and not closed.** Under the harness that failed 8 of 8 before the fix,
128 runs at a heavier setting produced ONE failure whose cause was not established; 224
instrumented runs at the same setting could not reproduce it. Say "the observed shapes are
closed", never "the watcher cannot false-positive".
