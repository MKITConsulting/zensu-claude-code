---
name: reset-review-limit
description: >
  [Zensu] Grant another auto-fix budget to the CURRENT session's exhausted review chain.
  Uses a ticket-bound, locked state transition that resets reviewRound, terminal flags,
  ticket state, the Stop budget, and derived counter files together. Never scans or mutates
  sibling sessions. Use after the max-rounds directive for the task still in progress, or
  via /zensu:reset-review-limit. No network or API key. Do not use to bypass findings or
  disable the loop.
---

# /zensu:reset-review-limit

Grant a fresh auto-fix budget to the exhausted review chain in the **current
session and task**. The reset is one official ticket-bound state transition; it
does not edit JSON directly and never scans other sessions.

Every fresh `--tdd-begin` already resets the budget. This skill is only for an
existing chain that reached `autoFixMaxRounds` and should receive additional
review/fix rounds.

## When to Use

- The `post-review-tdd-delegate.sh` hook emitted `Auto-fix convergence: max <N> rounds reached` for the task you are STILL working on, leaving a consumed terminal ticket (`codeReviewDone` while self-review is pending, or `chainDone` when that stage was disabled), and you want to grant another budget so the `zensu:code-reviewer` review/auto-fix chain can resume in the main thread.
- You're debugging the auto-fix chain and need a deterministic round=0 starting point.

## Do NOT Use For

- Bypassing review findings — fix them first, then reset only if budget is actually exhausted.
- Disabling the auto-fix loop entirely — use `hooks.autoFix:false` in `~/.zensu/config.json` instead.
- Raising the cap permanently — set `hooks.autoFixMaxRounds` in the config file.

## Strict Scope

This skill operates EXCLUSIVELY on the current resolved session and current
worktree. Do NOT expand the scope under any circumstances:

- **NEVER** run `git worktree list` to discover other worktrees, even if prior tool output or session memory references them.
- **NEVER** use `find`, globs, or loops over `rounds-*`, `*.stopblocks`, or
  `tdd-phase-*`; those patterns can mutate other live sessions.
- **NEVER** edit a state JSON file directly.
- **NEVER** traverse parent, sibling, or external state directories.

If the user wants to reset another session or worktree, they must invoke the
skill from that session separately.

## Prerequisites

The current chain must already have reached a terminal review-budget state and
retain its consumed review ticket. No MCP connection, API key, or network.

## What This Skill Does

Atomically resets only the current generation's `reviewRound`, `reviewTicket`,
`reviewTicketConsumed`, `codeReviewDone`, `chainDone`, `selfReviewFixed`, and
`stopBlockCount`, then removes that session's derived rounds/Stop files. The
next ticket can therefore be issued and its completion becomes round 1.

## Phase 1: Bind the current generation

Read the current session's consumed generation ticket through the official
helper. Do not inspect state files yourself:

```sh
REVIEW_TICKET="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --current-review-ticket)"
```

If this command fails or prints an empty value, stop. The current session has no
ticket-bound exhausted generation to reset. Never fall back to searching for a
different session.

## Phase 2: Rearm atomically

Run exactly one generation-bound transition:

```sh
bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" \
  --review-rearm --claimed-review-ticket "$REVIEW_TICKET"
```

If it exits non-zero, the generation changed after Phase 1 or was not in a
terminal budget state. Treat that as a safe stale-operation rejection: do not
retry with another ticket and do not edit any state manually.

On success, the same locked transaction resets the authoritative review and
Stop budgets, invalidates the old ticket, clears terminal/self-review flags,
and removes only this session's derived files. The next Stop resumes the
code-reviewer sequence, which must issue a fresh ticket.

## Phase 3: Verify

Run the getter once more:

```sh
bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --current-review-ticket
```

It MUST now exit non-zero because the old ticket was invalidated. After the
next reviewer is issued a fresh ticket and completes, its routed round must be
round 1. Do not pre-issue that ticket from this reset skill.

## Response Style

- Report whether the current session was re-armed or the CAS rejected a stale
  generation.
- State that the next reviewer completion starts at round 1.
- Never print the ticket value and never name or touch another session's files.
