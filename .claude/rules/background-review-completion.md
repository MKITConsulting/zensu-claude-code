---
paths:
  - "hooks/lib/background-review-v1.js"
  - "hooks/lib/review-ticket-state-v1.js"
  - "hooks/user-prompt-review-handback.sh"
  - "hooks/post-review-tdd-delegate.sh"
  - "hooks/stop-chain-enforcer.sh"
  - "skills/build/references/review-chain.md"
  - "tests/structure/background-review-v1.test.js"
  - "tests/structure/test-background-review.sh"
---

# Background Review Completion (`hooks/lib/background-review-v1.js` + `user-prompt-review-handback.sh`)

The Claude desktop app (Code tab, Claude Code 2.1.304) starts every `Agent` spawn in the
background, and its Agent tool has no `run_in_background` parameter. The consume-mode
`zensu:code-reviewer` therefore answers `tool_response.status: async_launched`, and the review
chain used to demand a foreground re-spawn that this host cannot make: every `/zensu:build` chain in
the desktop app stalled at the consume step and closed with `--tdd-reset`. The panel, the judge
pair and a fix round's re-review aspect run in the background too, and a turn end while they ran
was a blocked Stop that charged the chain-wide budget and ordered a fresh fan-out. The chain now
records every background review launch, waits for it, and claims the ticket when the consume
reviewer's report reaches the main thread, with the routing directive the foreground path gives.

A claim the host cancelled used to be lost. On 2026-10-26 (desktop, plugin 0.29.0, load about
200) the host cancelled the prompt hook on the hand-back after 30082 ms and on a resend after
30989 ms, no completion notification followed, and the ticket stayed unclaimed until a manual
replay, which took 162 s. The arrival is now noted before the claim, and a later Stop or prompt
completes the claim from that note.

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

## Measured (2.1.308, 2026-10-27)

- **A `UserPromptSubmit` hook without a registered `timeout` gets 30 s**, every other event
  600 s (binary constants `OAo=30000` and `yp=600000`). A registered `timeout` is honoured as
  `Math.min(timeout * 1000, …)`: a headless probe registered with `"timeout": 45` ran a 40 s hook
  to completion and delivered its context, while two unregistered hooks were cancelled at 30.08 s.
  The prompt waits for its `UserPromptSubmit` hooks before the model turn starts.
- **The cancel is TERM to the hook's process group and to every descendant `ps` finds, then KILL
  1.5 s later.** Hooks are spawned detached, so each is its own process-group leader. A plain
  background child of a cancelled hook died; only a double-forked child in its own process group
  survived. A cancelled hook's stdout is discarded.
- **The notification is no reliable second arrival on this host.** In transcripts since
  2026-10-15, 651 of 936 hand-backs had no completion notification for the same agent; where both
  arrived, the median gap was 15 s. The prompt hook was cancelled 64 times in 39 transcripts, all
  at `timeoutMs` 30000, against 120 delivered claim directives.
- **One claim spawned 89 `node` children** (11.7 s at load 19): 10 before `match`, 51 from
  `match` to the ticket CAS and 28 after it. 35 were `zensu_resolve_project_dir` verifications.

## The path

1. **Launch.** On `async_launched`, `post-review-tdd-delegate.sh` records the launch in
   `<CLAUDE_PLUGIN_DATA>/background-review/v1/` (temp file then rename at `0600`, exact key sets).
   A `zensu:review-aspect` or `zensu:review-judge` launch becomes one entry per agent under
   `fanout/<scv1-key>/<agentId>.json` (`background-review-v1.js fanout`). The consume-mode
   `zensu:code-reviewer`, after the header, envelope and preflight checks, becomes the session's
   one record `records/<scv1-key>.json` (`record`), written only while the prompt's ticket is the
   ticket the claim would accept; an arrival note the session still holds is dropped then. Its
   directive tells a standalone chain to end its turn and wait, and an Autopilot-bound chain to
   keep its turn.
