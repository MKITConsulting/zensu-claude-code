---
paths:
  - "hooks/lib/external-review-v1.js"
  - "hooks/post-workflow-launch.sh"
  - "hooks/stop-chain-enforcer.sh"
  - "hooks/lib/zensu-log.sh"
  - "agents/review-judge.md"
  - "skills/tdd/SKILL.md"
  - "tests/structure/external-review-v1.test.js"
  - "tests/structure/test-external-review-hook.sh"
---

# External Review Import (`hooks/lib/external-review-v1.js` + `post-workflow-launch.sh`)

When a Claude Code workflow (an Ultracode review, for example) already reviewed the change,
the first `/zensu:tdd` review imports it instead of running the aspect panel, and the judge
names what it left uncovered. Zensu reacts to what ran; it never starts, steers or interrupts
a workflow, and no code reads an Ultracode or effort signal. The operator account is
`docs/review-chain.md` §"Ultracode and external reviews".

**Three parts, one store.** `external-review-v1.js` owns `<CLAUDE_PLUGIN_DATA>/external-review/v1/`:

- `record` — `hooks/post-workflow-launch.sh` on PostToolUse `Workflow`. Main thread only
  (`classifyPreToolPayload`), one file per launch under `records/<scv1-key>/`, temp file then
  rename at `0600`, newest 64 per session, idle sessions swept after 14 days. It prints
  nothing and exits 0 on every fault, so it can never return a decision.
- `check` — `zensu-log.sh --external-review --root <top>`, strict bind, change set on stdin.
  `ok` only when exactly one launch is newer than the change time (`max(mtime, ctime)`) of
  every existing changed path and of the nearest existing parent of every missing one;
  `.zensu` paths are excluded and counted. Several fresh launches answer
  `unavailable reason=ambiguous-launch` until `--launch <id>` names one, and the `ok` line names
  the launch it selected (`selected=<name>@<time> id=<id>`), `hooks.reviewJudge`
  off answers `off reason=review-judge-disabled`, and a record dated beyond `clockSkewMs` is
  skipped. Every fault answers `unavailable`, a module that fails to load included, and every
  answer but `ok` leaves the panel path unchanged. The script block is fenced by a per-call
  random nonce, so a recorded script cannot forge its own end line.
- `stop-wait` — the Stop hook's `external_review_workflow_wait`. It releases a standalone
  chain's Stop at review round 0 while `background_tasks` lists a `workflow` entry whose status
  is in `RUNNING_TASK_STATUSES`, before the inner budget increment, after `outer_finish`, at
  most `LIMITS.maxWaits` (3) times in a row; after that every Stop blocks until one sees no
  running workflow, which deletes the counter, and `--tdd-begin` deletes it for every new chain
  generation. A chain whose workflows end and start again therefore waits again. A session that owns a live Autopilot run (`OUTER_PRESENT`), an Autopilot-bound
  chain (`INNER_BOUND_RUN`), a Stop that adopted a deferred review and a project holding a
  deferred claim never wait; all four exclusions sit inside the function. The counter is
  `waits/<scv1-key>.json` in the store, swept after 24 hours, so no workflow-state field was
  added.

**Decisions.**

- The change set comes from the model on stdin (the step-2 enumeration), as for
  `persona-activation.js` and `aspect-activation-v1.js`. A print mode in
  `zensu-edit-landing.sh` was planned and dropped: it would add a third copy of the git
  environment scrub that `X10e` keeps in step between two files, and the freshness set should
  be the set the reviewers see.
- The config flag is read through `zensu_hook_enabled` in all three shells. A JS port of
  `cfg()` was rejected: two readers of one key drift.
- The recorder is PostToolUse, not PreToolUse: a refused launch never reaches PostToolUse.
- A per-Read tracer over workflow agents was rejected: it credits reads that were not
  reviews, adds a hook run to every Ultracode agent call, and may see nothing when agents
  receive the diff in their prompt.
- The judge is the gap detector because it already re-reads every changed file fresh. The
  `## Gaps` section exists only with an `external_review` input, so the panel path renders
  the judge exactly as before. A judge that fails falls back to the full panel.
- An unknown or absent task status gets no wait, so the guard blocks: the status vocabulary
  was never captured, and a wait is the one relaxation of the chain guarantee.
- The wait bound has no environment override. A release that exits before the claim handoff
  would recreate the crashed-adopter state, hence the adoption and claim exclusions.

**Coupled sites.** The wait-file layout is spelled four times: `waitLocations`, `clearWait`
and `sweepStaleWaits` in the module and `zensu_external_review_wait_file` in `zensu-tdd-phase.sh`, which
the Stop hook's prefilter miss and `zensu-log.sh --tdd-begin` call through
`zensu_external_review_wait_reset`; `X14` drives the limit and the reset, `X25` the reset at
`--tdd-begin`, `X20`-`X23` the round, Autopilot and deferred-review exclusions, and `X24` the
bound-chain exclusion by running the shipped function with stubbed collaborators. The resume reason names the panel and the import path (`X12`). The store is in both
protected-root lists of `reviewer-capability-v1.js` (`X1a`). The Phase 6.10 text lives in
`skills/tdd/SKILL.md` steps 3, 4, 4b, 4c and 5 plus the `Subagent / Claude Code Workflow
safety` and `Work sequentially` bullets; the file is at its 433-line cap, so edits fold into
existing lines; step 4c defers an `EXT-<n>` finding kept with the anchor `-` to `## Open`
instead of neutralizing or routing it (`X26`). `agents/review-judge.md` carries the `external_review` input and `## Gaps`
(`P2m`), `agents/code-reviewer.md` names `EXT-<n>`. Operator rows: the hook, flag and Stop rows
of `docs/configuration.md` and the Workflow paragraph of `docs/session-control.md`.

**Known gaps.**

- The PostToolUse `Workflow` payload (`tool_input.script`, `scriptPath`, `name`, `args`; the run
  id inside `tool_response`) and the Stop `background_tasks` entry of a running workflow follow
  the Claude Code hook and workflow documentation; no live capture was taken. A missing field
  degrades to no record or no wait, never to a block.
- Freshness compares launch time with change times. A filesystem with coarse timestamps can
  make an older review look fresh, and a changed directory entry (a submodule) is judged by
  the directory's own times; the judge is the backstop.
- The record proves a launch, not what was reviewed or whether the workflow finished. The
  skill requires the finished result before an import; nothing enforces it.
- The wait counter is per session. It resets when a Stop sees no running workflow, when
  `--tdd-begin` arms a new chain and after 24 hours; a chain armed some other way, such as a
  deferred-review adoption, inherits the count, but such a chain never waits.
- The recorder reads a `scriptPath` the main thread named (`O_NOFOLLOW`, at most 512 KiB).
- Windows is unmeasured: the suite is in `ciStructureTests` and in no blocking Windows shard.

**Version: `patch`.** No context-record or workflow-state field, no strict key set, no hook
removed or re-matched; the added hook returns no decision and no output, and the new key is
read permissively.
