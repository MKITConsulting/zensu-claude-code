# Review Chain

The agents that review your code, how a repo extends them, and the artifact
skeletons they anchor on.

### Agents (6)

| Agent | Role | How It Works |
|-------|------|--------------|
| **zensu-plm** | Read-only planning analyst | Explains and decomposes Zensu lifecycle work. It receives neutral context but exposes only `Read`, `Grep`, and `Glob`; the matching skill performs mutations in the interactive main thread. |
| **code-reviewer** | Quality Review | Consolidates the review. Standalone: walks 5 specialist perspectives (conventions, bugs, architecture, tests, security) in a single READ-ONLY agent. In the `/zensu:build` chain: runs in **fan-out consume mode**, emitting the report the main thread merged from the parallel `review-aspect` panel — three perspectives by default, five with `hooks.reviewPanel: full` (no re-read, no build/test). |
| **review-aspect** | Single-Perspective Review | READ-ONLY reviewer scoped to ONE perspective. The `/zensu:build` chain spawns one per perspective of the panel in a single parallel batch — `correctness`, `design` and `security` by default (`hooks.reviewPanel: lean`, whose fix-round re-reviews spawn `correctness` alone), or `conventions`, `bugs`, `architecture`, `tests` and `security` with `hooks.reviewPanel: full` — then merges their findings in the main thread. Runs zero build/test commands — the suite already ran in the Phase 6 audit. |
| **review-judge** | Independent Second Pass | READ-ONLY judge spawned AFTER the aspect merge (gated by `hooks.reviewJudge`, default on; on the lean panel for the first review only, and on any review the Stop hook resumes). Re-reads the changed files fresh and covers the panel's structural blind spots: cross-cutting integration, requirement drift against the plan's stable AC-###/FR-### IDs, missed edge cases, and panel quality — a false-positive panel finding gets a `Panel-FP:` meta-verdict that the main thread neutralizes before fix routing. It also traces every guarantee a query or call inherits from session or connection state (row-level security, a tenant setting, the connecting role) through each connection mode the code still supports, and reports a defect such a mode reaches with its condition, even when committed configuration disables the mode, which may lower the severity by one level but never below IMPORTANT. On the first review it runs twice, independently and side by side (`hooks.reviewJudgeSecondRun`, default on): the second run reads what the changed files depend on before the files themselves and only adds `JUDGE-B<n>` findings, which the main thread merges as a union. Emits `JUDGE-*` deltas; never repeats panel findings, never runs build/test. |
| **plan-review-worker** | Confined plan validator | Dedicated `/zensu:plan-review` worker with only `Read`, `Grep`, and `Glob`. It reads a private, immutable evidence lease and returns one raw `kind:"plan-review"` JSON object as its final message; only the main thread validates and materializes that result. |
| **pr-review-worker** | Confined PR persona | Dedicated `/zensu:pr-team-review` worker with only `Read`, `Grep`, and `Glob`. It reviews a leased role/area evidence shard and returns one raw `kind:"pr-review"` JSON object; it cannot write files, mutate tasks, message agents, spawn agents, run commands, or publish. |

The built-in reviewer boundary uses each agent's exact
`tools: Read, Grep, Glob` allowlist. There is no shell or Git exception and no
control/agent tool. The first all-tool `PreToolUse` hook is the fail-closed
enforcement point: it revalidates the immutable Session Control context on every
tool call, recognizes Claude Code's plugin-scoped `zensu:code-reviewer`,
`zensu:review-aspect`, `zensu:review-judge`, `zensu:plan-review-worker`, and
`zensu:pr-review-worker` identities (the exact bare `--agents` names of the
three reviewers only under the evaluation opt-in
`ZENSU_SESSION_CONTROL_EVAL_BARE_IDENTITIES=1`), then repeats the exact
three-tool reviewer allowlist. The
plugin-scoped `zensu:zensu-plm` receives the same strict allowlist. The three
reviewers and the PLM may additionally call the host's `SubagentHandback` report
tool, with exactly one string `message` field, because Claude Code in `auto`
mode delivers a subagent's report only through that call; the two workers do
not, since their result is read from `SubagentStop` (see
[Session Control](session-control.md)). Inside a Claude Code workflow the same
reviewers and the PLM may also call `StructuredOutput`, through which a workflow
agent returns the result its script asked for; it carries data to that script and
nothing else. Every other
neutral `host-profile-v1` child may use every tool except what reaches Zensu's
own state or runs commands outside `Bash` (listed in
[Configuration](configuration.md)). It cannot invoke `shell`, `exec`,
`exec_command`, `terminal`, `command`, `PowerShell`, a `Monitor` command or a
tool whose name marks it as running commands, and a tool whose inputs the gate
does not know may not name Zensu's state in its input. It runs `Bash` only when
it reports an `agent_type`, is neither a read-only Zensu agent nor a
`zensu-review-*` persona, and `hooks.subagentShell` is not `false`; every such
command is checked by an accident guard that prevents accidents and is
not a sandbox.

