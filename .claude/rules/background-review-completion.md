---
paths:
  - "hooks/lib/background-review-v1.js"
  - "hooks/lib/review-ticket-state-v1.js"
  - "hooks/user-prompt-review-handback.sh"
  - "hooks/post-review-tdd-delegate.sh"
  - "hooks/stop-chain-enforcer.sh"
  - "skills/tdd/references/review-chain.md"
  - "tests/structure/background-review-v1.test.js"
  - "tests/structure/test-background-review.sh"
---

# Background Review Completion (`hooks/lib/background-review-v1.js` + `user-prompt-review-handback.sh`)

The Claude desktop app (Code tab, Claude Code 2.1.304) starts every `Agent` spawn in the
background, and its Agent tool has no `run_in_background` parameter. The consume-mode
`zensu:code-reviewer` therefore answers `tool_response.status: async_launched`, and the review
chain used to demand a foreground re-spawn that this host cannot make: every `/zensu:tdd` chain in
the desktop app stalled at the consume step and closed with `--tdd-reset`. The panel, the judge
pair and a fix round's re-review aspect run in the background too, and a turn end while they ran
was a blocked Stop that charged the chain-wide budget and ordered a fresh fan-out. The chain now
records every background review launch, waits for it, and claims the ticket when the consume
reviewer's report reaches the main thread, with the routing directive the foreground path gives.

## Measured (desktop 2.1.304, 2026-10-21)

- **`SubagentStop` is not a completion signal.** It fires for background agents, but at EVERY
  stop: one probe agent fired it four times, including stops the host overrode with a
  `[handback-send-enforce]` nudge, and its output cannot reach the main thread.
- **The report arrives as a prompt.** A hand-back is a prompt whose frame line is
  `<agent-message from="<agentId>">` followed by a line starting `[Subagent hand-back]`; about
  0.1 s later a `<task-notification>` block carries `<task-id><agentId></task-id>` and
  `<status>completed</status>`. Both fire `UserPromptSubmit` on the main thread, also when they
  are queued mid-turn. The stored user message prefixes the frame with
  `Another Claude session sent a message:`.
- **The launch result names the agent.** `tool_response.agentId` sits beside
  `status: async_launched`.
- **The host indents the report.** Its frame text says every line of the report is indented, so
  a frame-like line at column zero inside it would be forged.
- Only auto mode injects `SubagentHandback`; in other modes the final text is delivered and the
  completion notification is the arrival.
- The Stop payload's `background_tasks` entries for agents were NOT measured, which is why the
  wait reads the plugin's own launch records rather than that field.

## The path

1. **Launch.** On `async_launched`, `post-review-tdd-delegate.sh` records the launch in
   `<CLAUDE_PLUGIN_DATA>/background-review/v1/` (temp file then rename at `0600`, exact key sets).
   A `zensu:review-aspect` or `zensu:review-judge` launch becomes one entry per agent under
   `fanout/<scv1-key>/<agentId>.json` (`background-review-v1.js fanout`). The consume-mode
   `zensu:code-reviewer`, after the header, envelope and preflight checks, becomes the session's
   one record `records/<scv1-key>.json` (`record`), written only while the prompt's ticket is the
   ticket the claim would accept. Its directive tells a standalone chain to end its turn and wait,
   and an Autopilot-bound chain to keep its turn.
2. **Arrival.** `hooks/user-prompt-review-handback.sh` exits in bash, before any `node` child,
   unless the payload contains `<agent-message from=` or `<task-notification>` AND the store holds
   a regular `records/scv1_*.json` or `fanout/scv1_*/*.json`. Otherwise it hands the payload to the
   delegate with `--background-arrival`, which binds and runs `match`. `match` retires every fan-out
   entry whose agent the prompt names, any status. For the consume record it answers `claim` on a
   completed arrival WITHOUT retiring the record, `ended` on another status (record retired), and
   `stale-ticket` when the claim would no longer accept the record's ticket (record retired). On a
   claim the delegate re-runs the header, envelope and preflight checks on the STORED header,
   claims through `tdd_consume_review_ticket_context`, retires the record (`retire`), and emits the
   routing directive as `UserPromptSubmit` context with one lead sentence.
3. **Stop.** `background_review_wait` in `stop-chain-enforcer.sh` asks `wait` while a record or a
   fan-out entry exists. A consume record younger than the bound that still matches the issued
   ticket, or any fan-out entry younger than the bound, releases a standalone chain's Stop with one
   stderr line and no budget charge. An Autopilot-bound chain's Stop is held: it blocks, names the
   running agents, and skips the inner Stop budget increment. An owned Autopilot run without a
   bound chain and an adopted deferred review take neither; their resume reason is led by one
   sentence naming the running agents.

