---
name: self-review
description: >
  [Zensu] Terminal self-reflection stage of the post-implementation review chain. After the
  zensu:code-reviewer chain converges (PASS, suggestions-only, or max-rounds), re-read this
  session's own work as a senior engineer, take at most ONE fix round (under the
  still-active TDD phase-gate) if a must-fix surfaces, then render the final
  Positive/Improvements/Risks report and close the chain via --chain-done. It never re-runs
  the code-reviewer. Invoked AUTOMATICALLY as the chain's terminal gate (the post-review
  hand-off and the Stop chain-enforcer force it) — normally not run by hand, and never a
  substitute for the zensu:code-reviewer agent.
---

# /zensu:self-review

Terminal self-reflection stage of the post-implementation review chain. After the
`zensu:code-reviewer` chain converges (PASS, suggestions-only, or max-rounds), you
re-read this session's work as an experienced senior engineer reviewing your own
code, take at most ONE fix round if a must-fix surfaces, then render the final
report and close the chain. This is the LAST instance — it never re-runs the
code-reviewer.

You have full access to the conversation history and know exactly which files you
edited, created, or deleted in this session. Use that knowledge directly.

## When to Use

- Invoked automatically as the terminal review-chain stage: the
  `post-review-tdd-delegate.sh` hook hands off here once the code-reviewer chain
  converges, and the `stop-chain-enforcer.sh` Stop hook forces this skill while
  `codeReviewDone` is set but `chainDone` is not.
- You should normally NOT run this by hand — it is the chain's final gate.

## Do NOT Use For

- A substitute for the `zensu:code-reviewer` agent — that runs first; this is the
  terminal pass over your own work.
- Bypassing findings: a must-fix you surface here still goes through strict TDD.
- More than one fix round: the budget is exactly one (a hard latch), then finalize.

## What This Skill Does

1. Lists the files you changed this session (conversation context + `git diff --name-only HEAD`).
2. Re-reviews each change across seven dimensions against the project conventions.
3. Emits a Positive / Improvements / Risks reflection.
4. Takes at most ONE fix round under the still-active TDD phase-gate if a must-fix
   risk surfaces — without re-running the code-reviewer.
5. Owns the chain terminus: runs the standalone or exact Autopilot-bound
   `--chain-done` form for the current generation and renders the final report.

## Generation guard

The automatic handoff MUST include exactly one line
`SELF-REVIEW-TICKET: <review-ticket>`. Capture that exact ticket before doing
anything else. It is the generation token for every state mutation in this
skill. If the line is missing, malformed, or ambiguous, do not run
`--self-review-fixed` or `--chain-done`; report that the self-review handoff is
unbound and let the Stop hook reconstruct the current handoff.

An Autopilot-bound handoff MUST additionally include exactly one complete
official three-line envelope, with each line occurring exactly once:

`ZENSU-DELEGATED-CALLER: autopilot`
`AUTOPILOT-BINDING: run=<runId> attempt=<attempt> chain=<chainId>`
`AUTOPILOT-STAGE: <returnStage>`

The appearance of any one of the three header prefixes activates delegated
validation. A partial, duplicate, malformed, or conflicting envelope is a stale
handoff: do not read/change project files and do not run `--self-review-fixed`
or `--chain-done`. Capture `RUN_ID`, `ATTEMPT`, `CHAIN_ID`, and `RETURN_STAGE`
only from the accepted envelope, never from conversation memory.

Before reading or changing files, resolve the current session through
`zensu-session.sh`, run
`bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --autopilot-status`, and
cross-check the durable result. It must name the captured `runId`, have
`ownerSessionId` equal to the resolved session, be the current nonterminal
`stage=TDD_RUNNING` run, and match `tdd.sessionId`, `tdd.attempt`,
`tdd.chainId`, and `tdd.returnStage` to the resolved session plus the four
envelope values exactly. The `AUTOPILOT-STAGE: <returnStage>` line therefore
proves the same value as `tdd.returnStage`; it is not a navigation hint. A
missing, foreign, terminal, or mismatched status is stale and stops without
mutation. Conversely, if current status proves an owned `TDD_RUNNING` binding
but the envelope is absent, fail closed rather than using an unqualified
terminus. Standalone handoffs omit the entire Autopilot envelope and must have
no owned `TDD_RUNNING` durable status; their existing unqualified behavior is
otherwise unchanged.

Every command below that shows `<review-ticket>` means the captured ticket.
Every bound command uses the same captured run/attempt/chain. A non-zero exit
means this self-review belongs to a stale generation: stop without changing or
finalizing the current chain.

## Phase 1: List Changed Files

List every file you changed or created in this session. You know these from your
own context — no parsing needed. Cross-check with `git diff --name-only HEAD` to
catch anything you missed.

If there are NO changes this session, close only the verified generation. For a
standalone handoff run
`bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --chain-done --claimed-review-ticket "<review-ticket>"`.
For an Autopilot-bound handoff run
`bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --chain-done --autopilot-run "$RUN_ID" --autopilot-attempt "$ATTEMPT" --chain-id "$CHAIN_ID" --claimed-review-ticket "<review-ticket>" --outcome no-changes`.
State "No changes — self-review skipped" only after the command succeeds, then
stop. `${CLAUDE_PLUGIN_ROOT}` is the session-scoped plugin root supplied by
Claude Code.

## Phase 2: Analyze

Read the current content of each changed file with the Read tool. Read the project
root `CLAUDE.md` so you apply the governing conventions. Score each change on:

