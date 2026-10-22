---
paths:
  - "hooks/post-review-tdd-delegate.sh"
  - "hooks/user-prompt-review-handback.sh"
  - "hooks/lib/review-handback-v1.js"
  - "hooks/stop-chain-enforcer.sh"
  - "hooks/lib/zensu-tdd-phase.sh"
  - "hooks/lib/session-control-core-v1.js"
  - "tests/structure/test-post-review-tdd-scope.sh"
---

# Background Consume-Mode Reviewer (`reviewHandback` + `user-prompt-review-handback.sh`)

The Claude desktop app's Agent tool launches every subagent in the background: its schema has no
`run_in_background`, and the consume-mode `zensu:code-reviewer` spawn returns
`tool_response.status` `async_launched`. Before this change the delegate consumed only a foreground
completion, so on that host no chain could close by its own commands.

## What the host sends (Claude Code 2.1.304, measured in a desktop session)

- The launch's `toolUseResult` carries `status: "async_launched"`, `isAsync: true` and `agentId`.
- The reviewer's report reaches the main thread as a queued prompt: `<agent-message from="<agentId>">`,
  then a line starting `[Subagent hand-back]` at column zero, then the report with every line
  indented by two spaces, then `</agent-message>`. All eight hand-backs of the measuring session had
  that shape and their de-indented body equalled the recorded report. The binary builds the frame
  as `frame + "\n" + indent(report)` and parses it by the same rule.
- `UserPromptSubmit` hooks fired on that prompt in the main thread, mid-turn as well, and their
  `additionalContext` reached the model. The 2.1.304 builder sends `prompt` and no origin field.
- The Stop and SubagentStop inputs declare `background_tasks` entries with `id`, `type`, `status`
  and, for subagents, `agent_type`. A background agent's task id is its agent id.

The hook payload itself was not logged live; the prompt shape comes from the transcript's
`queued_command` record and the binary.

## Decisions

- **The anchor is the bound agent's hand-back at `UserPromptSubmit`.** It is the one main-thread
  event that fires when the real report arrives, so the directive lands beside the report it routes.
  SubagentStop was rejected: it runs in the subagent's context, its output does not reach the main
  thread, and it can fire after the main thread already read the hand-back.
- **The binding is written at the launch.** `post-review-tdd-delegate.sh` runs every check it runs
  on a completion — header lines, envelope, chain state, Autopilot preflight — and then
  `tdd_bind_review_handback` records `reviewHandback {schemaVersion, ticket, agentId, envelope}`
  under the chain lock, for the current unconsumed ticket only. First launch wins: a second agent
  for the same ticket is answered with the holder's id, the same agent again is idempotent, a stale
  or consumed ticket is a silent no-op, and a fresh `--review-ticket` drops the binding.
- **Consumption needs the bound agent inside the CAS.** `tdd_consume_review_ticket_context` takes
  the agent id as its fourth argument; the critical section then requires a binding with that
  ticket and agent, consumes, and deletes the binding in the same write. Every consumption deletes
  it, so a foreground completion of a bound ticket makes the late hand-back a no-op.
- **The delegate keeps one routing path.** `--handback` mode builds the review input from the
  binding (`review-handback-v1.js handback-input`): the two header lines plus the stored envelope,
  then status `handback`. Every parser after it reads `REVIEW_INPUT`, so the envelope check, the
  preflight and all directive branches are the foreground ones. `emit_post_context` names the event
  it answers.
- **The entry hook filters in bash.** `user-prompt-review-handback.sh` passes a prompt on only when
  its JSON holds `<agent-message from=` and `[Subagent hand-back]`; every other prompt costs one
  bash start and one `case`, about 5 ms. Every hand-back frame, whichever agent sent it, runs the
  delegate, which binds the session, verifies the project root and checks the state path before
  `handback-input` compares the agent id: about 0.8 s per frame, measured on macOS. A frame that
  matches no live binding then exits without output and without a write. The entry hook ends with
  `exit 0`, so a delegate refusal never blocks or erases the prompt.
- **Forgery bound.** The host sets `from` and indents every report line, so another agent, another
  session or a report cannot produce a column-zero frame naming the bound agent. A typed imitation
  is the user's own act. The model steering its reviewer through `SendMessage` gains nothing it
  could not already write into the reviewer's prompt.