2. **Arrival.** `hooks/user-prompt-review-handback.sh` exits in bash, before any `node` child,
   unless the payload contains `<agent-message from=` or `<task-notification>` AND the store holds
   a regular `records/scv1_*.json` or `fanout/scv1_*/*.json`, or the store holds a regular
   `arrivals/scv1_*.json` of any session. Its first `node` child is `background-review-v1.js
   arrive`, which derives the session key from the payload, retires every fan-out entry whose
   agent the prompt names, any status, and, for a completed arrival of the session's pending
   consume reviewer, writes the arrival note `arrivals/<scv1-key>.json` (exact key set, `0600`,
   temp file then rename) before anything is claimed. It prints
   `pending agent=<id> source=<prompt|note> retired=<n>` or `idle reason=<r> retired=<n>`, and the
   hook starts the delegate with `--background-arrival` only on `pending`, passing
   `ZENSU_BR_CLAIM_BY`. The delegate binds and runs `match`. For the consume record `match`
   answers `claim` on the prompt's own completed arrival, and otherwise on a note naming the
   record's agent and ticket, WITHOUT retiring either, and names the source; a note outranks a
   later notification with another status. It answers `ended` on such a notification without a
   note (record retired), and `stale-ticket` when the claim would no longer accept the record's
   ticket (record and note retired). On a claim the delegate re-runs the header, envelope and
   preflight checks on the STORED header, claims through `tdd_consume_review_ticket_context`,
   retires record and note (`retire`), and emits the routing directive as `UserPromptSubmit`
   context with one lead sentence per arrival kind and source.
3. **Stop.** Before the wait, `background_review_recover` in `stop-chain-enforcer.sh` checks in
   bash for the session's arrival note beside its consume record. With both present it runs the
   delegate with `--background-recovery`, whose `match` reads only the note
   (`ZENSU_BR_RECOVERY=1`), and a directive it prints becomes the block reason, ahead of
   `outer_finish`. `background_review_wait` asks `wait` while a record or a fan-out entry exists.
   A consume record younger than the bound that still matches the issued ticket, or any fan-out
   entry younger than the bound, releases a standalone chain's Stop with one stderr line and no
   budget charge. An Autopilot-bound chain's Stop is held: it blocks, names the running agents,
   and skips the inner Stop budget increment. An owned Autopilot run without a bound chain and an
   adopted deferred review take neither; their resume reason is led by one sentence naming the
   running agents. When the recovery left record and note in place, the release, the hold and
   that sentence say instead that the report arrived and its claim is pending
   (`BACKGROUND_REVIEW_ARRIVED_LEAD`).

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
- **The arrival is noted before the claim, by the prompt hook's first `node` child.** The host's
  cancel kills the hook's whole process group, so only state written before the kill survives it,
  and the claim is the expensive part. `arrive` is one child that reads no workflow state and
  needs no bind; it derives the session key with the core's `sessionKey`, the function the
  delegate's `zensu_resolve_session_id` uses on the same payload. A note grants nothing a prompt
  could not: it records an arrival the column-zero rule already accepted, and every claim still
  re-runs the header, envelope and preflight checks and the ticket CAS.
- **Record and note live and die together, and a kill keeps both.** A `HUP`/`INT`/`TERM` trap
  clears the EXIT trap on every arrival kind, and a SIGKILL runs no trap at all, so a cut-off
  claim leaves record and note for the next event. The EXIT trap retires both on every deliberate
  refusal (a failed header, envelope or preflight check). Right before the CAS the EXIT trap is
  cleared, so a failed claim keeps both too, and a later event retries it; the ticket CAS keeps
  the claim exactly-once, the stale-ticket answer retires a pair whose ticket is spent, and a
  note whose record is gone or names another agent or ticket is removed by the next `arrive` or
  `match`. The notification used to retire the record on a failed or killed claim, so that the
  next Stop would not wait for a reviewer that had already reported; the note's recovery path
  answers that Stop now.
- **The prompt hook is registered with `"timeout": 180`, and its claim deadline comes from the
  same number.** The 30 s default is the measured cause. 180 is a judgement: the incident replay
  of the 89-child claim took 162 s at load about 200. `BR_HOOK_TIMEOUT` in the hook spells the
  number a second time, and `BR1e` holds it equal to the registration. The hook passes
  `ZENSU_BR_CLAIM_BY`, 45 s before that limit, and the delegate checks it right before the CAS:
  past it the delegate defers, keeps record and note, and emits a short notice that the claim
  completes at the next Stop or prompt. The Stop path derives its own deadline from
  `zensu_stop_deadline_seconds`, 20 s before the supervisor's kill, and passes none when the hook
  runs unsupervised. A claim cut off after its CAS would leave `reviewRound` raised with no
  directive delivered, which is what the margin is for.
