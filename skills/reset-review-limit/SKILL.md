---
name: reset-review-limit
description: >
  [Zensu] Grant another auto-fix budget to the CURRENT session's exhausted review chain.
  Standalone chains use the one-shot ticket CAS; durable Autopilot chains use the central
  exact session/run/attempt/chain/ticket-bound composite, which safely chooses same-chain
  rearm or blocked-generation retirement. Never scans or mutates sibling sessions. Use
  after the max-rounds directive for the task still in progress, or via
  /zensu:reset-review-limit. No network or API key. Do not use to bypass findings.
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
- A durable Autopilot run has the same exhausted Inner generation and is either still
  `TDD_RUNNING` during the self-review handoff or already `BLOCKED` with code
  `TDD_MAX_ROUNDS`.
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
retain its consumed review ticket. A durable Autopilot reset additionally
requires the official status API to expose the exact current Inner binding. No
MCP connection, API key, or network.

## What This Skill Does

Atomically resets only the current generation's `reviewRound`, `reviewTicket`,
`reviewTicketConsumed`, `codeReviewDone`, `chainDone`, `selfReviewFixed`,
`chainOutcome`, and `stopBlockCount`, then removes that session's derived
rounds/Stop files. The next ticket can therefore be issued and its completion
becomes round 1.

For a durable generation, the central `zensu-log.sh --review-rearm` composite
locks Outer then Inner, validates the exact run/attempt/chain/ticket binding,
and selects rearm versus retire-and-resume internally. It stores a strictly
validated pending `reviewRearm` receipt containing the exact binding and the
consumed ticket's SHA-256 digest (never the ticket). This receipt permits safe
crash retries only while the committed post-rearm state is unchanged.

## Phase 1: Bind the current generation

Resolve the current session and read its consumed generation ticket through the
official helpers. Do not inspect state files yourself:

```sh
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
SESSION_ID="$(zensu_resolve_session_id "${CLAUDE_SESSION_ID:-}")"
REVIEW_TICKET="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --current-review-ticket)"
```

If this command fails or prints an empty value, stop. The current session has no
ticket-bound exhausted generation to reset. Never fall back to searching for a
different session.

Then read the official durable status once:

```sh
AUTOPILOT_STATUS="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --autopilot-status 2>/dev/null)"
AUTOPILOT_STATUS_RC=$?
```

Exit code 1 means there is no active durable run, so use the standalone branch
below. Exit code 0 at `stage=DONE` or `stage=CANCELLED` is only a historical outer pointer:
tentatively use the standalone branch, but let its central
`--review-rearm` CAS prove that the current Inner is actually unbound. That CAS
must reject a still-bound or corrupt current Inner; only its successful exact ticket transition proves standalone status.
Never reuse the historical outer
run/attempt/chain as current evidence.

For every other exit-0 status, `ownerSessionId` and `tdd.sessionId` must both
equal `SESSION_ID`; take `runId`, `tdd.attempt`, and `tdd.chainId` from that JSON
as `RUN_ID`, `ATTEMPT`, and `CHAIN_ID`, never from conversation memory. Accept
only `stage=TDD_RUNNING`, or `stage=BLOCKED` with
`blocked.code=TDD_MAX_ROUNDS`. In particular, `BLOCKED` never falls through to
standalone. A status parse error, another non-zero exit, an incomplete/mismatched
binding, or any other same-owner stage is a fail-closed stop. Do not read
`.zensu/state` directly.

## Phase 2: Rearm atomically

### Standalone chain

When no current-session durable binding exists, or official status exposes only
a historical `DONE`/`CANCELLED` pointer, run exactly one generation-bound
transition:

```sh
bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" \
  --review-rearm --claimed-review-ticket "$REVIEW_TICKET"
```

If it exits non-zero, the generation changed after Phase 1, was not in a
terminal budget state, or the current Inner was not actually standalone.
Treat that as a safe stale-operation rejection: do not reinterpret a historical
pointer, retry with another ticket, or edit any state manually.

On success, the same locked transaction resets the authoritative review and
Stop budgets, invalidates the old ticket, clears terminal/self-review flags,
and removes only this session's derived files. The next Stop resumes the
code-reviewer sequence, which must issue a fresh ticket.

The standalone replay contract is deliberately unchanged: a second normal
`--review-rearm` with the consumed ticket MUST fail.

### Durable Autopilot chain

For the exact current-session binding, call the central helper once with every
binding dimension and the consumed ticket:

```sh
bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" \
  --review-rearm --autopilot-run "$RUN_ID" \
  --autopilot-attempt "$ATTEMPT" --chain-id "$CHAIN_ID" \
  --claimed-review-ticket "$REVIEW_TICKET"
```

The helper is the only owner of this composite. For `stage=TDD_RUNNING`, it
rearms the same Inner chain after reconciling any already-finished Inner state.
For `stage=BLOCKED` with `blocked.code=TDD_MAX_ROUNDS`, it retires the exhausted
Inner and resumes the Outer to `AWAIT_TDD` under the same Outer-first lock order.
Do not source a phase library, choose a retirement flag, or emit a separate
Outer event from this skill.

The CAS requires the exact session/run/attempt/chain, the exact consumed ticket,
`chainOutcome=max-rounds`, and the appropriate terminal review state. Treat a
definite non-zero exit as a safe stale/corrupt-operation rejection: do not retry
with another ticket and do not edit any state manually. After an indeterminate
process crash, only the byte-identical binding and old ticket may be retried;
the strict digest receipt makes that exact retry an idempotent exit 0. A wrong
ticket, binding, malformed receipt, or progressed chain is always rejected
without reinterpretation.

## Phase 3: Verify

For a standalone or same-chain durable rearm, run the getter once more:

```sh
bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --current-review-ticket
```

It MUST now exit non-zero because the old ticket was invalidated. After the
next reviewer is issued a fresh ticket and completes, its routed round must be
round 1. Do not pre-issue that ticket from this reset skill.

For a durable rearm, read official status again. `TDD_RUNNING` means the same
chain was rearmed and its next reviewer completion starts at round 1.
`AWAIT_TDD` means the central composite retired and resumed the exhausted
generation; invoke `/zensu:tdd` with the exact `AUTOPILOT-RUN: <runId>` binding.
That flow must start `ATTEMPT + 1` through the bound `--tdd-begin` form with a
fresh chain id. The new begin clears the old rearm receipt. Any other status is
a verification failure; do not invent a recovery event.

## Response Style

- Report whether the current session was re-armed, its exhausted Inner attempt
  was retired for a fresh bound attempt, or the CAS rejected a stale generation.
- State that the next reviewer completion starts at round 1.
- Never print the ticket value and never name or touch another session's files.
