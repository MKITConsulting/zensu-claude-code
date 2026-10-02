---
paths:
  - "hooks/lib/evidence-run-v1.js"
  - "hooks/lib/zensu-log.sh"
  - "tests/structure/evidence-run-v1.test.js"
  - "tests/structure/test-evidence-run.sh"
  - "tests/structure/test-full-suite-gate.sh"
  - "hooks/post-review-tdd-delegate.sh"
---

# Evidence Runner and Full-Suite Gate (`hooks/lib/evidence-run-v1.js` + `zensu-log.sh --evidence-run` / `--chain-done`)

The plugin runs the full suite itself, records the real exit code bound to the exact
working tree, and a reviewed chain cannot close on a missing, red or stale record. It
replaced the Bash witness, whose claims were hand-copied strings matched by equality
against a log that never carried an exit code.

**One owner.** `evidence-run-v1.js` owns the record schema (`RECORD_KEYS`, an exact key
set), the ids, the store layout, the tree fingerprint, the closed verdict-state list,
retention and every display string. `zensu-log.sh` only transports: native paths from
`zensu-host-path.sh`, values in `ZENSU_EVR_*` variables that `zensu_msys_env_exclusions`
keeps out of MSYS conversion, and the command and config values as files in a temporary
transport directory. Neither the command nor the plugin root ever travels in argv. A
second hand-copied schema site is the failure this avoids: the edit-landing receipt
schema drifted across four of them.

**The command runs from a script file** under `set -o pipefail` in
`bash --noprofile --norc`, in its own process group, with stdin on the null device. The
child environment drops `CHILD_SCRUBBED_ENV` and every `ZENSU_EVR_*` name, and gets the
caller's `CLAUDE_PROJECT_DIR` back from the snapshot `zensu-log.sh` takes BEFORE its bind
block, because the bind overwrites that variable. A new binding the verb exports must
join `CHILD_SCRUBBED_ENV`, or the suite under test sees it; `test-evidence-run.sh` E7
pins the current set.

**The command runs where the fingerprint looks.** `runDirectory` keeps the caller's working
directory when it lies in the git work tree of the bound project root, and otherwise runs the
command in the project root and says so on stderr. Work-tree identity decides first: a nested
worktree, an embedded clone or a submodule inside the root is another work tree, which a run from
its cwd never reaches; only a leading literal `cd` in the command does, and the fingerprint then
measures it beside the project (below). Path containment decides only for a root outside git. The tree
fingerprint and the verdict are bound to the project root, so a run from another worktree — the
Bash tool's start directory after `/zensu:adopt-session --reanchor` — would certify a tree it never
tested. The same-work-tree arm keeps a session recorded in a subdirectory able to run its suite
from the worktree top. `test-evidence-run.sh` E8, E8b and E8c pin the three directions, and the
unit case `a working directory outside the work tree of the project root runs the command in the
project root` pins both arms, the `<root>-x` prefix sibling and a caller outside git.

**The tree fingerprint never touches the real index.** It copies the index, runs
`git add -A -- .` and then `git rm -r --cached .zensu` on the copy, and writes the tree.
Never exclude `.zensu` with a `:(exclude)` pathspec on `add`: once `.zensu/` is
gitignored, which is the normal case, `add` fails with "paths are ignored" and every
tree came out unverified. Git runs with the `_tc_git` scrub list and `LC_ALL=C`, because
its reason text reaches committed run-log lines. Over 20000 untracked files or 512 MiB,
or on a git failure, the record carries no tree and names the reason.

**The copy keeps the real index's atime and mtime.** git trusts a stat match only when the
entry's mtime is older than the index file's own mtime (the racy-git check), so a copy with a
fresh mtime made git trust a stale stat: a same-size edit in the second of the last index write
fingerprinted the committed blob, and `test-acceptance-gate.sh` A9 caught it. The copied
timestamps have millisecond precision, which rounds toward earlier and only makes more entries
racy. The stat is taken BEFORE the copy: a concurrent git that replaces the index between the
two would otherwise give the old content the newer mtime, so fewer entries would count as racy.
The unit case `a same-size edit in the second of the last index write still changes the tree
id` pins it with `core.checkStat minimal`, so it reproduces on hosts whose git keeps sub-second
stat data, and it backdates the file and its index entry five seconds, so the copy always lands
in a later second than the recorded mtime whatever the host's timing.

