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

**Bounds, accepted and named:**

- Without its fsmonitor, a large source worktree is scanned in full and can hit the helper's
  8 s timeout. That collapses to an empty result like every other git failure, as
  `skills/session-trail/references/archive.md` states.
- Other configuration of that repository still runs, measured under all three flags: a textconv
  driver and a `diff.external` driver in `takeover`'s diff, and a clean filter on a changed or
  stat-dirty file in `status` and `diff`. `references/disclosure.md` names that hazard in
  general terms.
- `release` now relies on the helper instead of its own two flags, so the sentence in
  `references/commands.md` that its `git status` runs with `--no-optional-locks` stays true.
- Native Windows is unmeasured. The verdict suite runs there only in the weekly Windows Safety
  run.

**Version: `patch`.** No schema field, strict key set, hook, matcher, config key or attestation
moves, and `session-lineage-v1.mjs` is untouched.
