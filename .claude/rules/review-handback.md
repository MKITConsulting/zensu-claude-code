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
  bash start and one `case`, and a hand-back that matches no live binding exits before any output.
- **Forgery bound.** The host sets `from` and indents every report line, so another agent, another
  session or a report cannot produce a column-zero frame naming the bound agent. A typed imitation
  is the user's own act. The model steering its reviewer through `SendMessage` gains nothing it
  could not already write into the reviewer's prompt.
- **The Stop guard waits.** `review_handback_wait` sits beside the external-review workflow wait,
  after `outer_finish` and before the inner budget increment. It releases a standalone chain's Stop
  at the code-review stage while the binding is live and `background_tasks` lists the bound agent
  with a status from `RUNNING_TASK_STATUSES` of `external-review-v1.js` (one owner) and an
  `agent_type` that is absent or `zensu:code-reviewer`. Its exclusions are the workflow wait's: a
  live Autopilot run, an Autopilot-bound chain, a deferred-review adoption or claim.

## Coupled sites

`reviewHandbackShapeOk` in `hooks/lib/session-control-core-v1.js` is the one shape owner: the
workflow validator, the bind critical section and the module all call it. Every full reset site
deletes the field, the same roster `implStopCount` uses (`tdd_set_flag` on `active`, the begin,
reset, clear and chain-reset sections in `zensu-tdd-phase.sh`, `resetDeferredReviewState` and the
deferred-review transfer in the core) plus ticket issuance. The frame grammar lives in
`review-handback-v1.js` and in the prefilter of the entry hook. Pins: `H1`–`H14` in
`tests/structure/test-post-review-tdd-scope.sh`, and the roster entry (`U5`) and zero budget for
every prompt kind (`U6`, `U7`) in `tests/structure/test-user-prompt-budget.sh`. Operator accounts: the delegate, entry-hook and Stop
rows of `docs/configuration.md`, §"A consume-mode reviewer the host runs in the background" of
`docs/review-chain.md`, the review-chain paragraph of `docs/tdd-manager-workflow.md`, the prompt
cost paragraph of `docs/architecture.md`, step 5 of `skills/tdd/references/review-chain.md` and the
table in `.claude/rules/prompt-origin.md`.

## Version: `minor`

Walked against `.claude/rules/runtime-lineage.md`: the workflow-state schema gains `reviewHandback`
with a strict key set, and the added `UserPromptSubmit` hook writes session state. Both are on the
breaking side of the list, whatever the permissive readers of older runtimes would tolerate.

## Known gaps

- No live desktop run of the whole flow exists; the hooks were driven with payloads shaped after
  the measured host records.
- An Autopilot-bound chain gets no wait: its Stops keep blocking while the reviewer runs, as
  before this change.
- The wait has no count bound: it releases on every Stop while the host lists the agent as
  running, which is the host's own definition of "paused waiting for background work".
- A reviewer that ends without a hand-back consumes nothing; once the host stops listing it the
  Stop blocks and the resume directive orders a new review.
- `--chain-status` and `/zensu:doctor` do not show a binding.
- Windows is unmeasured.
- `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not included.
