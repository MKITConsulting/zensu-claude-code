---
paths:
  - "hooks/lib/review-consume-v1.js"
  - "hooks/review-consume-subagent-stop.sh"
  - "hooks/post-review-tdd-delegate.sh"
  - "hooks/stop-chain-enforcer.sh"
  - "hooks/lib/zensu-log.sh"
  - "hooks/lib/zensu-tdd-phase.sh"
  - "hooks/lib/chain-recovery-v1.js"
  - "skills/tdd/references/review-chain.md"
  - "tests/structure/test-review-consume-background.sh"
  - "tests/structure/test-post-review-tdd-scope.sh"
---

# Background Consume Reviewer (`--review-consume`)

The Claude desktop app (Code tab) launches every Agent call in the background: its Agent tool
has no `run_in_background` field, and a `zensu:code-reviewer` spawn that sets
`run_in_background: false` still returns `tool_response.status` `async_launched` with an
`agentId` and an `outputFile`. The reviewer's report reaches the main thread later, as a
hand-back message (the host's `SubagentHandback` tool) or in a `<task-notification>` naming
that id. Before this subsystem the delegate answered
`async_launched` with a foreground respawn, which came back async again, so no supported
command could consume the ticket and `--code-review-done`, `--self-review-fixed` and
`--chain-done` all refused.

**Three records, one claim.** `hooks/lib/review-consume-v1.js` owns
`<project root>/.zensu/state/review-consume-<scv1-key>/`:

- `launch-<agentId>.json` — written by `post-review-tdd-delegate.sh` on `async_launched`,
  AFTER the header, envelope and state-plane preflight that a completion runs, from the
  host's `tool_response.agentId`. The fields are the ticket and the validated envelope
  (`kind` standalone or bound, then run, attempt, chain, stage). Newest 32 per session.
- `stop-<agentId>.json` — written by `hooks/review-consume-subagent-stop.sh` on
  `SubagentStop` with `agent_type` `zensu:code-reviewer`, and only when a launch record for
  that `agent_id` exists. The hook binds through `bindAndDisclose` with automatic adoption,
  for the reason the evidence stop half gives: no adapter binds on `SubagentStop`. It prints
  nothing, exits 0 on every fault and never returns a decision, because a `SubagentStop`
  stdout decision would keep the reviewer running. It does not read
  `last_assistant_message` (see Decisions).
- `wait.json` — the Stop guard's release counter for the open ticket; it restarts only for a
  new ticket.

The claim is `zensu-log.sh --review-consume --ticket <ticket>`, which `exec`s the delegate in
its `--background-consume` mode. That mode binds through `zensu_bind_model_session`, reads the
launch and stop records (`lookup`), re-runs the same preflight with the recorded envelope,
claims through `tdd_consume_review_ticket_context` and renders the same directive as plain
text. Exit 3: no launch for the ticket. Exit 4: launched, not stopped. Exit 5: stale, consumed
or mismatched, from an `EXIT` trap that fires whenever the mode leaves before the claim.
Exit 6: the ticket was consumed but no directive was printed; it is the only exit after a
state change, and it names `--chain-status`.

**Decisions.**

- The claim stays in the main thread. A `SubagentStop` claim would advance the chain with no
  directive delivered, because `SubagentStop` output never reaches the parent, and the Stop
  guard's existing reason for a consumed, unconverged ticket restarts the review.
- `SubagentStop` is the completion evidence, not the notification or a transcript. The host
  fires it when the subagent finishes, and the review-evidence lease store already depends
  on it for workers the host launched in the background, keyed by the same agent id.
- The stop record neither carries nor requires the reviewer's report. Nine consume-reviewer
  transcripts of 2026-10-21 end on a `SubagentHandback` tool call whose `message` holds the
  report and whose result reads "Report delivered to your caller."; none ends on assistant
  text. On that host `last_assistant_message` carries no report, so requiring one would refuse
  every real review. A failed reviewer is routed before the claim instead: the launch
  directive, both Stop-guard reasons and the exit-4 refusal name a fresh `--review-ticket`
  when its notification reports a failure or a stop without a report. A fresh ticket only
  repeats a review, so this escape cannot skip one.
- After the claim, exit 0 must mean the directive was printed. The three `emit_post_context`
  call sites set `CONSUME_EMITTED` themselves, because the right side of a pipeline is a
  subshell, and the `EXIT` trap turns a consumed ticket without a printed directive into
  exit 6.
- The records live in `.zensu/state/`, beside the workflow document, so no workflow-state
  field and no Session Control schema changed, and the reviewer capability gate already
  denies reviewers every read below `.zensu`.
- The routing text stays in the delegate. Dozens of suite checks grep its source, two of them
  line-anchored, so the claim mode is a second entry into the same file, never a copy.
- The wait borrows the workflow wait's shape but counts per ticket: up to three releases for
  the open ticket, none charged to `stopBlockCount`, restarting only for a new ticket, and no
  wait for an owned Autopilot run, an Autopilot-bound chain, an adopted deferred review or a
  held deferred claim. Unlike the workflow wait it has no TTL and reads no `background_tasks`,
  which was not measured to list agents. Past the bound and after the stop, the block reason
  names the claim instead of the review restart.
- An unrecordable launch keeps the old foreground-respawn directive: it is still right on a
  host that honors `run_in_background: false`.

**Coupled sites.** The claim command is rendered in the delegate's `async_launched` branch,
the Stop guard's background branch, `NEXT_COMMAND['ticket-unclaimed']` in
`chain-recovery-v1.js`, `skills/recover-chain/SKILL.md` and step 5 of
`skills/tdd/references/review-chain.md`. That reference may not add a bare
`run_in_background`: R17-P12 counts every occurrence other than `run_in_background: false`.
`--tdd-begin` resets the directory through `zensu_review_consume reset`. The module and the
recorder sit in both protected-root lists of `hooks/lib/reviewer-capability-v1.js`, and
`review-consume-v1` is in `HELPER_RE` of `hooks/lib/subagent-shell-guard-v1.js`, so a neutral
subagent can neither read them nor run the module. `zensu_review_consume` loads the module
cwd-relative from `hooks/lib`, the first mechanism
`tests/structure/test-msys-special-plugin-module-boundaries.sh` accepts, and that canary
probes launch, stop and lookup from its special plugin root. Operator accounts:
the delegate, recorder and Stop rows of `docs/configuration.md` and §"Background reviewers" of
`docs/review-chain.md`.

**Known gaps.**

- A deliberate write into `.zensu/state/` can forge a stop record, as for every plugin store;
  the claim still needs the chain's open ticket and an intact generation.
- Whether `SubagentStop` fires for a reviewer killed with `TaskStop` was not measured. A
  reviewer that dies without one stays "running" until the wait bound is spent; the block
  reason then names a fresh ticket for a reviewer whose notification reported a failure.
- A stop that reaches the recorder before its launch record exists is dropped, and the claim
  then answers exit 4. That refusal names a fresh ticket once the notification says the
  reviewer finished.
- An Autopilot-bound chain never waits, so a Stop before the notification spends its budget.
- Windows is unmeasured; the module is loaded cwd-relative and takes its project root from
  `_tdd_native_project_path`.

**Version: `patch`.** No context-record or workflow-state field, no strict key set that an
older reader or writer holds (the record key sets ship for the first time here), no hook
removed or re-matched, and the added hook returns no decision and no output.