**`full` and `scoped` runs carry a tree** (`TREE_SCOPES`); `lint`, `build` and `coverage`
stay untreed. `--if-stale` works for both: for `full` it reads the newest `full` record, for
`scoped` the newest run of the same command. A local chain's verdict still reads only `full`
records. A chain whose full suite runs in CI reads its `scoped` runs through `decideCi` and
may close as `deferred-ci`, a passing state that is never persisted. That mode, its policy and
its stores are described in `.claude/rules/full-suite-ci-deferral.md`.

**The fingerprint of a test run covers the project AND the nested work tree the suite ran
in.** For `full` and `scoped` runs (`TEST_SCOPES`) the run directory is the directory
`runDirectory` keeps, or the target of a leading literal `cd` in the command: `commandDirectory` reads one single-quoted,
expansion-free double-quoted or plain token followed by `&&`, `;` or a newline, optionally
inside a subshell, and keeps the cwd for anything it cannot read literally (`~`, `$VAR`, a
glob, `cd -`, an option). That is the shape of the benchmark run in
`docs/superpowers/specs/2026-09-28-review-cost-levers-design.md`: the runner started at the
project root with `--cmd 'cd <project>/.claude/worktrees/<name>/<dir> && …'`, so a fingerprint
that followed only the cwd never saw the worktree it tested. `fingerprintRoot` answers the work
tree that contains the run directory when `git rev-parse --show-toplevel` puts it strictly
inside the project root's own work tree, and the project root otherwise. It follows any
repository nested there, whether or not it shares the project's history, which is what the
multi-repo orchestrator layout of ignored code clones needs. Git's own "no work tree here"
answers (`not a git repository`, `cannot change to`, `must be run in a work tree`) keep the
project root; any other git failure answers `null`, and the fingerprint then carries no tree and
a reason, so the verdict reads `pass-tree-unverified` instead of silently measuring the project
root alone. For a nested work tree, `computeFingerprint` writes a combined tree with
`git mktree --missing` whose two entries, `project` and `work`, are the two trees, so an edit on
either side makes the record stale; `--missing` is what lets a nested repository with its own
object store be named from the project's. `fingerprintChanges` splits a combined tree back into
its halves to list changed paths, running the work-tree half in that repository's own object
store and prefixing it with its location relative to the project root, and lists nothing when
the two trees are not the same shape. The pass, stale and mutated verdicts name that location
(`of the project and <location>`). No record field carries the root or the directory: every
reader derives both from a record's `command` and `cwd`, and `cwd` is the directory `runDirectory`
kept, so a record written before it existed with a nested cwd still reads against the combined
fingerprint of the tree its command ran in. A local chain measures one root, the
newest `full` record's, so an older record from another directory never keeps the gate green;
`--if-stale` passes its own run's directory as `runCwd`, because the verdict CLI's transport
always fills `options.cwd` with the project root. `decideCi` compares every record with the
current tree of its own root, and reads `stale` when the root of the newest finished run has no
record on its current tree, so a current run at the project root cannot hide a stale one in the
worktree the chain works in. A record fingerprinted at the project root reads `stale` against a
combined fingerprint, never `pass`. An `acceptance` run keeps the project-root fingerprint,
because `acceptance-verify-v1.js` compares it with `computeTree(projectRoot)`. Known gaps: only
a leading `cd` moves the directory, so a suite reached any other way (`--manifest-path`,
`git -C`, `pushd`, an assignment or a command before the `cd`, a script that changes directory)
keeps the project-root fingerprint; and a work tree outside the project root's own work tree is
never followed, so a run from a clone elsewhere keeps the project-root fingerprint. On Windows
the `cd` target resolves only in a drive spelling (`C:/…`); an MSYS spelling such as `/c/…` or
`/tmp/…` needs the mount table, which the native runner never reads, so it keeps the
project-root fingerprint. F18 and F19 in `test-full-suite-gate.sh` therefore pass the worktree
through `zensu-host-path.sh`, and the unit tests compare directories through
`fs.realpathSync.native`, because git answers `C:/…` where `fs.realpathSync` answers `C:\…`.