- **Later events complete the claim from the note.** The prompt hook's prefilter passes while any
  note exists, so the next prompt of any kind claims through `arrive` and the delegate. The Stop
  hook runs `background_review_recover` after its three terminal early exits and before both
  waits, and emits the directive ahead of `outer_finish`, because the inner chain routes first
  and the ticket is already spent. A Stop that adopted a deferred review renews its handoff lease
  first, and a failure there cannot veto the directive for the same reason. The recovery prints
  the directive as raw text and the Stop hook JSON-encodes it in `emit_block`, so the Stop path
  spends no `node` child on the emit.
- **The delegate memoizes the project root and reads claim-independent values before the CAS.**
  `zensu_memoize_project_dir` follows its only bind (`.claude/rules/stop-latency.md`), and the
  full-suite policy, the vanilla flag and every config read move above the CAS, as two flags for
  the combined summary and the scope sentence. After the claim returns, a standalone claim that is
  not at max rounds spawns only the claim-field parse, the record retire and the emit (`BR4b`).
- **The prompt hook runs the delegate as a background child and passes on `HUP`, `INT` and
  `TERM`** as a `TERM`. A host that signals only the process it started would otherwise orphan
  the delegate, which would claim the ticket and write the directive into a closed pipe. `exec`
  would deliver the signal without a forwarder, but the delegate exits 2 on a plugin-root
  mismatch, and a `UserPromptSubmit` hook that exits 2 blocks the prompt, the reviewer's report
  with it; the forwarder keeps the hook's exit status at 0. The measured host also signals the
  whole group, so the delegate gets the `TERM` twice.
- **Rejected:** a double-forked claim worker, which the measured cancel does not reach, because a
  claim it finished after the hook died writes its directive into a discarded stdout and spends
  the ticket; the host's `asyncRewake` hook option, which was not measured; and redelivering a
  directive after a kill that landed past the CAS, which needs a store of rendered directives.
- **The wait is bounded at `LIMITS.waitTtlMs`** (60 minutes), a judgement: one measured consume
  reviewer took about seven minutes. `record`, `fanout` and `wait` print it as `ttl=`, and the
  delegate and the Stop hook interpolate it rather than spelling the number. Records and notes
  idle past 24 hours are swept on the next launch.
- **An Autopilot-bound chain is held, not released.** An owned run must not stop, so the Stop
  blocks as before but skips `autopilot_increment_inner_stop_budget_capped` while a record or entry
  is fresh. The hold costs one turn per Stop the model attempts, bounded by the wait bound; PR #483
  made the same trade for the Autopilot stage budget while review seats run.
- **Fan-out entries carry no ticket and no chain binding.** The Stop hook consults them only on the
  path where it would block for an armed review chain, so an entry from an earlier chain of the
  same session can release a Stop for at most the wait bound.
- **The re-spawn sentence keeps `run_in_background: false` only where the Agent tool offers that
  parameter**, in the three severity arms of the delegate, the Stop resume reason and steps 10 and 5
  of `skills/build/references/review-chain.md`.

## Coupled sites

- The store layout is spelled in `storeLocations`, `fanoutDirectory` and `arrivalFile`, in
  `background_review_wait` (record path and fan-out directory, so a Stop with nothing pending
  spawns no `node` child), in `background_review_recover` (record and note paths), and in the
  prefilter of `user-prompt-review-handback.sh`, which must stay a superset of all three.
- The arrival markers are spelled in `scanLines` and in the prefilter's `case`, which must stay a
  superset of what `scanLines` accepts.
- The claim predicate is `review-ticket-state-v1.js`; `_ZENSU_TDD_TICKET_STATE` is in the export
  list of `zensu-tdd-phase.sh` beside `_ZENSU_TDD_CHAIN_RECOVERY`.
- The `wait` line `wait kind= agent= age= count= ttl=` is parsed by `background_review_wait`, the
  `recorded agent= ttl=` line by the delegate's launch arm, the `pending agent=` prefix of the
  `arrive` line by the prompt hook's `case`, and the `source` field of the `match` claim line by
  the delegate's verdict parse.
- `--background-arrival` and `--background-recovery` are the delegate's two background modes; the
  Stop hook is the only caller of the second. `ZENSU_BR_CLAIM_BY` and `ZENSU_BR_RECOVERY` are read
  by the delegate and `envOptions` respectively.
