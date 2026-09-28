---
paths:
  - "hooks/lib/evidence-run-v1.js"
  - "hooks/lib/zensu-log.sh"
  - "tests/structure/evidence-run-v1.test.js"
  - "tests/structure/test-evidence-run.sh"
  - "tests/structure/test-full-suite-gate.sh"
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

**The tree fingerprint never touches the real index.** It copies the index, runs
`git add -A -- .` and then `git rm -r --cached .zensu` on the copy, and writes the tree.
Never exclude `.zensu` with a `:(exclude)` pathspec on `add`: once `.zensu/` is
gitignored, which is the normal case, `add` fails with "paths are ignored" and every
tree came out unverified. Git runs with the `_tc_git` scrub list and `LC_ALL=C`, because
its reason text reaches committed run-log lines. Over 20000 untracked files or 512 MiB,
or on a git failure, the record carries no tree and names the reason.

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
`tests/structure/test-bypass-ledger.sh`.

**Known gaps**: on Windows the group kill is a best-effort `taskkill /T /F` and stays
unverified until a Windows run measures it. `mutated-during-run` lists paths only when
both trees exist.
