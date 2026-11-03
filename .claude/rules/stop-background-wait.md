---
paths:
  - "hooks/lib/stop-background-wait-v1.js"
  - "hooks/stop-chain-enforcer.sh"
  - "hooks/lib/zensu-tdd-phase.sh"
  - "hooks/lib/zensu-log.sh"
  - "tests/structure/stop-background-wait-v1.test.js"
  - "tests/structure/test-stop-background-wait.sh"
  - "tests/structure/test-external-review-hook.sh"
---

# Stop Background Wait (`hooks/lib/stop-background-wait-v1.js`)

The Stop guard blocks every turn end while an armed chain's review is open. A turn that only
waits for a background run (an E2E reproduction, an affected suite, a background agent) was
therefore forced to poll: a PROJEKTPRO fix round on 2026-10-21 polled about ten times at
roughly 580k context tokens per call, and the self-review stage hit the same wall the day
before. This wait releases such a Stop, explicitly and bounded.

**The protocol.** The turn names the task it waits for on a line of its own in its final
message, `ZENSU-AWAIT: <task id>` (optionally in backticks). The hook reads the Stop input's
`last_assistant_message` and `background_tasks`; when a named task is in flight it releases the
Stop with one notice through `stop_notice` (stderr and the Stop's `systemMessage`, the channel
`.claude/rules/stop-latency.md` requires for every release) and charges nothing. The first Stop that sees running tasks and no
such line blocks once with a dedicated reason that names every task in flight (id, type,
description) and the line; that hint also charges nothing, and it is shown once per new task id
and at most `LIMITS.hintsPerGeneration` (3) times per chain generation, so a later Stop that
sees no new task, or comes after the third hint, gets the ordinary directive, charged as before.

**The vocabulary is MEASURED, statically, on Claude Code 2.1.299** (`MEASURED_HOST_BUILD`).
The Stop input carries `background_tasks`, built by `hSn(taskRegistry.all())`: it keeps only
tasks whose status is `running` or `pending` and that are not foreground
(`isBackgrounded !== false`), and maps the internal type to a label through one table —
`local_bash` → `shell` (a background Bash and the Monitor tool alike), `monitor_mcp` and
`monitor_ws` → `monitor`, `local_agent` → `subagent`, `local_workflow` → `workflow`, plus
`MCP task`, `teammate`, `dream`, `auto-mode scan`, `memory import`, `cloud session`, and the
raw discriminant for a type the table lacks. Re-verify against the binary, never against
memory, before changing `WAKING_TASK_TYPES` or `IN_FLIGHT_STATUSES`: search the bundle for
`background_tasks:hSn(` and read the label table and the status filter beside it. The Stop
payload was never captured live; the headless recipe needs the host's auth refresh.

**Why explicit, and why that is not negotiable.** A background Bash, the Monitor tool and a
dev server that never ends all carry the label `shell`, so the payload cannot tell a run the
turn waits for from a server that never wakes the session. An implicit release would let a
dev server started in the same turn end it with the review chain unrun. The marker puts the
choice where the knowledge is, and a named task must still be in flight according to the host,
which the model cannot forge.

**Fail-closed everywhere.** Only `shell`, `monitor`, `subagent` and `workflow` with status
`running` or `pending` count; any other type, status, id shape or a malformed field neither
releases nor hints. A store fault answers `nowait reason=fault`: a release or a hint that could
not be recorded would be unbounded. The hook accepts only a two-line verdict whose head is
`wait release=` or `hint tasks=` and whose text is one line.

**Bounds.** A task releases at most `LIMITS.releasesPerTask` (5) Stops per chain generation,
which covers a Monitor that wakes the session several times; after that the ordinary directive
blocks. A generation gets at most `LIMITS.hintsPerGeneration` (3) uncharged hints, counted in
the state's `hints` field, which survives the pruning of finished tasks, so a stream of new task
ids cannot hold the Stop budget still (`nowait reason=hint-limit`, `B21`). Neither path runs once
`stopBlockCount` has reached the cap (`autoFixMaxRounds + 3`): `stop_background_wait` compares
the counter with `CAP`, which the hook computes before the call, so a chain the cap released is
released by the cap path with its disclosure and never hinted or waited for again (`B20`). State
lives in `<plugin data>/stop-background-wait/v1/<session key>.json`, pruned to the tasks in
flight on every write and deleted by `--tdd-begin` (`zensu_stop_background_wait_reset`). The
session's own state has no age limit: a 24-hour expiry renewed the per-task bound and the hint
inside one generation. Another session's file is swept after `LIMITS.sweepAfterMs` (14 days)
without a write. 5 and 3 are judgements, not measurements.