The two review-worker identities add a private evidence lease on top of that
three-tool profile. The interactive main thread creates one immutable generation
containing exact files and narrow search roots, records each host worker id, and
never exposes the lease id or plugin-data path to the worker. Each tool call
revalidates canonical paths, symlink/path identity, and the creation snapshot so
TOCTOU replacement fails closed. PR leases also bind the exact
`core.quotePath=false` name-status manifest; ambiguous quoted/backslash paths and
findings outside that changed-path set fail closed. `SubagentStop` captures the
worker's one raw JSON result; collection requires the exact worker id, result
kind, and role.
Only then may the main thread write a debug JSON file, and it closes the lease on
success and failure. Repository instructions, diffs, source text, overlays, and
refinement context remain untrusted data and cannot widen this contract.

> **Implementation is no longer delegated to an agent.** Since 0.4.0 `/zensu:build` runs in the **main thread** — vanilla by default, with strict RED→GREEN available when configured — because the old `tdd-manager` subagent lost too much implementation context. Since 0.6.0 the review chain fans out to parallel `review-aspect` subagents (three on the default lean panel since 0.24.0, five with `hooks.reviewPanel: full`), optionally runs `review-judge`, and consolidates through one consume-mode `code-reviewer`, while preserving the round counter, auto-fix loop, and self-review terminus. Since 0.21.0 the loop no longer re-reviews the whole diff on every round: `hooks.incrementalReviewRounds` (default on) narrows rounds 2..N to that round's own delta while the judge keeps the full cumulative diff, and `hooks.aspectActivation` (default on) drops the perspectives a change set cannot implicate. Both fail open to the previous behavior — see [configuration.md](configuration.md) for the exact bounds and known gaps. `hooks.reviewConvergence` (default on) then bounds the loop itself: every merged finding is recorded in a findings ledger (`FINDING LEDGER` run-log lines read by `hooks/lib/review-ledger-v1.js`), the judge receives that ledger, and every re-review routes only CRITICAL findings plus the IMPORTANT findings the judge raised, tagged `[NOT FIXED]` or cited on code the previous fix pass edited (every IMPORTANT finding when `hooks.selfReview` is off), deferring the rest to the terminal self-review and the `## Open` table. The terminal self-review also verifies every active acceptance criterion again through `/zensu:verify-feature --chain` when the review rounds made the acceptance records stale, because the terminus refuses a criterion verified on an older tree ([Acceptance Verification Gate](gates.md#acceptance-verification-gate)). Every reviewer of a round reads one canonical `REVIEW PACKET v1` that `hooks/lib/review-packet-v1.js create` prints, a round's delta or a judge gap travels on a `review_scope:` line outside it, and the consume-mode review claims its ticket only when the packet, the tree and the edit-landing receipt still match and, where step 4b runs it, a primary judge run returned a substantive report; a second judge run never stands in for it ([Review Packet Gate](gates.md#review-packet-gate)). All three reviewer agents rate severity on the shared scale in [review-severity.md](review-severity.md).

#### Ultracode and external reviews

Claude Code's workflows (the `Workflow` tool) can review a change on their own, for example
when Ultracode is on. Zensu never starts, steers or interrupts a workflow, and no part of it
reads an Ultracode or effort setting. It reacts to what demonstrably ran:

- **Launch record.** A `PostToolUse` hook on the `Workflow` tool
  (`hooks/post-workflow-launch.sh`) records every workflow the main thread launched: the
  time, the workflow name, a digest and a bounded copy of the script (64 KiB), the arguments
  (8 KiB), and the run id, the task id and the run's transcript directory when the tool result
  names them. Records live in the plugin's
  private data store under `external-review/v1/`, one file per launch at mode `0600`, at
  most 64 per session; idle sessions are swept after 14 days and wait counters after 24 hours. `PostToolUse` runs only
  after a tool call succeeded, so a launch a permission rule or hook refused leaves no
  record, and a subagent's launch is never recorded. The hook prints nothing and exits 0 on
  every fault.
- **The review template.** A workflow review is imported only when it ran
  `templates/workflows/zensu-review-v1.js`, the plugin's own review script. A real review on
  a private repository showed why: its model-authored script launched 116 agents and
  reported 22 of its 34 findings as rejected although no verifier had voted on them, because
  it counted a dead verifier as a no. The Workflow tool loads a `scriptPath` only from the
  session's working directory or a directory the user added, so it refuses the template inside
  the plugin's install directory. The main thread therefore runs
  `zensu-log.sh --external-review --stage --root <top>`, which copies the template into the
  session's `.zensu/state/` under the session key, verifies the copy's digest and prints the
  tree id and the copy's path, and launches that copy through the Workflow `scriptPath`. The
  import compares digests, not paths: it answers `unavailable reason=foreign-script` for a
  launch whose script is not the template byte for byte, so an edited script is never
  imported. Its `args` carry the tree id that `--stage` prints, the lenses (the active panel's
  perspectives plus `tests`), the changed files, the REVIEW PACKET v1 the panel would receive,
  an agent ceiling (default 10), a per-lens cap (default 8) and the known deferred findings.
  Its finders and refuters run as `zensu:review-aspect`, so the capability gate confines them
  to `reviewer-readonly-v1` exactly like the panel: they read the project and return their
  result through the workflow's `StructuredOutput` tool, and every other tool is denied. A
  refuter is the same agent in its verify mode, with a `VERIFY FINDING` block after the packet
  whose values are JSON-quoted. The template runs one finder per lens, deduplicates across
  lenses in plain code (the same file within
  three lines and similar titles; it keeps the higher severity and lists the merged ids), and
  spawns at most one refuter per CRITICAL or IMPORTANT finding, CRITICAL first, within the
  ceiling. A SUGGESTION gets no verifier. It never filters a failed agent out: a failed finder
  lists its lens as `finder-failed`, a failed refuter leaves its finding `unverified`, and a
  finding over the cap, the ceiling or the token budget stays in the result as `unverified`
  with its reason and is counted under `dropped`. Under a token target it starts refuters four
  at a time and checks the budget before each one, CRITICAL first. It has no synthesis agent, because the
  chain's merge and judge do that work. It always returns `zensu-review-result/v1`: the tree,
  the lenses, the ceiling, the agent counts, the `dropped` list and every finding with its
  verification state (`upheld`, `refuted` or `unverified`) and votes.
- **Import on the first review.** In `/zensu:build` Phase 6.10 step 3, with `hooks.reviewJudge`
  on, the main thread pipes the review's change set into
  `zensu-log.sh --external-review --root <top> --result <output-file>`, where the output file
  is the one the workflow's completion notification names. The file name only selects the
  launch: the result is read from the run record the workflow runtime wrote for the launch's
  run id, beside its transcript directory, never from a file the main thread names. It answers
  `status=ok` only when five things hold. First, a recorded launch is newer than the change
  time (the later of modification and status-change time) of every changed file that still
  exists and of the nearest existing parent of every changed path that no longer does (the
  plugin's own `.zensu` files excluded). Second, the run completed, and the script it ran is
  the shipped template byte for byte. Third, the result parses as `zensu-review-result/v1`.
  Fourth, the result names the current tree. Fifth, the run's `changedFiles` argument names
  every changed path. A result of any other shape, an ad-hoc workflow's included, answers
  `status=unavailable reason=foreign-shape`, so such a review costs a second review instead of
  passing silently. A result for another tree answers `status=stale reason=tree`; when no tree
  can be computed, the change-time check decides alone and the line says `tree=unverified`. A
  run that has not completed answers `status=unavailable reason=run-not-completed`, and a run
  whose arguments left a changed path out `reason=files-not-reviewed`. The `--root` of both
  calls must be the root of the session's work tree: the top level `git rev-parse
  --show-toplevel` prints for the project root, or the project root itself when it lies outside
  git. Any other root answers `status=unavailable reason=root layout=<layout>` (with `--stage`
  or `--tree`, `stage=unavailable` or `tree=unavailable` in its place, and no copy is written)
  followed by what the layout is and the next
  step: `nested-work-tree` for a separate work tree nested inside the session's own, such as a
  worktree of another repository, `nested-in-folder` for a repository inside a project folder
  that is not a git work tree, `outside` for a sibling, `enclosing` for a directory above the
  work tree, `subdirectory` for one below its top level, `unresolved-root` or
  `unresolved-project-root` for a path that is missing, is not a directory or ends in a symbolic
  link (`zensu-log.sh` resolves symbolic links in the path's ancestors first), and
  `undetermined` when git cannot answer. A chain reviews one root, so for the first three the
  aspect panel reviews this change, and a workflow review of the other work tree imports only in
  a session started in it. `enclosing`, `subdirectory` and `unresolved-root` ask for a re-run
  with that root, `unresolved-project-root` points at `/zensu:doctor`, and `undetermined` names
  git's fault in `detail=`: for the review root it asks for the same re-run, because only that
  root imports whatever the fault hid, and for the project root it asks for the fault to be
  fixed first. The first line names
  the lenses the run reviewed (`lenses=`), which the judge receives. The import then compares
  the result's agent counts with the run journal the workflow runtime wrote (`journal.jsonl`
  in the launch's transcript directory, where only the outcome of each label's latest start
  counts), or with the run record's own progress list when the journal cannot be read. A
  failed, lost or miscounted agent, a failed finder, or a runtime record that cannot be read
  answers `status=degraded`. A degraded result is still imported, because its findings are real data:
  the line `EXTERNAL REVIEW DEGRADED — <failed> of <started> agents failed; <reasons>` goes
  into the run log and the CHAIN-END SUMMARY, and each `finder-failed` lens gets one targeted
  `zensu:review-aspect`, or a `REVIEW GAP` line when the lens is no panel perspective. When
  several launches are fresh, the import selects the one whose task id names the output file;
  otherwise it answers `status=unavailable reason=ambiguous-launch` until `--launch <id>`
  names one. With `hooks.reviewJudge` off it answers `status=off`, because only the judge
  names the gaps. Every other answer (`none`, `stale`, `off`, `unavailable`) leaves the panel
  exactly as before. On `ok` or `degraded` the main thread skips the aspect panel, logs
  `PANEL SKIPPED — external review <name> imported`, and merges every printed finding as
  `EXT-<n>`. None is dropped and none is labelled rejected: a refuted or unverified finding is
  merged with its verification state and the refuter's reasoning in its evidence, and the
  Finding Verification Gate grades every one. A severity may be raised but never lowered, and
  a finding without a `file:line` anchor keeps the anchor `-` and is deferred to `## Open`,
  because nothing can grade it.
- **The judge names the gaps.** On the import path `zensu:review-judge` always runs. It
  receives the lenses the run reviewed as data, reads every changed file fresh, and ends its report
  with a `## Gaps` section naming each file and panel perspective the external review did not
  cover. Each gap line gets exactly one targeted `zensu:review-aspect` over the gap files. A
  first judge run that fails, or answers without a parseable `## Gaps` section, means no coverage
  check ran: the main thread logs `REVIEW GAP UNAVAILABLE`, spawns the full panel and then runs
  the panel path's judge over its merge, which is the one retry the primary judge gets.
  While `hooks.reviewJudgeSecondRun` is on, the judge's independent second run beside it adds
  findings but never gaps, and its failure only logs `JUDGE SECOND RUN UNAVAILABLE`.
- **Everything after the merge is unchanged.** The Finding Verification Gate, the review
  ticket, the counted consume-mode round, the fix loop, the self-review terminus and the
  full-suite and acceptance gates run as for a panel review. A re-review never imports.
- **The Stop guard waits for a running workflow.** When the review chain still awaits its
  first review and the Stop input's `background_tasks` lists a workflow whose status reads as
  running, the guard releases that `Stop` without charging the review budget and says so on
  stderr, at most three times in a row: after the third release every `Stop` blocks until one
  sees no running workflow, which restarts the count, and arming a new chain with
  `--tdd-begin` restarts it too. A session that owns a live Autopilot run, a chain
  that adopted or holds a deferred review, a fix round, a converged chain, an Autopilot-bound
  chain and a refused reviewer spawn never wait.

`hooks.externalReviewImport` (default `true`) switches the record, the import and the wait
off; the chain then reviews exactly as before.

**Residuals.** A thin external review is backstopped by the judge, not by the full panel.
Freshness compares the launch time with file change times, so a filesystem with coarse
timestamps can make an older review look fresh, and a changed directory entry (a submodule)
is judged by the directory's own times; the judge's fresh reads remain the backstop. The
running statuses the wait accepts (`running`, `pending`, `queued`, `in_progress`,
`in-progress`, `starting`, `started`, `active`) were not captured from a live host, and any
other status gets no wait, so the guard blocks. The launch result fields the record keeps (the
run id, the task id and the transcript directory), the run record and the run journal follow
what real workflow runs wrote to disk, not a documented format, and a missing field makes the
import unavailable or degraded instead of passing it. The import never reads a file the main
thread names, but the run record and the journal sit in the session's own project directory,
which the main thread can write: a deliberate write there can still forge a result, as for
every plugin store, and a count that disagrees with the journal only degrades the import.

#### Fix-round bookkeeping

A routed fix round prepares its re-review with one call,
`zensu-log.sh --round-prepare --round <n> --log <run log>`, after it logged its
`R<n>-<step> IMPL completed — files:` claims. Step 10.2 runs `--round 0` once before the first
fan-out, and `/zensu:self-review` runs `--round self-review` for its one fix round. Every call of
a chain passes the `--baseline` its round-0 call passed. The verb:

- runs the Phase 6 step 5b edit-landing audit under the round's start marker;
- judges every claim of the round against a content snapshot taken when the round began, so a
  file that was already uncommitted before the round counts as landed only when this round
  changed it, and a claim whose file did not change stops the round with exit 1;
- appends a `fixed` ledger line for each open finding a landed claim names by its label
  (`R<n>-F<k>`, `R<n>-R<j>-F<k>` for an earlier finding, `SR-R<j>-F<k>` in the self-review, and
  the `G<g>:` form of an entry carried from an earlier generation, such as `SR-G1:R<j>-F<k>`);
- prints the panel's `changed_files` (the round's own delta while
  `hooks.incrementalReviewRounds` is on and the delta is established, the whole diff
  otherwise), the judge's full `judge_changed_files`, the aspects to spawn, the open ledger
  entries and the path of a round diff, and logs every skipped aspect. A
  `changed_files (round-delta):` line goes on the `review_scope:` line after each aspect's
  canonical `REVIEW PACKET v1`, and any other reason means no `review_scope:` line; the packet
  itself keeps the full cumulative change set `review-packet-v1.js create` renders, for the
  judge as for every aspect.

Exit 0 means the round is prepared. Exit 1 means a claim of this round did not land in this
round: no `fixed` line is written, and the same round runs again once the claim is landed or
withdrawn. Exit 2 is a refused argument or a failed step. A refused argument prints its usage
error on stderr and changes nothing. A failed step prints `ROUND PREPARE STOPPED — <step>: <cause>`
and then a `ROUND PREPARE FALLBACK` line for the case the verb cannot run at all, outside git or
without node: run the step 5b audit yourself,
append each `fixed` line after re-reading its fix, and give the re-review the whole diff. An
audit that graded the claims but could not write its receipt is such a stop: the verb attributes
no claim, writes no `fixed` line and keeps the snapshot, so the round runs again once the cause
its `RECEIPT REFUSED` line names is fixed.

Without a usable round-start snapshot the round is reported as unattributable and no `fixed`
line is written, because the verb cannot tell this round's edits from earlier ones. A snapshot is
usable only for the run log, the review generation and the `--baseline` that recorded it:
another chain's snapshot, one recorded before a `REVIEW BUDGET RESET`, or one taken with another
`--baseline` is refused, so the first fix round after a reset is unattributable. The self-review
round starts from the snapshot of the chain's last fix round as the run log shows it, never from
an older one. A claim also stays unresolved when its file's digest names no content (a directory,
or a file over the size bound or past the hash bound), when it names a new file and the snapshot
was cut at its record bound, or when two labels of the round claim the same changed file. A label
claimed both before and after the last reset is judged by the files it claimed after it: a
verdict for a file it claimed only before the reset belongs to the earlier claim, and one that
names no file stays unresolved. The verb lists unresolved labels under `unresolved_claims`, and a
`fixed` line for one is written by hand only after its fix was re-read.

The verb reads claims with the audit's own grammar: a label of at most five words before the
`IMPL completed — files:` or `WIRED — files:` marker, written with any of the three dashes, and a
file the run-log writer spelled `<project>/…` counts as the same file. Round 0 logs
`ROUND PREPARE — round 0 recorded the round-start snapshot`, which marks where round 1 begins. A
claim logged since the round began without the round's prefix (`R<n>-` or `SR-`) is listed under
`unprefixed_claims`, because no `fixed` line can name its finding.

A claim that cannot land is withdrawn by logging `CLAIM WITHDRAWN — <label>: <file>` after it, or
`CLAIM WITHDRAWN — <label>` for all of its files, which is the only form for a claim the audit
lists with no file. The round then passes, the claim gets no `fixed` line and its finding stays
open. A claimed file restored to its committed content in the round counts as landed, although
the audit reports `EDIT NOT LANDED` for it. The verdict lines of earlier claims, the audit tally,
one `ROUND LANDING` line per claim and any `ROUND LEDGER UNAVAILABLE` line go to the run log and
to the caller.

The verb reads the ledger the way `/zensu:self-review` does. A `partial` read writes `fixed`
lines only for the entries it could read and says so in a `ledger_note:` line, and a ledger that
cannot be read prints `ROUND LEDGER UNAVAILABLE` and writes no `fixed` line. With
`hooks.reviewConvergence` off the verb reads no ledger and prints
`open_ledger: off (hooks.reviewConvergence is off); no fixed line was written` in every fix round,
so `fixed: none` never reads as a ledger that was consulted.

The packet lists and the round diff leave out every path inside a `.zensu` directory, at any
depth, and every changed path that only your own global git excludes file ignores
(`core.excludesFile`, by default `~/.config/git/ignore`); a `user_ignored:` line counts the
second kind. The edit-landing audit grades claims without that file, so the snapshot in
`.zensu/state/` still records a sha256 digest of such a path.

A changed file is evidence that an edit happened, not that a finding is fixed. Only
`hooks.reviewPanel: full` re-checks a `fixed` entry, through the judge's `[NOT FIXED]` tag: the
lean panel's re-review reads the edit but not the ledger, and `/zensu:self-review` takes no
`fixed` entry as a candidate. A `fixed` line written for an edit that missed its finding therefore
stays closed unless a later review raises the defect again.

#### Background review agents

A host may start every `Agent` spawn in the background: the Claude desktop app does, and its
Agent tool offers no `run_in_background` parameter. Every review agent of the chain then answers
`async_launched`, and no report exists yet when the post-review hook runs.

- **Launch.** The post-review hook records each launch in the plugin's private data store under
  `background-review/v1/`, at mode `0600`. A `zensu:review-aspect`, `zensu:review-judge` or
  repo-local `zensu-review-*` persona launch becomes one entry per agent under
  `fanout/<scv1-session-key>/`. The consume-mode
  `zensu:code-reviewer` becomes the session's one record under `records/`, holding the agent id,
  the ticket and the prompt's header lines, but only while its `REVIEW-TICKET` is the ticket the
  claim would accept. Its directive tells a standalone chain to end its turn and wait, and an
  Autopilot-bound chain to keep its turn. No ticket is consumed and no second reviewer is spawned.
  While `hooks.reviewPacketGate` is on, the review packet gate checks that launch first: a launch
  it refuses is not recorded and gets the gate's refusal instead, and a passing one is recorded
  in the gate's store with the digest of the block it carried.
- **Arrival.** A report reaches the main thread as a prompt: a hand-back whose frame line names
  the agent id, then a completion notification. `hooks/user-prompt-review-handback.sh` exits
  without a `node` child unless the prompt carries one of the two markers and the store holds a
  pending record or entry, or the store holds an arrival note. Its first `node` child,
  `background-review-v1.js arrive`, retires every fan-out entry the prompt names and, for a
  completed arrival of the session's pending consume reviewer, writes an arrival note under
  `arrivals/` before anything is claimed. It does either only for a prompt of the main thread: a
  payload that names a subagent (`agent_id` or `agent_type`) or another hook event changes
  nothing. Only an arrival the consume record still waits for, or a fan-out agent's hand-back that
  retired its entry, starts the post-review hook. For the consume arrival it claims the ticket once,
  through the claim the foreground path uses, and returns that path's routing directive as context
  of the prompt; for the fan-out hand-back it only lets the review packet gate record the report.
  Record and note are retired together right after the claim and on every deliberate refusal. A
  claim that fails, or that a kill of the hook cuts off, keeps both, so the notification, the next
  Stop or the next prompt completes it. A frame counts only on a line of its own at column zero that
  the host's `[Subagent hand-back]` line follows, because the host indents every line of a report it
  forwards. A notification with another status, such as `failed`, ends the consume record without a
  claim and asks for a re-spawn with the same ticket, unless a note already records the completed
  report. While `hooks.reviewPacketGate` is on, the gate checks the consume reviewer's arrival once
  more before the claim, against the digest it recorded at the launch and with the report the
  hand-back carries; a refusal keeps the ticket unconsumed, retires the record and its note and
  names the re-spawn.
- **Panel and judges under the packet gate.** While `hooks.reviewPacketGate` is on, a
  `zensu:review-aspect`, `zensu:review-judge` or `zensu-review-*` launch is recorded in the gate's
  store with its agent id and its packet digest. It counts as no run and never as a failed judge,
  and its hand-back, which starts the post-review hook because it retired the agent's fan-out entry,
  completes it with the report the frame carries, so the consume check counts a panel and judges
  that ran in the background like foreground ones. Outside auto mode the desktop app sends no
  hand-back, so those launches never complete, and the consume check refuses with a hint to wait for
  them or to ask the user whether to set the key to `false`
  ([gates.md](gates.md#review-packet-gate)).
- **Claim deadline.** The prompt hook is registered with a `timeout` of 180 seconds. A
  `UserPromptSubmit` hook without one gets 30 seconds (Claude Code 2.1.308), and one claim under
  load took longer: the measured incident cancelled the hand-back hook at 30.1 s and its resend at
  31.0 s, and no completion notification followed. The claim starts only while 45 of the 180
  seconds remain; past that the prompt carries a notice that the claim completes at the next Stop
  or prompt, and the ticket stays untouched.
- **Stop.** A Stop whose store holds an arrival note beside the consume record first runs the
  post-review hook in its recovery mode, which claims the ticket from the note and blocks with the
  routing directive. While `hooks.reviewPacketGate` is on, the gate checks that claim as an arrival
  on the round's records alone, because the note carries no report. It starts that claim only
  while the Stop has more than 20 seconds left before
  its deadline, the Stop guard's own (45 seconds by default) or, when the hook runs without that
  guard, its registered 90-second timeout, and stops a claim that has not reached the ticket by
  then, so a slow claim never costs the Stop its decision. While a consume record younger than 60
  minutes still matches the issued ticket, or a fan-out entry younger than 60 minutes exists, the
  Stop guard releases a standalone chain's turn end with one stderr line and charges no review
  budget. An Autopilot-bound chain is held instead: its Stop blocks, names the agents that still
  run, and does not count against the inner Stop budget. When the claim from a note did not
  complete in that Stop, both say that the report arrived and its claim is pending instead. A Stop
  that is not released, such as an Autopilot-bound chain's or a standalone chain's whose wait
  could not be read, says so at most three times for one claim and names the attempt; the
  next one that still cannot claim it retires the record and its note, and so does any Stop whose
  claim still fails 60 minutes after the launch, so the resume directive then runs the review
  again. A session that owns a live Autopilot run
  without a bound chain, and a Stop that adopted a deferred review, take neither; their resume
  directive opens with a sentence naming the running agents, or the pending claim.

**Residuals.** The arrival relies on the host firing `UserPromptSubmit` for queued prompts, as
measured in the desktop app; without it every wait ends 60 minutes after the newest launch and the
resume directive applies again. The column-zero rule rests on the host indenting what it forwards:
a peer message the host does not indent, and that names a pending agent id, could still carry a
forged frame; that id sits only in the session's own `0600` store. A notification that says
no report was delivered still claims the ticket, and the directive tells the main thread to ask
the reviewer for its report with `SendMessage` first. A kill that lands after the ticket is
consumed and before the directive is emitted still loses that directive; the claim starts only
with the deadline's margin left, and only the claim-field parse, the record retire and the emit
run after it. While any session's arrival note is pending, every prompt of every session in the
plugin pays one `node` child for `arrive`. A fan-out reviewer whose completion notification
arrives before its hand-back has its entry retired by the notification, so its hand-back no
longer starts the post-review hook and the packet gate never reads that report: the consume check
then refuses for a missing reviewer, as for a report it cannot observe. The measured host sends
the hand-back first. With `hooks.reviewPacketGate` off, each fan-out hand-back still starts the
post-review hook, which binds the session and exits without output, because the hand-back hook
reads no config. A claim the Stop completes from a note is checked without the report, so a
consume reviewer that answered `REVIEW PACKET INVALID` in a hand-back whose claim was cut off is
not refused there.

#### Custom review personas (repo-local)

Projects extend the review panel without forking the plugin: drop agent definitions at `.claude/agents/zensu-review-*.md` (standard agent frontmatter + body prompt; Claude Code registers them at session start — a file added mid-session is not yet spawnable and gets logged as `PERSONA SKIPPED — <name> (not registered)`). The frontmatter `name:` must equal the filename stem and match `zensu-review-[A-Za-z0-9_-]+` — anything else is skipped as malformed. An optional `activation:` field holds comma-separated glob patterns (items may be quoted) matched against the changed-file paths — `**` crosses directory separators on segment boundaries (`"**/domain/**"` matches `src/domain/x.ts` but not `src/subdomain/x.ts`), `*`/`?` stay within one segment, and a pattern without `/` also matches the basename. Project-agnostic examples: `"**/domain/**"` (DDD rules), `"**/*.tf"` (infrastructure), `"**/*.component.ts"` (frontend components). A persona with no `activation:` field always joins; one whose globs match nothing is skipped AND named in the run log (`PERSONA SKIPPED — <name> (no activation match)`) — never silently omitted; malformed files (bad frontmatter, name/stem mismatch, symlinks) are skipped with a log line and never abort the chain. Extra personas are capped at five per run — glob-matched personas take slots before always-join ones (relevance wins), each group lexicographic; overflow is logged as dropped. **Output contract:** a persona reports exactly like a built-in aspect — `## Aspect: <persona-name>` header with `- [SEVERITY] file:line — finding` bullets — except every finding is prefixed with the persona's uppercased `<NAME>-<n>` ID for provenance. **Trust boundary:** a persona file is a repo-controlled prompt at the same trust level as any `.claude/agents` definition or a checked-in `CLAUDE.md` — the read-only/no-build contract is carried by the spawn prompt and the persona's own `tools:` frontmatter, not by promotion to the built-in reviewer principal. Custom personas stay neutral `host-profile-v1`: the all-tool gate prevents Session Control/workflow-root access and `main-v1` impersonation, but their ordinary host tools remain governed by their own frontmatter. Audit `zensu-review-*.md` files in third-party repos before running `/zensu:build` or `/zensu:plan-review` (both spawn personas from the local working checkout; `/zensu:pr-team-review` is base-scoped). Matching is decided deterministically by `hooks/lib/persona-activation.js` (changed files on stdin, personas dir as argv; verdict lines `spawn`/`skip`/`drop`).

Here, “ordinary host tools” means every tool their frontmatter grants except what
reaches Zensu's own state or runs commands outside `Bash`: neutral personas are
denied every shell/command alias, `PowerShell`, a `Monitor` command, a tool whose
name marks it as running commands, and `Bash`, regardless of their frontmatter.
**Three consumers, one file.** The same `.claude/agents/zensu-review-*.md` persona feeds three review flows: `/zensu:build`'s Phase 6 fan-out, `/zensu:pr-team-review`'s cast, and `/zensu:plan-review`'s cast. A persona file declares only the *concern* (its body) plus its *activation globs* (frontmatter) and stays **output-format-agnostic**; each flow injects its own output contract at spawn — `/zensu:build` wants the `## Aspect: <persona-name>` markdown above, while the two team-review skills want structured JSON (`$WORKDIR/<name>.json` per their shared schema). A body that hardcodes one format still runs under the others (the injected contract wins), but keeping the body format-neutral lets one file serve all three. **Trust boundary for PR review:** `/zensu:pr-team-review` reviews an untrusted PR head, so it discovers personas from the reviewed repo's **base checkout** (`$REPO/.claude/agents`), never the PR-head worktree — a PR cannot introduce its own reviewer. `/zensu:plan-review` and `/zensu:build` run against the trusted local working checkout and discover from its git toplevel.
**Inline anchors.** When `/zensu:pr-team-review` publishes, every inline comment anchor is pre-validated against the diff by `hooks/lib/valid-diff-lines.js`, with nearest-line remap, so a finding whose line is not commentable is relocated rather than lost.

#### Skill overlays (additive-only)

Three skills carry an overlay anchor (`<!-- zensu:overlay <name> -->`): `build`, `cover`, and `pr-team-review`. A repo drops team guidance at `.zensu/overlays/<name>.md` (resolved at the git toplevel of the working checkout, worktree-aware, same anchor as templates and personas) and the skill injects it at that point. The contract is **additive-only**: an overlay may ADD conventions, extra checks, and stack particularities; it can NEVER disable, replace, weaken, or reorder the skill's mandatory phases (discipline gates, evidence audits, review chain, chain terminus) — on any conflict the skill text wins and the run surfaces one line naming the ignored overlay directive. Missing or empty file = no-op. **Trust boundary:** overlays are repo-controlled prompts at the same trust level as `.claude/agents` personas or a checked-in `CLAUDE.md` — the additive-only rule is carried by the skill instruction, not enforced by code; audit `.zensu/overlays/` in third-party repos before running. Example overlay (`.zensu/overlays/build.md`):

```markdown
- Team convention: every new module gets an ADR reference in its header.
- Extra check: flag any new dependency added without a lockfile update.
```

#### Templates (repo-overridable)

Four artifact skeletons ship as plugin defaults under `templates/` and resolve with the repo winning: a consumer uses `.zensu/templates/<name>.md` at the git toplevel of the working checkout (`git rev-parse --show-toplevel` — worktree-aware, same anchor as persona discovery) when it exists, else `<absolute-plugin-root>/templates/<name>.md`. The top-level Skill obtains that concrete root from Claude's native `${CLAUDE_PLUGIN_ROOT}` substitution; a supporting file loaded with `Read` must receive the already-resolved value from its parent instead of expecting another substitution pass. An override REPLACES the default wholesale — it MUST keep the mandatory sections, because the Phase 5/6 audits and `/zensu:converge` anchor on them (a structure test can only pin the plugin defaults, so for overrides this is a documented contract):

| Template | Consumer | Mandatory sections |
|----------|----------|--------------------|
| `zensu-plan.md` | `/zensu:build` Phase 2 | `## Requirements` (ID/Covers), `## Preconditions`, `## Cross-Layer Value Flow Pairings`, Status Legend, Steps table with Status+Covers, `## Final Verification` |
| `autopilot-spec.md` | `/zensu:autopilot` Phase 0.C | numbered stable `AC-###` criteria, out-of-scope section, resolved recipe |
| `autopilot-pr-body.md` | `/zensu:autopilot` step 3 | per-AC checklist table (deprecated rows kept) whose `Status` cells carry the 🟢/🟡/🔴/⚪ marker prefix, `Gates bypassed during build:` audit line |
| `pr-body.md` | `/zensu:pilot` "Commit + open PR" (shared default for any PR opener) | `## Acceptance criteria` table filled from the feature's `## Requirements` rows, with a stub-row fallback, whose `Status` cells carry the 🟢/🟡/🔴/⚪ marker prefix |

#### Code Reviewer — 5 Sequential Specialist Perspectives

The code-reviewer agent is a single READ-ONLY agent (no `Edit` / `Write` / `Task` tools) that walks five perspectives in order:

> In the `/zensu:build` review chain (since 0.6.0) the review is fanned out to parallel `review-aspect` subagents and merged in the main thread — by default the lean panel of `correctness`, `design` and `security`, or these five perspectives with `hooks.reviewPanel: full`; the sequential walk described here is what a direct standalone `code-reviewer` invocation does.

| Reviewer | Scope |
|----------|-------|
| conventions-checker | CLAUDE.md compliance, naming, formatting |
| bug-hunter | Logic errors, off-by-one, null checks, race conditions |
| architecture-reviewer | Layer separation, dependency direction, patterns |
| test-analyzer | Coverage gaps, assertion quality, missing scenarios |
| security-reviewer | Secrets, injection, auth checks, input validation |

Anti-hallucination rules: every finding requires file:line reference, confidence >= 80, must Read the file before reporting. Those rules are directives the reviewer is asked to follow; the **Finding Verification Gate** (`hooks.findingVerification`, default on) is what mechanically checks them afterwards — the main thread grades every merged finding against the real source via the model-free `hooks/lib/finding-verify-v1.js` plus its own read, and marks whatever does not hold up `[Unverified — do not fix]` instead of routing it to a fix or publishing it.
