---
name: recover-chain
description: >
  [Zensu] Diagnose the CURRENT session's review chain and, only when it is genuinely
  wedged, restore it to a reviewable state with one guarded transition. Reports the
  chain shape and the supported next command via `zensu-log.sh --chain-status`, and
  repairs the single shape no other command can reach: a pending rearm receipt that
  disagrees with its own workflow document, which makes every future review ticket
  refuse, permanently. It drops that receipt and records its own history entry — nothing
  else. It never sets a terminal flag, never grants another auto-fix round, never
  discards an outstanding ticket, never rewrites the ticket slot and never unbinds an
  Autopilot generation — every other shape is refused with the supported command. Use
  when a review chain cannot be advanced, when `--review-ticket` refuses, when
  `--current-review-ticket` and `/zensu:reset-review-limit` both report nothing to work
  with, or via /zensu:recover-chain. No network or API key. Do not use to bypass
  findings.
---

# /zensu:recover-chain

Diagnose and, where legal, un-wedge the review chain of the **current session and
worktree**. Recovery is one official state transition through
`hooks/lib/zensu-log.sh`; it never edits JSON directly and never scans other
sessions.

Most "the chain will not move" situations are NOT wedges — they are a supported
command the caller has not run yet. This skill's first job is therefore to tell you
which of the two it is, and only then to repair.

## The gap this closes

Exactly one chain shape exists that no supported command can leave without closing the
chain unreviewed: a **rearm receipt that disagrees with its own document**. A pending `reviewRearm` receipt is validated
twice — the Session Control core checks only its SHAPE, while the ticket issuer
additionally requires it to match the document's current `autopilotRunId` /
`autopilotAttempt` / `chainId`. Such a receipt is therefore a perfectly legal workflow
document that makes `zensu-log.sh --review-ticket` refuse **forever**, and the only
writers that delete it are a successful ticket issue (which can no longer happen) or a
full `--tdd-begin`.

With no ticket the chain cannot move either: the ticket-bound terminus has nothing to
claim, the unclaimed terminus requires `reviewRound === 0`, and
`/zensu:reset-review-limit` requires a terminal flag plus the exact consumed ticket.
So the only exit was a full `--tdd-begin` / `--tdd-reset`, which zeroes `reviewRound`
(a free auto-fix budget), clears the bypass ledger and drops the generation. Recovery
cost more than the defect and handed out budget it should not.

**Provenance of that shape.** No in-plugin transition produces it: every writer of the
receipt writes it matching the document's own link, and every writer or deleter of the
link fields drops the receipt in the same locked mutation. It arises from an
**externally corrupted or restored workflow document** — a hand-edited file, a state
document copied or restored from another generation, or a future writer that breaks
the invariant. Treat this skill as repair for that class of damage, not as a routine
step of the review chain.

Two shapes that look similar are deliberately NOT recovered:

- `ticket-lost` (`reviewRound >= 1`, no ticket): `--review-ticket` still issues, the
  consumed rounds stand, and the next completion counts against the same budget.
- `ticket-unclaimed` (a ticket is outstanding and unconsumed): the spawned reviewer can
  still claim it — ticket consumption never inspects the receipt — so recovery would
  destroy a live capability.

## When to Use

- `zensu-log.sh --review-ticket` refuses and no reviewer can be spawned.
- `zensu-log.sh --current-review-ticket` reports nothing AND `/zensu:reset-review-limit`
  refuses because its precondition (a terminal budget state plus the consumed ticket)
  is not met.
- You want to know what state the chain is actually in before touching anything —
  run the diagnosis phase alone; it is read-only.

## Do NOT Use For

- **Bypassing review findings.** Recovery never sets `chainDone`, `codeReviewDone`, or
  `selfReviewFixed`, so it cannot end a chain. Fix the findings.
- **Granting another auto-fix round.** `reviewRound` is preserved on purpose. Budget is
  `/zensu:reset-review-limit`'s job, and only from a terminal state.
- **Forcing a chain past an outstanding ticket or a deferred-review claim.** Both are
  refusals, not obstacles.
- **Repairing another session or worktree.** Invoke it from that session instead.

## Strict Scope

This skill operates EXCLUSIVELY on the current resolved session and current
worktree:

- **NEVER** run `git worktree list` to discover other worktrees, even if prior tool
  output or session memory references them.
