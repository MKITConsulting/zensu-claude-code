---
name: reset-review-limit
description: >
  [Zensu] Atomically reset the current task's integrated auto-fix and Stop
  budgets after "max rounds reached". Uses one validated Session Control CAS
  mutation to zero both counters and re-arm every review terminus/latch.
  Performs no file search, deletion, cross-worktree discovery, network call, or
  API operation. Use only for the active task whose review budget was exhausted.
---

# /zensu:reset-review-limit

Grant another review/fix budget to the **current active task** after
`post-review-tdd-delegate.sh` emitted `Auto-fix convergence: max N rounds
reached`.

`reviewRound` and the Stop-hook anti-deadlock counter `stopBlocks` are bounded
integer fields in the same validated, revisioned
`.zensu/state/tdd-phase-<scv1-session-key>.json` document as the TDD FSM. There
is no separate counter or stop-block file. The complete reset must use the
single `tdd_reset_review_budget` CAS helper; never split it into counter and
flag mutations, and never edit, replace, delete, or rediscover the JSON document
directly.

## When to Use

- The current task exhausted `autoFixMaxRounds`, and the user explicitly wants
  the reviewer/fix loop to continue instead of proceeding to terminal
  self-review or stopping.
- A deterministic, additional budget is needed during diagnosis of the current
  active review chain.

## Do NOT Use For

- Bypassing findings. Fix routed findings before requesting another review.
- Resetting a different session, worktree, or task.
- Permanently changing the cap; configure `hooks.autoFixMaxRounds` instead.
- Disabling auto-fix; configure `hooks.autoFix:false` instead.
- Recovering malformed workflow state. Invalid state fails closed and requires
  a fresh Claude Code session; this skill never repairs JSON.

## Strict Scope

Operate only on the exact `ZENSU_SESSION_KEY`, `ZENSU_PROJECT_ROOT`, and
`ZENSU_CLAUDE_PLUGIN_ROOT` exported by Session Control for this session.

- Never run `find`, `git worktree list`, or a filesystem scan.
- Never inspect sibling or parent worktrees.
- Never use `CLAUDE_PLUGIN_DATA_OVERRIDE`, transcript discovery, PPID, newest
  file selection, filename iteration, or a fallback identity.
- Never invoke `rm`, `mv`, `cp`, redirection, or a JSON editor against workflow
  state.

## Phase 1: Validate the exact active workflow document

Run this preflight as one Bash call. It derives one state path from the bound
key and rejects missing, symlinked, malformed, foreign, or inactive state
through the canonical readers.

```bash
PLUGIN_ROOT="${ZENSU_CLAUDE_PLUGIN_ROOT:?FATAL: plugin root unavailable; start a fresh Claude Code session}"
PROJECT_ROOT="${ZENSU_PROJECT_ROOT:?FATAL: project root unavailable; start a fresh Claude Code session}"
SESSION_KEY="${ZENSU_SESSION_KEY:?FATAL: Session Control key unavailable; start a fresh Claude Code session}"
SESSION_HASH="${SESSION_KEY#scv1_}"
case "$SESSION_HASH" in *[!a-f0-9]*|'') echo 'FATAL: invalid Session Control key' >&2; exit 1 ;; esac
[ "$SESSION_KEY" = "scv1_$SESSION_HASH" ] && [ "${#SESSION_HASH}" -eq 64 ] \
  || { echo 'FATAL: invalid Session Control key length' >&2; exit 1; }
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
. "$PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
STATE_FILE="$(tdd_state_file "$SESSION_KEY")" || exit 1
[ "$(tdd_state_status "$STATE_FILE")" = valid ] || { echo "FATAL: workflow state is missing or invalid: $STATE_FILE" >&2; exit 1; }
[ "$(tdd_session_active "$STATE_FILE")" = true ] || { echo "FATAL: workflow is not active: $STATE_FILE" >&2; exit 1; }
BEFORE_REVISION="$(CONTROL_CORE="$PLUGIN_ROOT/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$PROJECT_ROOT" SID="$SESSION_KEY" node -e '
  const core = require(process.env.CONTROL_CORE);
  const state = core.readWorkflowState({projectRoot: process.env.PROJECT_ROOT, sessionId: process.env.SID});
  if (state.active !== true || state.implComplete !== true) process.exit(1);
  process.stdout.write(String(state.revision));
')" || exit 1
export BEFORE_REVISION
printf 'Reset target: %s (revision %s)\n' "$STATE_FILE" "$BEFORE_REVISION"
```

Do not continue if any preflight command fails.

## Phase 2: Reset and re-arm through CAS only

Run exactly one mutation, pinned to the revision validated in Phase 1:

```bash
RESET_RESULT="$(tdd_reset_review_budget "$SESSION_KEY" "$BEFORE_REVISION")" \
  || { echo 'FATAL: atomic review-budget reset failed' >&2; exit 1; }
```

That one validated CAS transaction sets `reviewRound=0`, `stopBlocks=0`,
`chainDone=false`, `codeReviewDone=false`, and `selfReviewFixed=false` while
preserving `active=true` and `implComplete=true`. A stale revision, invalid
document, inactive workflow, or incomplete implementation fails before commit,
leaving the state bytes and revision unchanged. Never fall back to individual
flag or counter helpers.

## Phase 3: Verify the revisioned result

Use the trusted Core reader, not raw file parsing, and require exactly one
successful revision advance:

```bash
AFTER="$(CONTROL_CORE="$PLUGIN_ROOT/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$PROJECT_ROOT" SID="$SESSION_KEY" node -e '
  const core = require(process.env.CONTROL_CORE);
  const state = core.readWorkflowState({projectRoot: process.env.PROJECT_ROOT, sessionId: process.env.SID});
  const expected = Number(process.env.BEFORE_REVISION) + 1;
  if (state.revision !== expected || state.reviewRound !== 0 || state.stopBlocks !== 0
      || state.chainDone !== false || state.codeReviewDone !== false
      || state.selfReviewFixed !== false || state.active !== true
      || state.implComplete !== true) process.exit(1);
  process.stdout.write(JSON.stringify({
    revision: state.revision,
    reviewRound: state.reviewRound,
    stopBlocks: state.stopBlocks,
    chainDone: state.chainDone,
    codeReviewDone: state.codeReviewDone,
    selfReviewFixed: state.selfReviewFixed
  }));
')" || { echo 'FATAL: transactional reset verification failed' >&2; exit 1; }
printf 'Reset complete: %s\n' "$AFTER"
```

After verification, re-run the normal review fan-out and the single
`zensu:code-reviewer` consume-mode spawn. Its completion advances
`reviewRound` from 0 to 1 atomically.

## Response Style

- Report the exact derived `STATE_FILE` and before/after revision.
- State the verified values of `reviewRound`, `stopBlocks`, `chainDone`,
  `codeReviewDone`, and `selfReviewFixed`.
- Explicitly say that no files were searched for or deleted.
- Never claim success when any CAS mutation or the final trusted read failed.
