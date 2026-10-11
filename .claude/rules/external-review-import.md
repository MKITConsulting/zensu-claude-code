---
paths:
  - "hooks/lib/external-review-v1.js"
  - "hooks/post-workflow-launch.sh"
  - "hooks/stop-chain-enforcer.sh"
  - "hooks/lib/zensu-log.sh"
  - "agents/review-judge.md"
  - "skills/tdd/SKILL.md"
  - "skills/tdd/references/review-chain.md"
  - "templates/workflows/zensu-review-v1.js"
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
- `check` — `zensu-log.sh --external-review --root <top> --result <output-file>`, strict bind,
  change set on stdin. Freshness comes first: a launch must be newer than the change time
  (`max(mtime, ctime)`) of every existing changed path and of the nearest existing parent of
  every missing one; `.zensu` paths are excluded and counted. Several fresh launches select the
  one whose `task_id` names the output file, else answer `unavailable reason=ambiguous-launch`
  until `--launch <id>` names one. Then `judgeResult` gates the result: no `--result` answers
  `unavailable reason=no-result`; a file that is not a task output (a `result` key and a
  `workflowProgress` array) or a `result` that `validateReviewResult` rejects answers
  `unavailable reason=foreign-shape`; an output file not named `<task_id>.output` answers
  `unavailable reason=result-not-from-launch`; a `tree` other than the one `computeTree` of
  `evidence-run-v1.js` computes now answers `stale reason=tree`, and with no computable tree the
  freshness check decides alone and the line says `tree=unverified`. The agent counts are
  compared with `journal.jsonl` in the recorded `transcript_dir` (per label, the outcome of its
  latest `started` record; no `result` or `failed` record means lost) or, when that is
  unreadable, with the task output's `workflowProgress`. A mismatch, a failed or lost agent, a
  `finder-failed` entry, a launch without a `task_id` or no readable runtime record answers
  `degraded`, which prints `EXTERNAL REVIEW DEGRADED — …` as its second line and one
  `gap <lens> finder-failed` line per failed finder, and still imports. `ok` and `degraded`
  print every finding in a `findings <id> begin`/`end` block and then the script block; both
  are fenced by a per-call random nonce, and every finding value is JSON-quoted, so no value
  can start a line of its own. `hooks.reviewJudge` off answers `off reason=review-judge-disabled`,
  a record dated beyond `clockSkewMs` is skipped, every fault answers `unavailable`, a module
  that fails to load included, and every answer but `ok` and `degraded` leaves the panel path
  unchanged.
- `tree` — `zensu-log.sh --external-review --tree --root <top>` prints `tree=<id>` from the same
  `computeTree` the import compares, or `tree=unavailable reason=<reason>`.
- The template — `templates/workflows/zensu-review-v1.js`, which the main thread launches
  through the Workflow `scriptPath`. It owns the `zensu-review-result/v1` shape, and
  `validateReviewResult` checks that shape with an exact key set at every level. Before
  anything else, `judgeResult` compares the launch record's `script_sha256` with the digest of
  `TEMPLATE_FILE` and answers `unavailable reason=foreign-script` on a mismatch, or
  `template-unreadable` when the file cannot be read: a model-written script can emit the same
  shape and still filter or relabel findings, so the shape alone does not prove the template
  ran. Under a token target the template starts refuters `REFUTER_WINDOW` (4) at a time and
  checks the budget before each one, because a check made when every refuter starts sees the
  budget before any of them spent it.
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
- Only a template result is imported. A model-authored review script counted dead verifiers
  as rejections and reported 22 of 34 findings as rejected with no vote cast, so the shape
  gate fails to the panel: an ad-hoc workflow costs a second review, never a silent pass.
- The main thread names the output file, and the module does not search for it: the task
  output lives in the host's temporary directory, whose layout is not documented. The file is
  bound by name to the recorded task id.
- The run journal, not the result, is the runtime truth for the agent counts, and per label
  only the latest start counts, because a resumed run starts a label again.
- The tree binding reuses `computeTree` of `evidence-run-v1.js`, the fingerprint the full-suite
  and acceptance gates already trust, so there is no second tree algorithm.
- A finding over the per-lens cap, the ceiling or the budget stays in the result as
  `unverified`: the limits bound what is verified, never what is reported.
- `task_id` and `transcript_dir` joined `RECORD_KEYS` before any release shipped the record
  format, so the strict key set changed with no reader in the field.

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
The result shape is spelled twice: the object the template returns and the `RESULT_*_KEYS`,
`DROPPED_KINDS`, `VERIFICATION_STATUSES` and `VOTE_OUTCOMES` the module validates. The unit file
runs the template in a sandbox and validates its output with the module, so a one-sided edit
fails there. The template's `args` are built in step 3 of `skills/tdd/references/review-chain.md`
and described in `docs/review-chain.md`; a renamed argument moves all three. The `degraded`
status lives in `STATUSES`, step 3's `On ok or degraded` and the docs. The output file reaches
the module as `ZENSU_XR_RESULT`, which is in the MSYS exclusions, and `zensu-host-path.sh`
converts only its directory. Four tests of the unit file sit in
`tests/profiles/clock-shift-allowlist.v1.json` with the `file-mtime` dependency: the wait
counter sweep and the restored-mtime freshness check compare kernel-set times with `Date.now()`.

**Known gaps.**

- The PostToolUse `Workflow` payload (`tool_input.script`, `scriptPath`, `name`, `args`) and the
  Stop `background_tasks` entry of a running workflow follow the Claude Code hook and workflow
  documentation; no live hook capture was taken. The `tool_response` fields the record keeps
  (`taskId`, `runId`, `transcriptDir`) were read from the `toolUseResult` of real launches in
  session transcripts, on the assumption that the hook receives the same object, and a text
  form is parsed as a fallback. The journal record kinds (`launched`, `started`, `result`,
  `failed`) and the task output keys were measured over 413 run journals and the surviving task
  outputs on one machine on 2026-10-10, not taken from documentation. A missing field degrades
  to no record, no wait or a degraded import, never to a block or a silent pass.
- Freshness compares launch time with change times. A filesystem with coarse timestamps can
  make an older review look fresh, and a changed directory entry (a submodule) is judged by
  the directory's own times; the judge is the backstop.
- The output file is named by the main thread. The name binding, the tree check and the
  journal comparison make a substituted or unfinished result fail; a deliberate shell write
  can still forge the files, as for every plugin store.
- The wait counter is per session. It resets when a Stop sees no running workflow, when
  `--tdd-begin` arms a new chain and after 24 hours; a chain armed some other way, such as a
  deferred-review adoption, inherits the count, but such a chain never waits.
- The recorder reads a `scriptPath` the main thread named (`O_NOFOLLOW`, at most 512 KiB).
- Windows is unmeasured: the suite is in `ciStructureTests` and in no blocking Windows shard.

**Version: `patch`.** No context-record or workflow-state field, no strict key set, no hook
removed or re-matched; the added hook returns no decision and no output, and the new key is
read permissively.
