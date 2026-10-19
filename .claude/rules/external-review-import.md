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
- `check` — `zensu-log.sh --external-review --root <top> [--result <output-file>] [--launch <id>]`,
  strict bind, change set on stdin. Freshness comes first: a launch must be newer than the change
  time (`max(mtime, ctime)`) of every existing changed path and of the nearest existing parent of
  every missing one; `.zensu` paths are excluded and counted. Several fresh launches select the
  one whose `task_id` names the output file, else answer `unavailable reason=ambiguous-launch`
  until `--launch <id>` names one. Then `judgeResult` gates the run. A recorded
  `script_sha256` that is not the digest of `TEMPLATE_FILE` answers `foreign-script`
  (`template-unreadable` when that file cannot be read), and an output file not named
  `<task_id>.output` answers `result-not-from-launch`. The result is read from the run record
  `<session>/workflows/<run_id>.json`, which `runRecordPath` derives from the recorded
  `transcript_dir` (`<session>/subagents/workflows/<run_id>`), never from the output file: no
  run id or transcript directory answers `launch-unbound`; an unreadable (a link included),
  oversized, unparseable or mismatching record (`runId`, and `taskId` when one was recorded)
  answers `run-record-unreadable`, `run-record-oversized`, `run-record-unparseable` or
  `run-record-mismatch`; a `status` other than `completed` answers `run-not-completed`; a
  recorded `script` other than the template answers `foreign-script`; a `result` that
  `validateReviewResult` rejects answers `foreign-shape`; a `tree` other than the one
  `computeTree` of `evidence-run-v1.js` computes now answers `stale reason=tree`, and with no
  computable tree the freshness check decides alone and the line says `tree=unverified`; run
  `args` without a `changedFiles` list answer `launch-args`, and a changed path that list
  lacks answers `files-not-reviewed`. All of these but `stale` are `unavailable`. The agent
  counts are compared with `journal.jsonl` in the recorded `transcript_dir` (per label, the
  outcome of its latest `started` record; no `result` or `failed` record means lost) or, when
  that is unreadable, with the run record's `workflowProgress` (per label, the highest
  `attempt`). A mismatch, a failed or lost agent, a `finder-failed` entry or no readable
  runtime record answers `degraded`, which prints `EXTERNAL REVIEW DEGRADED — …` as its second
  line and one `gap <lens> finder-failed` line per failed finder, and still imports. `ok` and
  `degraded` name the reviewed lenses on the first line (`lenses=`) and print every finding in
  a `findings <id> begin`/`end` block fenced by a per-call random nonce; every finding value is
  JSON-quoted, so no value can start a line of its own, and a finding that names a file but no
  line prints the anchor `-` and a `file` line. `hooks.reviewJudge` off answers
  `off reason=review-judge-disabled`, a record dated beyond `clockSkewMs` is skipped, every
  fault answers `unavailable`, a module that fails to load included, and every answer but `ok`
  and `degraded` leaves the panel path unchanged.
- `tree` — `zensu-log.sh --external-review --tree --root <top>` prints `tree=<id>` from the same
  `computeTree` the import compares, or `tree=unavailable reason=<reason>`. With the import or
  the judge off it answers `reason=disabled` or `reason=review-judge-disabled`, so the skill
  never launches a template whose result could not be imported.
- `stage` — `zensu-log.sh --external-review --stage --root <top>`, the launch preparation of
  step 3. It answers like `tree` while the import or the judge is off and for a root that does
  not hold the recorded project root, then needs a valid session key and a tree id. It reads
  `TEMPLATE_FILE` bounded, writes it as `stagedTemplateName` (`zensu-review-v1-<scv1-key>.js`)
  into `<recorded project root>/.zensu/state/` through the records' temp-then-rename writer
  (missing components created at `0700`; a link or a non-directory component answers
  `state-directory`), re-reads the copy with `O_NOFOLLOW` and compares its digest with the
  template's (`digest-mismatch`), and sweeps copies of other sessions idle past
  `idleSessionMs`. It prints `stage=ok tree=<id> script=<path>`, the path last because it may
  hold spaces, or `stage=unavailable reason=<reason>`. The gate is unchanged: the import compares
  the launch record's and the run record's script digest with `TEMPLATE_FILE`, so the copy is
  imported because its bytes are the template's, and an edited copy answers `foreign-script`.