- **Architecture**: does the approach fit the existing structure? Are better patterns available?
- **Consistency**: does the code follow the patterns used elsewhere in the codebase?
- **Edge-cases**: missing boundary conditions, error handling, or validation?
- **Test coverage**: are the tests sufficient? Are scenarios missing?
- **Security**: potential vulnerabilities (injection, missing auth checks, secret leakage)?
- **Simplification**: unnecessary complexity that could be reduced?
- **Conventions**: are the CLAUDE.md rules honored (language, comments, watermarks)?

## Phase 3: Report

Structure the reflection as:

- **Positive**: what was solved well.
- **Improvements**: concrete suggestions with `file:line` references.
- **Risks**: potential problems that were overlooked.

Be honest and direct. If everything looks good, say so briefly. Do not invent
problems where none exist.

Classify each finding: a **must-fix** is a Risk that would ship a defect — a real
bug, a security hole, or a broken convention the gate would reject. Everything else
is advisory and is buffered into the final report, not fixed here.

## Phase 4: Fix Round or Finalize

Read the one-fix-round latch: `selfReviewFixed` in the session chain-state.

- **If `selfReviewFixed` is false AND there is at least one must-fix finding** — take
  EXACTLY ONE fix round, in this main thread, under the still-active PreToolUse
  phase-gate. For each must-fix: RED test, then IMPL, then GREEN (re-enter the
  `/zensu:tdd` Phase 4 discipline). In a vanilla-mode session — verify with
  `bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --mode` (echoes `vanilla`) — apply each
  must-fix directly instead: no RED→GREEN cycle required, the gate passes through.
  Then set the latch with
  `bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --self-review-fixed --claimed-review-ticket "<review-ticket>"` and re-run
  `/zensu:self-review` (pass 2 to confirm). The pass-2 invocation MUST carry the
  same captured `SELF-REVIEW-TICKET: <review-ticket>` line again and, for a
  bound handoff, the same captured official envelope exactly once:
  `ZENSU-DELEGATED-CALLER: autopilot`,
  `AUTOPILOT-BINDING: run=<runId> attempt=<attempt> chain=<chainId>`, and
  `AUTOPILOT-STAGE: <returnStage>`. Do not re-read, re-derive, or omit either generation token or any envelope line. In this branch you MUST NOT:
  - run `--tdd-complete` (implementation is already complete);
  - spawn the `zensu:code-reviewer` agent — self-review is terminal, so do not spawn it;
  - re-invoke the whole `/zensu:tdd` skill (its Phase 6 tail would re-spawn the reviewer).

- **Otherwise** (no must-fix, OR `selfReviewFixed` is already true) — finalize:
  1. Standalone handoffs keep the unqualified terminus: run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --chain-done --claimed-review-ticket "<review-ticket>"`. For a verified Autopilot binding, run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --chain-done --autopilot-run "$RUN_ID" --autopilot-attempt "$ATTEMPT" --chain-id "$CHAIN_ID" --claimed-review-ticket "<review-ticket>"`. This is the ticket- and generation-bound chain terminus. If it fails, stop as stale and do not render a successful final report.
  2. Render the final report (below), then stop.

### Final report

Render a CHAIN-END SUMMARY in narrative form with these sections IN THIS ORDER
(pull from your own context; do NOT re-spawn any agent). The TL;DR comes LAST:

```
## Problem
In plain words: the feature, bug, or need this session addressed — why the work happened.

## What I built
Numbered deliverables. For each: what it does in plain words, its status (done /
merged / built-tested), and a PR link if one exists. Carry the audit facts: feature
title, files modified, tests created, build status, coverage status. Cite the plan
+ log paths. When the session plan carries a ## Requirements table, also give
per-requirement status keyed by its stable IDs (AC-###/FR-###: met / partial / dropped).

## How I built it
The TDD discipline followed, then the final zensu:code-reviewer verdict (PASS /
suggestions-only / max-rounds reached) with findings by severity and files
reviewed. Then the auto-fix history: list EVERY code-review round 1..N — including
rounds that fixed nothing. For each round give the round number and either what was
fixed in-thread, OR — for a verification round with no findings — mark it explicitly
as `PASS — 0 findings, nothing to fix`. Always include the final clean verification
round so the reader sees the chain converged. Skip this section only if no review
round ran at all.

## Self-Review Summary
The self-reflection verdict, the seven-dimension findings, what the single self-review fix round
changed (if any), and any advisory findings buffered (not fixed). State whether a fix round ran.

## Open
What is left: any deferred suggestions or max-rounds findings requiring manual fix,
plus the next step. If nothing is open, say so in one line. Close the section with
the bypass-ledger audit line: run
`bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --bypass-list` and render its output as
`Gates bypassed during this session: <output>` (the verb echoes `none` when the
ledger is empty).

## TL;DR
Exactly ONE sentence, and it is the last section: what shipped and the test verdict.
```

## Strict Scope

- Operate ONLY on the current session and the current worktree. NEVER run
  `git worktree list` or traverse sibling worktrees.
- The latch (`selfReviewFixed`) and the terminus (`--chain-done`) are per-chain —
  each `--tdd-begin` re-arms them, so a later chain in the same session gets its
  own single fix round. A bound terminus always carries the captured exact
  run/attempt/chain evidence. Never touch another session's chain-state.
- Do not fix advisory findings — only a genuine must-fix earns the single fix round.

## Response Style

Terse and concrete. Lead with the reflection buckets, then either the fix-round
status or the final report. No preamble. Reference findings as `file:line`.
