---
paths:
  - "skills/session-trail/scripts/autopilot-runs-v1.mjs"
  - "skills/session-trail/scripts/trail.mjs"
  - "skills/session-trail/references/**"
  - "skills/autopilot-adopt/SKILL.md"
  - "tests/structure/autopilot-runs-v1.test.js"
  - "tests/structure/test-session-trail-verdict.sh"
---

# Session-Trail Autopilot Runs (`autopilot-runs-v1.mjs` + `autopilotRunsOf` in `trail.mjs`)

**A takeover names the old session's durable Autopilot runs, because nothing else carries them.**
On 2026-11-10 a session drove run `run_ad0149b5fdc8d879` to `TEAM_REVIEW`, hit a rate limit, was
taken over through `/zensu:session-trail` with the move route and was released. The run stopped
without a word: session-trail never read `autopilot-run-*.json`, `--autopilot-adopt` served only a
successor in the same project root, and no writer rewrote `projectRoot` or `workspaceRoot`. The
adopt half of the fix, the relocation, is in `.claude/rules/autopilot-run-scope.md`. This file is
the session-trail half.

**The reader.** `readAutopilotRuns(folders, ownerKey)` reads `<folder>/.zensu/state` for each of
`new Set([r.cwd, r.wt])`, the session's recorded directory and its worktree, because a run record
lives in the state directory of the project root that minted it. A `.zensu` or `state` that is a
symbolic link or no directory holds no run, exactly as the state library refuses such storage. The
listing takes `RUN_FILES_MAX` (64) names per directory and counts the rest. Each record must be a
regular, single-link file of at most `RUN_RECORD_MAX_BYTES` (1 MiB), read through a no-follow,
non-blocking descriptor whose `fstat` must match the `lstat`; it must parse, name the run of its file
name and name an owner. Every other record is listed as **unreadable** with its reason, never
skipped in silence. `ownerKey` is a function, so the Session Control core loads only when a run
record exists: `sessionControlKey` requires `hooks/lib/session-control-core-v1.js` and answers
`core.sessionKey(r.sessionId)`, the `scv1_` key the state library stores as `ownerSessionId`. A key
that cannot be computed makes the whole state `measured: false`, rendered as not attributed. A run
of another owner is counted in `others` and a `DONE` or `CANCELLED` run in `terminal`; neither is
named on any carrier.

**Classification.** A run is `nested-workspace` when its `workspaceRoot` differs from its
`projectRoot`, the origin-checkout layout, and `own-tree` otherwise. `innerChain` is a pending stage
of `TDD_RUNNING`, read from `blocked.from` for a `BLOCKED` run, because the adopt verb refuses that
run with exit 3. `folder`, the directory that holds the record's state directory, names the tree
and the session root in every route text, since the recorded root may already be gone. Stage, next
action, blocked code, pull-request number and URL are rendered only when they match a strict shape,
so no record value carries a control character, a backtick or whitespace into a line.

**Four carriers.** Both briefs render `## Autopilot run` after their linked-session reports, the
takeover before `## Recent instructions` and the handoff before `## Open threads`, and render
nothing when the tree holds no run of the session. `show` prints one `AUTOPILOT` line under the
same rule. `show --json` and `takeover --json` carry the whole state as `autopilotRuns`. `release`
pushes `autopilot-run` for every owned nonterminal run, `autopilot-unreadable` for an unreadable
record or a cut listing, and `autopilot-unattributed` for an unattributed tree, so a dry run lists
them and `--apply` exits 1. A transferred run left the tree or changed its owner, so it no longer
blocks.

**Slash commands only.** Every carrier names `/zensu:autopilot-adopt` and `/zensu:autopilot-release`
and never `--confirm` or `zensu-log.sh`, the rule `.claude/rules/autopilot-run-scope.md` states for
every model-read channel: a complete invocation would route around the one confirmation the guided
skills ask for. The unit file asserts it over every renderer and state.

**The hand copies are pinned.** `TERMINAL_STAGES`, `RUN_RECORD_MAX_BYTES`, `RUN_ENVELOPE` and
`RUN_ID_SHAPE` copy the state library's `TERMINAL`, `MAX_BYTES`, run-file envelope and `identifier`;
`STAGE_SHAPE` and `ACTION_SHAPE` must accept every member of its `STAGES` and `NEXT_ACTION`. The
case `the run vocabulary matches the state library it mirrors` reads all of them from
`hooks/lib/zensu-autopilot-state.sh`, so a one-sided change fails there.

**Coupled sites.** The four sandboxes that stage `trail.mjs` copy the module beside it:
`mutant_path`, `cont_mutant` and the `OM` sandbox in `tests/structure/test-session-trail-verdict.sh`,
and the `TDZ` tree in `tests/structure/test-session-trail-lineage.sh`. The import line and the
`show` lines moved the two line citations of `docs/multi-repo-chains-spec.md` and
`docs/multi-repo-chains-overview.html`, which `T36` grades. PR #606 vendors `trail.mjs` into the
Session Hub companion and pins both copies, so whichever change lands second also vendors this
module. The skill texts: the *Autopilot run* paragraph and the step 1 sentence of
`references/takeover.md`, flows 4 and 5 of `references/handoff.md`, the `show`, `handoff`,
`takeover` and `release` rows of `references/commands.md`, the `show --json` and `release`
paragraphs of `references/disclosure.md`, the data-source row of `SKILL.md`, and the moved-tree
procedure of `skills/autopilot-adopt/SKILL.md`. Pins: the `AP` family in
`tests/structure/test-session-trail-verdict.sh`, on a real repository with worktrees, and
`tests/structure/autopilot-runs-v1.test.js`, whose `registered` count and win32 skip ceiling in
`tests/profiles/unit-files.v1.json` are exact.

**Known gaps, accepted and named:**

- The folders come from the transcript. A session re-anchored to a sibling worktree, or one whose
  tree moved before the takeover ran, keeps its run where this reader does not look, and the
  carriers then say nothing. A tree that is gone holds no readable run either.
- The record lives in a session-writable directory, so a planted record can make a carrier name a
  run or make `release` refuse. The adopt verb re-validates everything before it moves anything.
- The section tells the reader which route carries a run; nothing verifies that the route was
  taken. `release` is the backstop for a run that stayed behind in the old worktree only.
- Windows is unmeasured: the verdict suite runs there only in the weekly Windows Safety shard,
  and the unit file's link case skips where a symbolic link cannot be made.

**Version: `patch`.** Walked against `.claude/rules/runtime-lineage.md`: no context-record or
workflow-state field and no strict key set moves. The relocation rewrites two existing run-record
fields with values an older installation already accepts, a nested `workspaceRoot` included, and
writes no event. No hook is added, removed or re-matched, no `permissionDecision` and no attestation
changes, and no config key is added. The `--json` key and the `release` refusal are new outputs of
a skill CLI, and `skills/session-trail/scripts/session-lineage-v1.mjs` is untouched.