## Decisions

- **One owner of the claim predicate.** `hooks/lib/review-ticket-state-v1.js` exports
  `claimContext` and `claimableTicket`. `_tdd_consume_review_ticket_critical` `require`s it through
  `_ZENSU_TDD_TICKET_STATE`, and `background-review-v1.js` `require`s it, so "the ticket the claim
  would accept" is decided by the same code at launch, at arrival and at Stop. A hand copy in the
  module was the first draft; it accepted documents the claim refuses.
- **An arrival counts only at column zero.** `scanLines` takes a hand-back only when a whole line
  equals `<agent-message from="<agentId>">` and the next line starts with `[Subagent hand-back]`,
  and a notification only inside a `<task-notification>` block whose tags each stand alone on a
  column-zero line. Substring matching was the first draft and would have let any report that
  quotes the reviewer's frame claim its ticket.
- **The consume record outlives a hand-back's claim attempt, never the notification's.** `match`
  leaves a claimable record in place, and the delegate retires it right after the claim succeeds.
  On a hand-back an EXIT trap retires it on every deliberate refusal (a failed header, envelope or
  preflight check), a `HUP`/`INT`/`TERM` trap clears that EXIT trap, and a failed claim keeps it,
  so the notification that follows can still claim. The notification is the last arrival, so its
  EXIT trap stays armed through the claim: a refusal, a failed claim or a kill retires the record,
  and the next Stop blocks with the resume directive instead of waiting out the bound for a
  reviewer that has already reported. The ticket CAS makes the claim exactly-once, and the
  stale-ticket answer retires a record whose ticket is spent.
- **The prompt hook runs the delegate as a background child and passes on `HUP`, `INT` and
  `TERM`** as a `TERM`. A host that signals only the process it started would otherwise orphan
  the delegate, which would claim the ticket and write the directive into a closed pipe. `exec`
  would deliver the signal without a forwarder, but the delegate exits 2 on a plugin-root
  mismatch, and a `UserPromptSubmit` hook that exits 2 blocks the prompt, the reviewer's report
  with it; the forwarder keeps the hook's exit status at 0.
- **The prompt hook carries no timeout**, like the delegate's PostToolUse entry: a claim the host
  cut off after the ticket CAS would leave `reviewRound` raised with no directive delivered. The
  host's default hook limit still applies.
- **The wait is bounded at `LIMITS.waitTtlMs`** (60 minutes), a judgement: one measured consume
  reviewer took about seven minutes. `record`, `fanout` and `wait` print it as `ttl=`, and the
  delegate and the Stop hook interpolate it rather than spelling the number. Records idle past
  24 hours are swept on the next launch.
- **An Autopilot-bound chain is held, not released.** An owned run must not stop, so the Stop
  blocks as before but skips `autopilot_increment_inner_stop_budget_capped` while a record or entry
  is fresh. The hold costs one turn per Stop the model attempts, bounded by the wait bound; PR #483
  made the same trade for the Autopilot stage budget while review seats run.
- **Fan-out entries carry no ticket and no chain binding.** The Stop hook consults them only on the
  path where it would block for an armed review chain, so an entry from an earlier chain of the
  same session can release a Stop for at most the wait bound.
- **The re-spawn sentence keeps `run_in_background: false` only where the Agent tool offers that
  parameter**, in the three severity arms of the delegate, the Stop resume reason and steps 10 and 5
  of `skills/tdd/references/review-chain.md`.

## Coupled sites

- The store layout is spelled in `storeLocations` and `fanoutDirectory`, in `background_review_wait`
  (record path and fan-out directory, so a Stop with nothing pending spawns no `node` child), and
  in the prefilter of `user-prompt-review-handback.sh`, which must stay a superset of both.
- The arrival markers are spelled in `scanLines` and in the prefilter's `case`, which must stay a
  superset of what `scanLines` accepts. `handbackReports` reads the same frame grammar with the
  same line splitter and exports it, with `AGENT_ID_RE`, to the review packet gate, which takes
  each frame's de-indented report from it (`.claude/rules/review-packet-gate.md`).
- With `hooks.reviewPacketGate` on, the delegate's arrival branch runs the gate's `record --event
  UserPromptSubmit` after `match` and before the `ARRIVAL_MATCH` exit, so a failed `match` sets
  `ARRIVAL_MATCH` empty instead of ending the branch, and `review_gate_check` runs at the consume
  launch before `record` and at the arrival before the claim. `tests/structure/test-background-review.sh`
  turns the gate off in its config, because its fixtures carry no canonical packet.