- The template — `templates/workflows/zensu-review-v1.js`, which the main thread launches
  through the Workflow `scriptPath` from the copy `stage` writes. Its finders and refuters run as `zensu:review-aspect` (a
  refuter in the agent's verify mode, with a `VERIFY FINDING` block whose values are
  JSON-quoted), so the reviewer capability gate confines them like the panel and admits only
  their `StructuredOutput` result beside the read trio. `args.packet` carries the step-2c
  REVIEW PACKET v1, which must name its eight fields and every `changedFiles` entry, and a lens
  outside the agent's seven perspectives makes the template throw. It owns the
  `zensu-review-result/v1` shape, and
  `validateReviewResult` checks that shape with an exact key set at every level. Before
  anything else, `judgeResult` compares the launch record's `script_sha256` with the digest of
  `TEMPLATE_FILE` and answers `unavailable reason=foreign-script` on a mismatch, or
  `template-unreadable` when the file cannot be read: a model-written script can emit the same
  shape and still filter or relabel findings, so the shape alone does not prove the template
  ran. Under a token target the template starts refuters `REFUTER_WINDOW` (4) at a time and
  checks the budget before each one, because a check made when every refuter starts sees the
  budget before any of them spent it. It counts `over-cap` entries after the cross-lens dedup,
  because a capped finding that absorbs another lens's in-cap duplicate is refuted, and the
  refuter prompt JSON-quotes every value a finder wrote.
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
  the judge exactly as before. A first judge run that fails falls back to the full panel; the independent second run writes no gaps (`.claude/rules/cross-cutting-review.md`).
- An unknown or absent task status gets no wait, so the guard blocks: the status vocabulary
  was never captured, and a wait is the one relaxation of the chain guarantee.
- The wait bound has no environment override. A release that exits before the claim handoff
  would recreate the crashed-adopter state, hence the adoption and claim exclusions.
- Only a template result is imported. A model-authored review script counted dead verifiers
  as rejections and reported 22 of 34 findings as rejected with no vote cast, so the shape
  gate fails to the panel: an ad-hoc workflow costs a second review, never a silent pass.
- The result is read from the run record, never from the output file the main thread names.
  The launch response carries no output path, a named file is whatever the main thread wrote,
  and the run record also holds the script that ran and the arguments it ran with, so the import
  checks the executed script and the reviewed files against what the runtime wrote. The output
  file name only selects the launch.
- A run whose `changedFiles` argument leaves out a changed path answers `unavailable`, not
  `degraded`: it did not review this change, so the panel runs.
- No script block is printed. Only the template can be imported, so the block always repeated
  the same file; the judge receives the reviewed lenses instead.
- The template is launched from a plugin-staged copy inside the working directory. Measured on
  2026-10-14 in a Claude desktop session on 0.26.0 in auto mode: a `scriptPath` into the
  installed plugin root was refused with `scriptPath must be a script path this tool returned,
  or a file you can already read (the working directory or a directory you have added)`; the
  same launch was refused again after a full `Read` of that file; a byte-identical copy at
  `<working directory>/.zensu/state/` launched (zero agents, it failed on the missing `args`),
  and both its launch record and its run record carried the template digest. The copy `stage`
  writes launched the same way: `check` selected that launch by its task id, passed the launch
  record's digest comparison and answered `run-not-completed`, and the run record's `script`
  carried the template digest too. Reading first was
  rejected because the tool decides by directory, not by read history. The inline `script`
  input the refusal text suggests was rejected because a model would have to reproduce 15 KB
  byte for byte, and the gate fails on the first changed character. A user-added directory was
  rejected because the plugin cannot add one. The copy goes into the recorded project root,
  not `<top>`, because the recorded root is where the session started, and it carries the
  session key so that two sessions in one tree never launch each other's copy.
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
`skills/tdd/references/review-chain.md` steps 3, 4, 4b, 4c and 5, plus the `Subagent / Claude
Code Workflow safety` and `Work sequentially` bullets of `skills/tdd/SKILL.md`, whose body
`tests/structure/test-skill-text-budget.sh` bounds; step 4c defers an `EXT-<n>` finding kept
with the anchor `-` to `## Open` instead of neutralizing or routing it (`X26`).
`EXTERNAL REVIEW DEGRADED —` is carried into the CHAIN-END SUMMARY by
`COMBINED_SUMMARY_DIRECTIVE` in `hooks/post-review-tdd-delegate.sh`, `skills/self-review/SKILL.md`
§"Final report" and `docs/tdd-manager-workflow.md`; both literal loops of
`evals/config-gate/test-post-review-combined-summary.sh` require it. The run-record layout is
spelled in `runRecordPath` and `transcriptDirMatches`, the unit file's `workflowRun` and the
shell suite's `write_run_record`. `agents/review-judge.md` carries the `external_review` input and `## Gaps`
(`P2m`), `agents/code-reviewer.md` names `EXT-<n>`. Operator rows: the hook, flag and Stop rows
of `docs/configuration.md` and the Workflow paragraph of `docs/session-control.md`.
The result shape is spelled twice: the object the template returns and the `RESULT_*_KEYS`,
`DROPPED_KINDS`, `VERIFICATION_STATUSES` and `VOTE_OUTCOMES` the module validates. The unit file
runs the template in a sandbox and validates its output with the module, so a one-sided edit
fails there. The template's agent type and prompts move with the structured-result and
`## Verify mode` paragraphs of `agents/review-aspect.md` and with `WORKFLOW_RESULT_TOOL` in
`reviewer-capability-v1.js`. The template's `args` are built in step 3 of `skills/tdd/references/review-chain.md`
and described in `docs/review-chain.md`; a renamed argument moves all three. The staged copy's
location is spelled once, by `stagedTemplateName` over `core.WORKFLOW_STATE_SEGMENTS`. The
`--stage` recipe is named in step 3, the `Subagent / Claude Code Workflow safety` bullet of
`skills/tdd/SKILL.md`, `docs/review-chain.md`, the Workflow paragraph of
`docs/session-control.md` and the `externalReviewImport` row of `docs/configuration.md`; `X27`
pins the step-3 recipe and the `docs/review-chain.md` sentence, and `X7d`, `X9d` and `X10b`
drive the verb, whose copy `X7` and `X7b` then launch and import. The `degraded`
status lives in `STATUSES`, step 3's `On ok or degraded` and the docs. The output file reaches
the module as `ZENSU_XR_RESULT`, which is in the MSYS exclusions, and `zensu-host-path.sh`
converts only its directory. No test of the unit file is on
`tests/profiles/clock-shift-allowlist.v1.json`: every sweep test sets each mtime the sweep
reads from the clock the sweep is given, after the last write to that file, and the
restored-mtime freshness test injects launch times read from a file the kernel just stamped,
because no call can set a ctime. Both sides of each comparison stay on one clock when `Date`
is shifted.