- **The Stop guard waits for a standalone chain and never misdirects the others.**
  `review_handback_in_flight` asks whether the binding is live and `background_tasks` lists the
  bound agent with a status from `RUNNING_TASK_STATUSES` of `external-review-v1.js` (one owner) and
  an `agent_type` that is absent or `zensu:code-reviewer`. `review_handback_wait`, beside the
  external-review workflow wait, after `outer_finish` and before the inner budget increment,
  releases the Stop only when `tdd_review_handback_releases_stop` in `zensu-tdd-phase.sh` holds as
  well: no nonterminal (live or BLOCKED) Autopilot run of this session, no Autopilot-bound chain,
  no deferred-review adoption in this Stop and no claim file. The Stop hook sets `OUTER_PRESENT`
  back to false for a DONE or CANCELLED run (`outer_is_stop_terminal`). That predicate is the one
  answer to "will the guard release": the delegate's launch text asks it too, with no outer run for
  every standalone launch, because the standalone preflight admits one only without a run or with a
  DONE or CANCELLED one, so the text says the turn may end only when the guard will release.
  A Stop it does not release is charged as before, and while the agent still runs its reason names
  that agent and forbids a fresh ticket, because a fresh ticket drops the binding and the in-flight
  hand-back would then consume nothing.

## Coupled sites

`reviewHandbackShapeOk` in `hooks/lib/session-control-core-v1.js` is the one shape owner: the
workflow validator, the bind critical section and the module all call it. Every full reset site
deletes the field, the same roster `implStopCount` uses (`tdd_set_flag` on `active`, the begin,
reset, clear and chain-reset sections in `zensu-tdd-phase.sh`, `resetDeferredReviewState` and the
deferred-review transfer in the core) plus ticket issuance. The frame grammar lives in
`review-handback-v1.js` and in the prefilter of the entry hook, and its preamble set is shared with
`zensu_prompt_origin` in `hooks/lib/zensu-prompt-origin.sh`. `tdd_review_handback_releases_stop`
has two callers, `review_handback_wait` and the delegate's launch text, and its exclusions are the
workflow wait's. Pins: `H1`–`H23` in
`tests/structure/test-post-review-tdd-scope.sh`, and the roster entry (`U5`) and zero budget for
every prompt kind (`U6`, `U7`) in `tests/structure/test-user-prompt-budget.sh`. Operator accounts: the delegate, entry-hook and Stop
rows of `docs/configuration.md`, §"A consume-mode reviewer the host runs in the background" of
`docs/review-chain.md`, the review-chain paragraph of `docs/tdd-manager-workflow.md`, the prompt
cost paragraph of `docs/architecture.md`, the binding-hook roster of `docs/session-control.md`,
step 5 of `skills/tdd/references/review-chain.md` and the table in `.claude/rules/prompt-origin.md`.

## Version: `minor`

Walked against `.claude/rules/runtime-lineage.md`: the workflow-state schema gains `reviewHandback`
with a strict key set, and the added `UserPromptSubmit` hook writes session state. Both are on the
breaking side of the list, whatever the permissive readers of older runtimes would tolerate.

## Known gaps

- No live desktop run of the whole flow exists; the hooks were driven with payloads shaped after
  the measured host records.
- An Autopilot-bound chain, a session that owns a nonterminal Autopilot run and a project holding
  a deferred-review claim get no release: every Stop while the reviewer runs is charged, so a
  model that keeps ending its turn there can still spend the budget. The launch text and the block
  reason tell it to wait in the turn instead.
- Every background hand-back of the chain, the panel's and the judges' included, pays the
  delegate's bind and root verification (about 0.8 s on macOS) before the agent id is compared. A
  cheaper test ahead of the bind would need the session's state path, which only the bind yields.
- The parser accepts the preamble `Another Claude session sent a message while you were working:`,
  which `zensu_prompt_origin` in `hooks/lib/zensu-prompt-origin.sh` does not know; such a hand-back
  is consumed here but classified `typed` by the reminder and router hooks. The two preamble sets
  are coupled sites.
- `handbackReviewInput` ignores a payload `origin`. The 2.1.304 builder sends none; a host that
  sends `origin.kind: human` would still let a typed exact frame naming the bound agent consume.
- A hand-back the host has queued but not yet delivered when it already lists the agent as
  finished gets the ordinary resume reason, which orders a fresh ticket; following it drops the
  binding before the hand-back arrives.
- Only the consume-mode reviewer is waited for. The panel and the judges run in the background on
  the same host, and a Stop during the fan-out blocks and orders the fan-out again. A wait for
  every running review agent, bounded like the workflow wait, is a separate change.
- The wait has no count bound: it releases on every Stop while the host lists the agent as
  running, which is the host's own definition of "paused waiting for background work".
- A reviewer that ends without a hand-back consumes nothing; once the host stops listing it the
  Stop blocks and the resume directive orders a new review.
- `--chain-status` and `/zensu:doctor` do not show a binding.
- Windows is unmeasured.
- `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not included.
