---
paths:
  - "scripts/claude-promptfoo-wrapper.sh"
  - "scripts/fixture-mutation-watch.js"
  - "scripts/fixture-manifest.js"
  - "tests/structure/fixture-mutation-watch.test.js"
  - "tests/structure/test-claude-promptfoo-wrapper.sh"
  - "tests/structure/test-eval-harness-units.sh"
---

# Fixture Mutation Events (`scripts/fixture-mutation-watch.js`)

_Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

The promptfoo wrapper attests `tracked_clean` for the immutable eval fixture from TWO
independent signals: a manifest comparison (`scripts/fixture-manifest.js`, also polled every
10 ms) and a filesystem-event marker. **The marker is not redundant** — it is the only thing
that catches a TRANSIENT mutation, written and restored byte-for-byte before the run ends,
which is what `test-claude-promptfoo-wrapper.sh` P13-S6 pins.

**Both watch backends share ONE decision, `classifyFixtureEvent`, so they cannot diverge.**
Both gate `.git` behind a manifest delta: a recursive backend
(`fs.watch(root, {recursive:true})`, FSEvents on macOS) that marks any `.git` path outright
attests dirty under load against the wrapper's own `git init` + `git add` + `git commit`
seeding, which runs BEFORE the watcher starts (P13-S8 measured rc=3 on 8 of 8 concurrent runs
and 0 of 8 idle). Three further event shapes were measured the same way and are gated for the
same reason: the watched ROOT's own basename (what libuv
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
still see is what makes gating `.git` safe), and the unit file's entry in
`tests/profiles/unit-files.v1.json`, which its shell driver grades every run against. `tests/structure/fixture-mutation-watch.test.js` carries the four measured shapes and
pins the single-implementation property at SOURCE level — a rule pin alone cannot catch a
SECOND copy of the rule. That unit file runs in GitHub Actions
through `tests/structure/test-eval-harness-units.sh`, a `ciStructureTests` suite, and so on the
weekly Windows Safety run too. The wrapper's shell probes, P13-S6 and P13-S8 among them, do
not: `test-claude-promptfoo-wrapper.sh` is local-only (`tests/profiles/promptfoo-local-only.v1.json`,
and in the `excluded` list of `windows-native-structure.v1.json`).

**The macOS profile is the enforcing half, and three rules widen it on purpose.** The
attestation above detects a fixture write; the `sandbox-exec` profile the wrapper writes for an
`init_git` fixture prevents one. Measured on macOS 26.7.2 on 2026-11-24, `(deny default)` with
`(allow process*)` still refused every signal and the exec of the setuid `/bin/ps` (exit 126), so
the verify-feature fixture runtime could not prove its own server. The profile therefore adds
`(allow signal (target same-sandbox))` (own and orphaned sandboxed processes, never one
outside), `(allow signal (target children))` and `(allow process-exec (literal "/bin/ps") (with
no-sandbox))` for every `init_git` eval. Google Chrome cannot run inside the profile at all: the
socket directory of its single-instance lock lies in the per-user temp directory, with that
writable its startup dies on `mach-register`, and with that allowed its renderer crashes,
because its own sandbox cannot be applied inside another one. So `allow_unsandboxed_chrome: true`
in a provider config appends `(allow process-exec (literal "<Chrome main executable>") (with
no-sandbox))`, the main executable of `/Applications/Google Chrome.app` alone, which is narrower
than the app subpath and enough, since the helpers it starts inherit no sandbox. Only the three
verify-feature providers set the key, and the wrapper refuses it with exit 64 unless the same
provider config sets `require_disposable_environment: true`. The rules must follow
`(allow process*)`, and `(target children)` is what lets the sandboxed Playwright daemon kill
the browser it started: with `same-sandbox` alone its group kill failed with EPERM and the
browser kept running. So a child the sandbox starts outside itself, the browser and `ps`
included, stays signalable, while a process it did not start stays out of reach. **The cost:**
the browser process tree runs outside the boundary, and any process inside the sandbox can start
that executable outside it with arguments of its choosing, so for the browser the boundary falls
back to this file's detection. The eval grader fails a run whose Bash command text names a
browser, a word check it also applies with line continuations joined and quotes, backslashes and
backticks removed, and a name the shell assembles from a variable passes it. Linux `bwrap` is unmeasured for Chrome and ignores
the key. Moving together: the profile and the key's refusal in
`scripts/claude-promptfoo-wrapper.sh`; the profile-rule check of
`tests/structure/test-eval-harness-units.sh`, a `ciStructureTests` suite, which counts the
`with no-sandbox` lines, lists the files that set the key and requires the disposable setting
beside it; P13-S12 and P13-S12b in `test-claude-promptfoo-wrapper.sh`, which drive the real
profile with a stub `claude` and signal an orphaned sandboxed process and the unsandboxed
browser, one case per signal rule (macOS only), and P13-S12c there, which refuses the key without
the disposable setting in a dry run, so a regression stops at the preview and never starts a CLI
(all three local-only); and the macOS paragraph of
`evals/verify-feature/README.md`. A new `with no-sandbox` rule needs its own measurement and
moves that count.

**Known gap, measured and not closed.** Under the concurrent harness that measured P13-S8,
128 runs at a heavier setting produced ONE failure whose cause was not established; 224
instrumented runs at the same setting could not reproduce it. Say "the observed shapes are
closed", never "the watcher cannot false-positive".