- **NEVER** use `find`, globs, or loops over `tdd-phase-*` state documents.
- **NEVER** edit a state JSON file directly.
- **NEVER** traverse parent, sibling, or external state directories.

## Prerequisites

- The chain being repaired belongs to the CURRENT session; there is no cross-session form.
- `node` is on PATH and the plugin's `hooks/lib/chain-recovery-v1.js` is readable —
  both verbs fail closed otherwise.
- Phase 1 must report `recoverable: true`. Nothing else authorizes Phase 2.
- No MCP connection, API key, or network.

## Phase 1: Diagnose (read-only)

```sh
ROOT="${CLAUDE_PLUGIN_ROOT}"
LOG="$ROOT/hooks/lib/zensu-log.sh"
[ -f "$LOG" ] || exit 1
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "$LOG" --chain-status
```

Exit codes: `0` a report was printed, `1` this session has no chain state, `2` the
state is unreadable, foreign, or unsafe (or the module/node is unavailable). On `1`
there is nothing to recover — arm a chain with `/zensu:tdd`. On `2` stop: a foreign
`session_id_hash`, a corrupt document, or a symlinked state file is not repairable in
place, and the honest next step is a fresh session or `--tdd-reset`, not a forced write.

The report's `shape`, `recoverable` and `nextCommand` are authoritative. Report them to
the user verbatim before doing anything else:

| `shape` | Meaning | Supported next step |
|---------|---------|---------------------|
| `no-session` | No chain is armed | `/zensu:tdd` |
| `implementing` | Armed, implementation not marked complete | `--tdd-complete` (the report renders the bound form when the chain is Autopilot-bound) |
| `ready-for-review` | Idle chain, ready for a reviewer | `--review-ticket`, then spawn `zensu:code-reviewer` |
| `ticket-unclaimed` | A ticket is outstanding and unconsumed | let that reviewer finish, or issue a fresh ticket and re-spawn |
| `ticket-spent` | A consumed ticket is retained at round 0 (the shape `/zensu:reset-review-limit` leaves behind) | `--review-ticket`; the retained ticket can never be claimed again |
| `ticket-lost` | Rounds were consumed and the ticket is gone | `--review-ticket`; the consumed rounds stand |
| `review-in-flight` | A ticket is claimed, the round is open | the ticket-bound terminus `--code-review-done --claimed-review-ticket` |
| `awaiting-self-review` | `codeReviewDone` is set | `/zensu:self-review` (or `/zensu:reset-review-limit`) |
| `chain-closed` | Terminus already written | nothing |
| `self-review-unbindable` | `codeReviewDone` is set but no consumed ticket can bind the self-review | a fresh generation via `/zensu:tdd` |
| `wedged-stale-rearm` | A receipt that disagrees with its document blocks every future ticket | `--chain-recover` |

Only the last shape is recoverable, and only when `recoverable` is `true`.
`recoverable: false` on a wedged shape means one of five blockers, each named by
`nextCommandId` in the report: `link-shape` (the document carries a receipt without a
complete Autopilot binding — a shape no writer in this plugin produces, so recovery
refuses it rather than repairing corrupt input), `partial-link` (the Autopilot linkage is incomplete —
not repairable in place), `deferred-claim` (an outstanding deferred-review claim must be
cancelled first), `ticket-slot` (`reviewTicketConsumed` is `false` — see "Why the ticket
slot is not repaired" below) or `flag-state` (this generation already latched
`selfReviewFixed`). Follow the report's `nextCommand`; never force past it.

Two in-transaction refusals print their own message instead of a shape: `stale-generation`
(the document changed between the diagnosis and the lock) and `unclassifiable-generation`
(under the lock the document no longer classified). Both are rc 3 and write nothing.

A chain that IS Autopilot-bound but otherwise intact is recoverable: the repair drops the
receipt without touching a single link field or the ticket slot, so the generation stays
bound to its run.

## Phase 2: Recover (one guarded transition)

Run this ONLY when Phase 1 reported `recoverable: true`:

```sh
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "$LOG" --chain-recover
```

Exit codes: `0` recovered (stdout names the shape), `1` no chain state at all, `2` the
state or the plugin is unusable, `3` refused. A refusal prints what was observed plus
the supported command for that shape, and says explicitly whether the chain is wedged.
Treat both `2` and `3` as correct fail-closed outcomes — do not retry in a loop, do not
reach for `--tdd-reset` to force the result, and never edit the state file by hand.

