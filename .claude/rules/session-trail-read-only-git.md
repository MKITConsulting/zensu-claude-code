---
paths:
  - "skills/session-trail/scripts/trail.mjs"
  - "tests/structure/test-session-trail-verdict.sh"
---

# Session-Trail Read-Only Git (`git()` and `READ_ONLY_GIT` in `skills/session-trail/scripts/trail.mjs`)

**Every git call in `trail.mjs` goes through `git()`, and `git()` prepends `READ_ONLY_GIT`.**
`gitState` and `gitDiffText` run in the SOURCE session's worktree on every `takeover`, `show`
and `handoff`, and that session may still be live. The prefix is `--no-optional-locks`,
`-c core.fsmonitor=false` and `-c diff.autoRefreshIndex=false`. It also applies to calls in the
caller's own tree, because every call in the file is a read. A git call that bypasses `git()`
loses all three, so add new calls through the helper.

**`git()` also runs every call in `gitEnvironment(process.env)` from
`hooks/lib/worktree-keep-v1.js`**, which deletes `GIT_DIR`, `GIT_COMMON_DIR`, `GIT_WORK_TREE`
and the other discovery and config variables of its `GIT_ENV_SCRUB` and sets
`GIT_TERMINAL_PROMPT=0`. Measured against git 2.51.0: with `GIT_DIR` exported,
`rev-parse --git-common-dir` answers that repository from any folder, one in no repository
included, so every repository verdict of `takeover` would read the same repository. The list has
one owner, and `gitChildEnvironment` fails with the plugin-tree-incomplete diagnostic when that
module cannot be loaded, so every sandbox that stages `trail.mjs` (`mutant_path` and
`cont_mutant` in `test-session-trail-verdict.sh`) copies it beside `claude-path-v1.js`. `CH13`
there pins it: `CH7`'s takeover run from another repository with `GIT_DIR` and with
`GIT_COMMON_DIR` exported gives the verdicts of the run without them.

**MEASURED against git 2.51.0**, with a stat-dirty tracked file, the index mtime set to a fixed
past time and a `core.fsmonitor` hook that logs each run:

- A plain `status --porcelain` rewrites the index and runs the hook. `--no-optional-locks`
  alone stops the rewrite but not the hook, and `-c core.fsmonitor=false` alone stops the hook
  but not the rewrite.
- `diff`, `diff --cached` and `ls-files --others` run the hook on every index read.
- A porcelain `git diff` rewrites the index through its own refresh EVEN UNDER
  `--no-optional-locks`. Only `diff.autoRefreshIndex=false` stops it, and a stat-only change
  still prints nothing. The pair `release` used to spell at its own call sites therefore left
  `takeover` rewriting the index. Do not drop the third flag.
- `rev-parse`, `rev-list`, `log`, `symbolic-ref`, `worktree list` and a `base...HEAD` diff
  touch neither the index nor the hook.

**Pins.** `RO1` in `tests/structure/test-session-trail-verdict.sh` runs `takeover --json`,
`show` and `handoff` against such a fixture. It fails when the index mtime moved, when the hook
ran, and when the output does not list the edited file; the last condition stops a broken
helper from passing by running no git at all. `RO1-control` proves that a plain `git status` in
the same fixture rewrites the index and runs the hook. Both run git with `GIT_OPTIONAL_LOCKS`
unset, so an exported `0` cannot mask the defect. Removing any one of the three flags, or
restoring the old helper, turns `RO1` red.

`RO2` runs `takeover --json` against a repository whose one file has a textconv driver and
whose config sets a `diff.external` driver, both logging each run, with a committed, a staged
and an unstaged edit of that file. It fails when either driver ran, and when the uncommitted,
staged or branch diff lacks that edit's raw line. `RO2-control` proves that a plain `git diff`
in the same fixture runs the `diff.external` driver, and that `git diff --no-ext-diff` runs the
textconv driver. No single command can show both: measured, a plain `diff` hands every file to
`diff.external` and runs the textconv driver for none. Both unset `GIT_EXTERNAL_DIFF`, so an
exported driver cannot stand in for the fixture's. Measured, removing either diff flag turns
`RO2` red, with the raw line missing from all three diffs.

**Bounds, accepted and named:**

- Without its fsmonitor, a large source worktree is scanned in full and can hit the helper's
  8 s timeout. That collapses to an empty result like every other git failure, as
  `skills/session-trail/references/archive.md` states.
- `gitDiffText` passes `--no-ext-diff --no-textconv` to its three diffs. Measured with both
  flags, git runs no textconv driver, no `diff.external` driver, no `diff.<driver>.command` and
  no exported `GIT_EXTERNAL_DIFF`, and either flag alone leaves the other kind running. The
  cost, also measured: a file with a textconv driver shows its raw content in the brief and in
  `--json`, and binary content shows only as `Binary files … differ`. Text content then reads
  as it does in the carry-over patch, which passes the same two flags. `gitState`'s
  `diff --stat` runs neither driver, so it takes no flag.
- A clean filter still runs, and no diff flag can stop it. Measured under all five flags,
  `diff` runs a `filter.<driver>.clean` for a changed or stat-dirty file and starts a
  `filter.<driver>.process` filter for a changed one. Under the helper's three flags, `status`
  runs the clean filter when the stat data cannot settle the comparison: a same-size edit or a
  stat-dirty file. `references/disclosure.md` names that hazard in general terms.
- `release` now relies on the helper instead of its own two flags, so the sentence in
  `references/commands.md` that its `git status` runs with `--no-optional-locks` stays true.
- Native Windows is unmeasured. The verdict suite runs there only in the weekly Windows Safety
  run.

**Version: `patch`.** No schema field, strict key set, hook, matcher, config key or attestation
moves, and `session-lineage-v1.mjs` is untouched.