**Placement.** `stop_background_wait` runs after the round-0 workflow wait of
`.claude/rules/external-review-import.md` and the background review wait of
`.claude/rules/background-review-completion.md`, and before the Stop budget, in every armed state
past implementation (the first review, routed fix rounds and the self-review stage) while the
budget is below its cap. The implicit workflow wait keeps its own counter; once it is spent, a
running workflow is an ordinary waking task here. A review agent the plugin recorded at launch
releases through the background review wait first; once that wait's 60-minute window has passed,
an agent that still runs is an ordinary `subagent` task here. Exclusions, all inside the function: a session that owns a live Autopilot run, an
Autopilot-bound chain, a Stop that adopted a deferred review, a project holding a deferred
claim, and a refused reviewer spawn. A Stop input without a `background_tasks` entry returns at
a `case` test before any config read, probe or child process (`B18`).

**Config.** `hooks.backgroundTaskWait` (default `true`), read permissively through
`zensu_hook_enabled` in a subshell that exports the RECORD's project root, the same anchoring
the scope-sentence read uses (`B12`). `false` removes both the release and the hint.

**Coupled sites.** The module (vocabulary, marker grammar, verdicts, bound, store, rendered
hint and release note); `stop_background_wait` and its call site in `hooks/stop-chain-enforcer.sh`;
`zensu_stop_background_wait_file` / `_reset` in `hooks/lib/zensu-tdd-phase.sh` and the
`--tdd-begin` call in `hooks/lib/zensu-log.sh`; `config.example.json`; the `false` entry in
`evals/route-short-line-reaction/eval-config.json`, which `RS5` of
`tests/structure/test-route-short-line-eval.sh` requires for every key a hook passes to
`zensu_hook_enabled`; the `backgroundTaskWait` row and the `stop-chain-enforcer.sh` row of
`docs/configuration.md`; §"Waiting for background work" of `docs/review-chain.md` and the
pointer to it from the workflow-wait bullet; the unit file and
`tests/structure/test-stop-background-wait.sh` with their registry and manifest entries; and
X14, X15, X17 and X20 in `tests/structure/test-external-review-hook.sh`, which now expect the
hint where a running task meets the limit of the implicit wait, a converged chain or a fix round;
the release goes through `stop_notice` (`B4`), and `.claude/rules/stop-latency.md` lists it among
the releases that return on `DECISION_EMITTED`.

**Known gaps.**

- A model that names a task that never ends releases up to five Stops for it, each one ending a
  turn that nothing wakes; the review chain then waits for the next prompt. The hint tells the
  model never to name such a task; nothing enforces it.
- A Monitor that reports more than five events exhausts its task's bound, and the turn polls
  again.
- A host without `last_assistant_message` never releases: the hint shows once per task and the
  ordinary directive follows.
- No `/zensu:doctor` row reports the state file or a spent bound.
- A chain generation that sees no write for 14 days while another session writes loses its
  counters to that session's sweep, and its tasks get fresh bounds.
- At most `LIMITS.maxTasks` (32) in-flight tasks are considered; a 33rd is neither named in the
  hint nor releasable.
- Windows is unmeasured: the suite is a `ciStructureTests` member and runs in the weekly Windows
  Safety structure shard only. Say "unmeasured", never "POSIX only".

**Version: `patch`.** No context-record or workflow-state field (the state is a private store
file), no strict key set, no hook added, removed or renamed, no matcher change, no
`permissionDecision`, no attestation change; the config key is read permissively.

**Port-relevant.** Core half: the module, whose inputs are a payload and two options. Host
half: the payload fields (`background_tasks`, `last_assistant_message`), the label vocabulary,
the marker line in the host's final message, and the hook placement. `zensu-codex`,
`zensu-kiro` and `zensu-antigravity` were not included.