`1` means the state document is absent, and only that: an unavailable session lease, an
unwritable store, a module that fails to load under the lock, and a commit whose outcome
is unconfirmed all report `2` with their own message. (A module that is missing or
tampered with never reaches this code at all — the runtime digest rejects the session
binding first, with its own `runtime digest mismatch` error.) That distinction matters — the remedy for `1` is
`/zensu:tdd`, which starts a fresh generation and zeroes the review budget, so it must
never be applied to a chain that merely failed to take its lock. When a message says
the outcome could not be confirmed, re-run `--chain-status` and believe what it reports.

What the transition writes, under the same external lease every other ticket writer
takes, in one revision-bumping mutation whose acceptance predicate is re-evaluated
after the lock is acquired:

- drops the disagreeing `reviewRearm` receipt,
- appends one `history` entry recording the repair.

That is the whole write. It deliberately leaves untouched: `chainDone`,
`codeReviewDone`, `selfReviewFixed`, `reviewRound`, `stopBlockCount`, `bypasses`,
`phase`, the ticket slot, and every Autopilot link field. Because the review budget
survives, a recovered chain that had already reached `autoFixMaxRounds` converges to the
max-rounds terminus on its very next reviewer completion — recovery restores
reachability, never budget.

**Why the ticket slot is not repaired.** A `reviewTicketConsumed: false` looks like
harmless inconsistency, but writing `true` there completes the exact precondition of the
*unqualified* no-ticket terminus, which would let `--code-review-done` close a chain with
no reviewer, no ticket and no round. Recovery therefore refuses such a document
(`ticket-slot`) rather than normalizing it — the repair must never WRITE a value that was a
missing precondition of a terminus. A retained CONSUMED ticket is a different matter: it
keeps that terminus closed by itself, so a `ticket-spent` chain carrying a disagreeing
receipt is recoverable, and the repair leaves the retained ticket exactly where it is.

Note what this invariant does NOT say. Dropping the receipt returns a wedged chain to
exactly the permissiveness of any freshly armed chain — including the unqualified no-ticket
terminus, which `_tdd_mark_unclaimed_review_critical` refuses while a receipt is present and
accepts once it is gone. That is the intended outcome: the repair restores the normal state,
it does not grant a privilege the normal state lacks. Reviewing the work is still your job.

The audit record shares the single transaction: the `history` entry is written in the
same revision as the repair, so a recovery can never land without its provenance. It is
deliberately NOT written to the bypass ledger — that ledger records gate escapes only, so
everything rendered under "Gates bypassed during this session" stays true, and a repair is
not an escape. Report the recovery in your own response as well.

## Phase 3: Verify and resume

```sh
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "$LOG" --chain-status
```

The shape MUST now be a non-wedged one (normally `ready-for-review`) and
`rearmReceipt` MUST be `none`. Then resume the normal chain: issue a fresh ticket with
`--review-ticket` and spawn `zensu:code-reviewer` with it, exactly as `/zensu:tdd`
Phase 6 does. Do not pre-issue that ticket from this skill.

The report also carries `revision`, `lastEvent` and `recoveries`, so a repair stays
verifiable: `lastEvent` reads `chain-recovered` at the revision the repair produced, and
`recoveries` counts the durable `CHAIN_RECOVERED` history entries — which survive later
transitions, unlike `lastEvent`, and are what `/zensu:doctor` renders as `repaired N×`.
That count is trustworthy because no other verb can write such an entry: the phase writer
refuses both the reserved `CHAIN_RECOVERED` phase and the `chain-recovered: ` reason prefix.
That is how you tell a repair apart from a `--tdd-begin` reset, which would also clear the
receipt but zero the review budget with it.

If the refusal reads `stale-generation`, the document changed between the diagnosis and
the moment the lock was acquired — the in-transaction re-check refused rather than write
into a generation it had not classified. Re-run Phase 1 and follow its `nextCommand`; do
not force a second recovery. The same applies when the shape is still wedged.

## Response Style

- Name the shape you observed, what you did (recovered / refused), and the exact next
  command the user or the chain should run.
- State explicitly that no finding was skipped and no review budget was granted.