**Known gaps.**

- The PostToolUse `Workflow` payload (`tool_input.script`, `scriptPath`, `name`, `args`) and the
  Stop `background_tasks` entry of a running workflow follow the Claude Code hook and workflow
  documentation; the one live capture is the launch of 2026-10-14 below, and the Stop entry
  was never captured. The `tool_response` fields the record keeps
  (`taskId`, `runId`, `transcriptDir`) were read from the `toolUseResult` of real launches in
  session transcripts, on the assumption that the hook receives the same object, and a text
  form is parsed as a fallback. The journal record kinds (`launched`, `started`, `result`,
  `failed`) were measured over 413 run journals on one machine on 2026-10-10, and the run record
  keys (`runId`, `taskId`, `status`, `script`, `args`, `result`, `workflowProgress`) were read
  from real run records on 2026-10-11, among them a template run launched through `scriptPath`
  whose recorded `script` had the template file's digest; none is documented. A missing field
  degrades to no record, no wait, or an unavailable or degraded import, never to a block or a
  silent pass.
- Freshness compares launch time with change times. A filesystem with coarse timestamps can
  make an older review look fresh, and a changed directory entry (a submodule) is judged by
  the directory's own times; the judge is the backstop.
- The run record and the journal sit in the session's project directory, which the main
  thread can write: a deliberate write there can still forge a result, as for every plugin
  store, and a count that disagrees with the journal only degrades the import.
- The confinement of the template's agents rests on `StructuredOutput` doing nothing but
  hand data to the workflow script: a host that gave that tool a side effect would widen every
  reviewer inside a workflow (`.claude/rules/reviewer-capability-gate.md`).
- The wait counter is per session. It resets when a Stop sees no running workflow, when
  `--tdd-begin` arms a new chain and after 24 hours; a chain armed some other way, such as a
  deferred-review adoption, inherits the count, but such a chain never waits.
- The recorder reads a `scriptPath` the main thread named (`O_NOFOLLOW`, at most 512 KiB) only
  when `tool_input` carries no `script`. The measured `scriptPath` launch of 2026-10-14 reached
  the shipped hook with the loaded text in `tool_input.script`: its record said
  `source: script`, and its digest, `run_id`, `task_id` and `transcript_dir` matched the run
  record, which also names the `scriptPath`.
- The copy launches only where the recorded project root lies inside a directory the Workflow
  tool accepts, which by its refusal text is the working directory or one the user added. A
  session started in a subdirectory records that subdirectory, so its copy lands inside its
  working directory. A session re-anchored to a sibling worktree records a root outside it, so
  its copy would be refused, and step 3 then runs the panel at the cost of the Workflow review.
  Only a session whose working directory was its recorded root was measured; the other two
  cases are derived from the refusal text.
- The copy lives in `.zensu/state/`, which the session can write, and the Workflow tool's
  launch answer invites editing the script file it names. An edit between the stage and the
  launch answers `foreign-script` and costs the Workflow review, never a silent pass; step 3
  forbids the edit and the next `--stage` overwrites it.
- The tree fingerprint and the freshness check exclude `.zensu`, so the copy moves neither the
  tree id nor a freshness verdict. A consuming repository that does not ignore `.zensu/` sees
  the copy as an untracked file.
- Windows is unmeasured: the suite is in `ciStructureTests` and in no blocking Windows shard,
  and no staged copy was launched on Windows.

**Version: `patch`.** No context-record or workflow-state field, no hook removed or
re-matched, and the added hook returns no decision and no output. `RECORD_KEYS` and the
`RESULT_*_KEYS` are strict key sets, but both ship for the first time here, so no released
reader or writer predates them; a later change to either is a `minor`. The new config key is
read permissively. The `stage` mode is a `patch` on the same walk: a new mode of an existing
`zensu-log.sh` verb that writes one file per session into `.zensu/state/`, with no hook,
matcher, schema field, key set or attestation change.