**`not-applicable` is decided narrowly.** Only a root that git reports as outside any
repository or work tree, or a host without git, skips the gate. Every other git failure
is `unavailable` and blocks under `required`: a `safe.directory` refusal also exits 128,
and reading it as "not a repository" would open the gate on a real repository.

**The gate sits at `--chain-done` only**: the ticket-bound standalone terminus and a
bound chain with outcome `pass`. `--tdd-complete` is deliberately not gated, because
review rounds change the tree anyway and its preconditions are hand-rendered in two
recovery surfaces. Exempt: the unqualified zero-change terminus, silently
(`test-chain-terminus-zero-change-gate.sh` G1 requires an empty stderr), and outcome
`no-changes`. Outcome `max-rounds` is disclosed and never blocked, because
`post-review-tdd-delegate.sh` drives that call with its output discarded.

**The order is load-bearing**: the chainDone short-circuit, then a read-only ticket
pre-check through `tdd_claimed_review_ticket`, then the verdict, the escape record, the
transition, the pass line and the bypass line. The pre-check makes a wrong ticket fail
on the ticket check rather than on a suite message, and keeps an escape on a wrong
ticket out of the ledger (`test-full-suite-gate.sh` F9).

**`ZENSU_FULL_SUITE_GATE=off` is recorded only where the gate applies**, never outside
a work tree (F14). The bypass allowlist keeps `ZENSU_TEST_WITNESS` as a retired name,
because the ledger write path FILTERS existing entries through the allowlist: removing a
name silently erases it from every adopted chain's ledger.

**Scopes.** `full` and `acceptance` fingerprint the tree at both ends (`TREE_SCOPES`); only
`full` feeds the full-suite verdict, and an `acceptance` run is the observed evidence an
acceptance record cites (`.claude/rules/acceptance-verification-gate.md`). Retention keeps the
newest `maxRecordsPerSession` records PER SCOPE, so a chain's acceptance checks never evict its
newest full record.

**Config**: `evidence.fullSuiteCommand` is the runner's default for `--scope full`, and
an explicit `--cmd` that differs from it is refused. `evidence.fullSuiteGate` is
`required` (default) or `advisory`; any other value acts as `required` with a disclosure.
This repository commits `advisory`, because CI is its full-suite gate and
`tests/run-all.sh` is never run locally.

**The store** is `$CLAUDE_PLUGIN_DATA/evidence-run/v1/`, in both protected-root lists of
`hooks/lib/reviewer-capability-v1.js`; the plugin-data guard already denies Edit and
Write there. A Bash redirect from the main thread can still forge a record. That is the
documented residual of every plugin store, and no seal was added.

**Coupled sites**: `docs/configuration.md` §"Full-Suite Evidence", its
`ZENSU_FULL_SUITE_GATE` row and the visible-opt-outs roster; `docs/gates.md`
§"Full-suite gate"; the counts in `.claude/rules/gate-disable-prefixes.md`;
`ESCAPE_STEMS` in `tests/structure/test-gauntlet-loop-skill.sh`; the escape case in
`tests/structure/test-bypass-ledger.sh`. The close step moves together across
`FULL_SUITE_STEP`, `AFFECTED_SUITE_STEP`, `CLOSE_SUITE_STEP` and `CLOSE_SUITE_REASON` of
`hooks/post-review-tdd-delegate.sh` (both `CLOSE_PASS` arms, `CLOSE_PASS_SUITE_CI` and both
max-rounds hand-offs interpolate them), the routed-round sentence of step 10 in
`skills/tdd/SKILL.md`, discipline patch 12 in `docs/tdd-manager-workflow.md`,
the `FS-A` pins and F16 to F19 in `tests/structure/test-full-suite-gate.sh`, `S17` in
`tests/structure/test-post-review-tdd-scope.sh`, the `MR` checks in
`evals/config-gate/test-review-convergence-directive.sh`, C22 and C23 in
`tests/structure/test-full-suite-ci.sh`, and the `evidence-run-v1.test.js` count in
`tests/SUITE-OVERVIEW.md`.

**Known gaps**: on Windows the group kill is a best-effort `taskkill /T /F` and stays
unverified until a Windows run measures it. `mutated-during-run` lists paths only when
both trees exist.