- The claim predicate is `review-ticket-state-v1.js`; `_ZENSU_TDD_TICKET_STATE` is in the export
  list of `zensu-tdd-phase.sh` beside `_ZENSU_TDD_CHAIN_RECOVERY`.
- The `wait` line `wait kind= agent= age= count= ttl=` is parsed by `background_review_wait`, and
  the `recorded agent= ttl=` line by the delegate's launch arm.
- The fan-out types are `FANOUT_TYPES` in the module and the `case` in the delegate's PostToolUse
  branch. `FANOUT_TYPES` is derived, never spelled: the `zensu:` names in `REVIEWER_TYPES` of
  `claude-principal-v1.js` other than `REVIEWER_SUBAGENT_TYPE`, because
  `tests/structure/reviewer-spawn-allow-v1.test.js` fails on any second spelled copy of a confined
  reviewer under `hooks/`.
- The store is in both protected-root lists of `reviewer-capability-v1.js` (`BR1a`).
- The prompt hook has a `budget()` row in `tests/structure/test-user-prompt-budget.sh` and a row in
  the table of `.claude/rules/prompt-origin.md`; the hook count in `docs/configuration.md` moved
  with it (`test-readme-hook-count-sync.sh`).
- `S8c` in `tests/structure/test-post-review-tdd-scope.sh` pins the launch directive's wait
  wording.
- `BR9e` and `BR9f` in `tests/structure/test-background-review.sh` pin the prompt hook's forwarder,
  the hand-back's `TERM` trap and the notification's retire on a failed claim, through `node`
  stubs keyed to the `MATCH` and `TICKET_STATE` variables of the delegate's and the claim's
  `node` calls.
- Operator accounts: the delegate, Stop and prompt-hook rows of `docs/configuration.md`,
  §"Background review agents" of `docs/review-chain.md`, `docs/architecture.md`, and the step-10
  lead and step 5 of `skills/tdd/references/review-chain.md`.

## Known gaps

- **The arrival depends on `UserPromptSubmit` firing for queued prompts.** If a host stops doing
  so, every wait ends at the bound and the resume directive applies again.
- **The column-zero rule rests on the host's indentation.** A peer message whose body the host does
  not indent, and that names a pending agent id, could still carry a forged frame; the id sits only
  in the session's own `0600` store, and the hand-back frame text is the only measured statement
  of that indentation.
- **Repo-local review personas are not recorded.** Their subagent types are repo-authored, so a turn
  end while only a persona runs blocks and charges the budget as before.
- **An Autopilot-bound chain's hold costs turns.** Each held Stop is one more model turn until the
  report arrives; the bound caps it, the budget does not.
- **A notification that says no report was delivered** still claims the ticket; the lead sentence
  tells the main thread to ask the reviewer for its report with `SendMessage` first.
- **A kill during the claim itself loses the directive** once the ticket CAS has run: the claim
  finishes, the delegate exits without emitting the directive, and the next arrival finds a spent
  ticket. A killed foreground post-review hook has the same window.
- **A hand-back whose claim fails, with no notification after it,** keeps the record until the
  bound. The measured host always sends the notification.
- **A host that kills the hook with `SIGKILL`** orphans the delegate, and the forwarder cannot
  reach it. Which signal the host's hook timeout sends was not measured.
- **Not measured live.** The suite drives the real hooks with payloads shaped like the
  measurements; no desktop session has run the patched plugin yet.
- **Windows is unmeasured.** The suite is in `ciStructureTests` and in no blocking Windows shard;
  `tests/profiles/windows-native-structure.v1.json` lists it as excluded, because BR2's host
  branch is a native-Windows marker that `windows-ci-contract.test.js` audits.
- `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not changed.

## Version: `patch`

Walked against `.claude/rules/runtime-lineage.md` entry by entry: no context-record or
workflow-state field; the record and fan-out key sets are strict but ship for the first time, so
no released reader or writer predates them, and a later change to either is a `minor`. The added
`UserPromptSubmit` hook returns only `additionalContext`, and the Stop hook's new hold is a block
it already emitted, minus one budget increment. The claim now reads its predicate from
`review-ticket-state-v1.js` with the same field test, so it accepts and refuses exactly the
documents it did before. It writes workflow state only through that existing claim transition, so
a runtime of the same lineage reads the result exactly as it reads a foreground claim. The new
store is read only by this release: an older installation never records a launch, and a newer one
that finds no record stays silent. No matcher changes, no config key is added, and no attestation
moves.