- `BR_HOOK_TIMEOUT` and `BR_CLAIM_MARGIN` in the prompt hook, the registration in
  `hooks/hooks.json` (`BR1`, `BR1e`), and `BACKGROUND_REVIEW_CLAIM_MARGIN` in the Stop hook.
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
- `tests/structure/test-background-review.sh` drives the paths through `node` stubs keyed to the
  `MATCH`, `TICKET_STATE` and `CLAIM_CONTEXT` variables of the delegate's, the claim's and the
  claim-field parse's `node` calls: `BR9d` and `BR9d2` a refusal through a hand-back and
  through a completion notification, which retires record and note, `BR9e` the forwarder and the
  kept pair, `BR9f` to `BR9h` a
  failed claim, the arrived release and the Stop claim, `BR14c` the bound hold, `BR16` and `BR17`
  a host-style cancel (TERM to the process group and its descendants, KILL 1.5 s later) and the
  Stop that completes the claim once, `BR18` to `BR18c` the deferral, the cross-session cost and
  the prompt that completes the claim, and `BR19` a Stop and a prompt racing on one note. `BR4b`
  counts the root verifications and the calls after the claim through the classifying shim, which
  keys on the `core.readContext({ recordsDir, sessionId: key })` literal the latency suite reads.
- Operator accounts: the delegate, Stop and prompt-hook rows of `docs/configuration.md`,
  §"Background review agents" of `docs/review-chain.md`, `docs/architecture.md`, and the step-10
  lead and step 5 of `skills/build/references/review-chain.md`.

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
- **A kill after the ticket CAS still loses the directive.** The claim has landed, the delegate dies
  before it emits, and the next event finds a spent ticket and retires the pair. The deadline
  margin and the three post-claim children make that window small, not empty. A killed foreground
  post-review hook has the same window.
- **A kill before `arrive` wrote the note** leaves only the record, as before this change: a
  standalone Stop then waits out the bound, unless a later arrival names the reviewer again.
- **Another session's note costs every prompt one `node` child.** The prefilter cannot derive the
  session key in bash, so while any session holds a note, each prompt of every session runs
  `arrive`, which answers `idle` for a note that is not its own (`BR18b`). A note normally lives
  for seconds; a session whose bind keeps failing keeps its pair until the 24-hour sweep.
- **The Stop recovery runs under the Stop deadline** (45 s by default). On a loaded host it defers
  and the release says the claim is pending; the next prompt then claims with the prompt hook's
  larger budget. Measured on 2026-10-27 at a load of about 100 to 150: one recovery Stop under
  the 75 s maximum took 42 s, and in a full suite run both recovery Stops of `BR17` deferred. So
  `recover_until_claimed` lets `BR9h` and `BR17` meet up to three deferring Stops before the
  claim, and each of them must release with record, note and ticket intact.
- **A kill inside the ticket CAS leaves two empty temporary files** (`<state>.XXXXXX` and
  `<state>.next.XXXXXX`) beside the workflow document: `_tdd_consume_review_ticket_critical`
  creates them before its `node` child and removes them only on its own exits. Nothing reads or
  sweeps them. Observed after the `BR16` cancel.
- **Not measured live.** The suite drives the real hooks with payloads shaped like the
  measurements and a host-style cancel; no desktop session has run the patched plugin yet.
- **Windows is unmeasured.** The suite is in `ciStructureTests` and in no blocking Windows shard;
  `tests/profiles/windows-native-structure.v1.json` lists it as excluded, because BR2's host
  branch is a native-Windows marker that `windows-ci-contract.test.js` audits. The cancel
  simulation relies on `set -m` and `ps`.
- `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not changed.

## Version: `patch`

Walked against `.claude/rules/runtime-lineage.md` entry by entry: no context-record or
workflow-state field; the record and fan-out key sets are unchanged, and the arrival note's key set
is strict but ships for the first time, so no released reader or writer predates it, and a later
change to it is a `minor`. No hook is added, removed or renamed and no matcher changes: the prompt
hook's registration gains a `timeout`, which is neither. The prompt hook still returns only
`additionalContext`, and the Stop hook's recovery emits a block it already emitted, with another
reason. The claim still runs through the existing ticket transition, so a runtime of the same
lineage reads the result exactly as it reads a foreground claim. An older installation of the same
lineage never serves a session after a newer one, and the newer one reads the older records
unchanged. No config key is added, and no attestation moves. The original feature's walk, recorded
here before: the record and fan-out key sets shipped for the first time, the added hook returned
only `additionalContext`, and the claim read its predicate from `review-ticket-state-v1.js` with the
same field test.
