# Session Control

How the plugin binds a running session to one immutable record, what that
protects, the two states in which a failed bind is deliberately relaxed, and the
third it names and repairs instead.

## Claude Code Workflows (subagent safety)

The review chain is enforced by a Stop hook (`stop-chain-enforcer.sh`) on the **top-level
interactive thread** — the one that owns the TDD state, receives the `Stop` event, and can
spawn `zensu:code-reviewer`. Under a **Claude Code Workflow** (the `Workflow` tool /
`agent()` orchestration) many short-lived agents run concurrently, and naively that breaks
two ways: each spawned worker fires its own `Stop` (the enforcer would block it and order a
reviewer spawn it cannot do → deadlock), and concurrent agents could cross-resolve to each
other's session state.

Both are handled by Session Control v1:

- **Spawned agents never block on `Stop`.** The enforcer classifies the trusted
  hook payload and no-ops for Task/Agent reviewers **and** Workflow workers.
  Only a genuine `Stop` event with neither `agent_id` nor `agent_type` may enforce;
  no environment override can promote a child into the interactive main principal.
- **One immutable parent context.** `SessionStart` binds the exact plugin installation,
  project, version, content-addressed source revision (equal to the runtime digest), and runtime digest to a domain-separated session
  hash under `CLAUDE_PLUGIN_DATA/session-control/v1`. `SubagentStart` reads that
  parent record to inject context, but Claude Code does not support blocking a child
  from this event. The first all-tool `PreToolUse` hook therefore revalidates the
  host-provided session id, executing plugin root, plugin-data directory, private
  record, and current runtime digest before every tool call and denies missing or
  contradictory context. Hook subprocesses derive this binding directly from the
  standard host fields. `SessionStart` never reads or writes `CLAUDE_ENV_FILE`,
  and no plugin-private selector is exported into the shared model/subagent shell
  environment. The record's `project_root` remains the immutable
  workflow-state anchor, while the canonical host-reported `cwd` may move to an
  external detached worktree after `CwdChanged` and is used only to resolve
  relative tool paths. Fresh `startup`/`clear`/`fork` events may create that
  binding; `resume`/`compact` reuse the existing record's original project even
  when the current directory changed. A session id with no record yet — a
  `fork`, whose new id can never have one, or a continuation whose private
  record was pruned or invalidated by a plugin upgrade — is registered like a
  cold start rather than left unbindable, because a session without a record
  fails every stateful hook closed for the rest of its life. A missing or
  malformed lifecycle source, and a fresh cross-project reuse of an id that
  already has a record, still fail closed instead of creating a replacement
  anchor. A fork inherits no workflow state: it starts with its own baseline
  document, and Claude Code's `SessionStart` payload carries no parent session
  id to inherit from. The five
  exact plugin-scoped reviewer identities receive
  `reviewer-readonly-v1`; the plugin-scoped `zensu:zensu-plm` and every other
  unknown or custom agent receive neutral `host-profile-v1`. This also applies
  when Claude reports `agent_type` directly on `SessionStart` for a top-level
  `claude --agent` session; only a host payload with neither agent field is the
  interactive `main-v1` principal. The PLM and
  reviewers are nevertheless restricted to `Read`/`Grep`/`Glob`; ordinary
  host-profile children keep non-command tools granted by Claude and their
  agent definitions, but every shell/command tool is denied because command
  text cannot be safely confined by token inspection. Only the top-level
  interactive thread receives `main-v1`; there
  is no transcript scan, PPID key, newest-file selection, or fallback identity.

**Security boundary.** Session Control protects host-tool and subagent workflow
decisions against cross-session confusion, protected-path access, and concurrent
CAS races. Before a neutral file tool runs, the gate resolves every existing
path component (including symbolic links), but Claude Code does not provide an
OS broker that atomically binds that check to the later tool operation. The
project-local state is therefore not a cryptographic authority against
user-authorized build/test commands, external processes, or other same-UID
processes that can mutate the worktree between check and use. Run untrusted
project code inside an OS sandbox/container with a separate UID and restricted
mounts; do not treat `host-profile-v1` as a host sandbox. Normal report prose
cannot impersonate a principal: identity comes only from trusted hook payload
fields. For neutral children the gate blocks every command tool, actual
protected paths, protected traversal roots, and mutating Zensu operations while
preserving non-command review tools. `Grep`/`Glob` must target a concrete safe
subtree; omitted paths and project/plugin/plugin-data ancestors are denied.
Neutral file mutations also deny the complete installed-plugin and private
plugin-data trees, including symlink, case-variant, and hard-link aliases.
Third-party MCP tools that themselves expose arbitrary local execution are
outside this host-tool boundary; do not grant them to untrusted agents.

> Naming note: this is unrelated to the MCP-gate `--workflow-begin` / `workflowActive`
> markers above — those scope per-skill MCP mutation tools, not Claude Code Workflows.

The local Promptfoo installed-plugin evaluation can install an exact clean Git
SHA through an ephemeral local marketplace backed by a private detached-HEAD
clone, using the pinned Claude Plugin CLI and an isolated user cache. It
launches Claude without `--plugin-dir` and proves that normal and reviewer
subagents inherit this immutable context. These Promptfoo and live-model
profiles are local-only and never run in GitHub Actions. Their Linux harness
pins Ubuntu 24.04 semantics, verifies Claude's required `bubblewrap`/`socat`
sandbox dependencies, and fails closed if AppArmor user-namespace preparation
or a functional sandbox probe fails. The side-by-side upgrade profile itself
is Linux-only: it first proves
the explicit API/OAuth credential with a plugin-free, tool-free Claude canary
inside outer `bubblewrap` containment. Bubblewrap receives that canary
environment through its `--args` file descriptor 3, never through the process
argument vector; custom Anthropic base URLs, proxies, and TLS trust overrides
are rejected. The gate then runs the old and candidate lifecycles with only a
random dummy credential against its own deterministic loopback
Anthropic-compatible backend. Both lifecycle processes use `bubblewrap`
PID/mount containment, and every plugin hook runs in a nested
network/PID/mount namespace that cannot see evaluator control or trace state.
That nested boundary receives only the evaluator-bound `CLAUDE_PLUGIN_DATA`
and `CLAUDE_PROJECT_DIR` values needed by the hook contract. The old and
candidate fixtures are immutable, unpredictable direct children of an
isolated cache parent; the isolated plugin registry, not a predictable SemVer
path, selects which completed root Claude loads. PR CI exercises only the
deterministic nested-hook integration on pinned Ubuntu without a model request.
Windows CI runs deterministic non-Promptfoo contracts only. Real existing-login
candidate execution is unsupported; its hermetic fake remains solely for local
deterministic coverage.
See [Session Control release gate](session-control-release-gate.md).

**Getting a guaranteed review for a Workflow-triggered run.** Because the worker `Stop`
no-ops, run the review **once over the aggregate diff** — either in-script (recommended) or
deferred:

```js
// Orchestrator-driven: after all implementation agents have joined, run ONE
// review pass over the combined diff — 5 read-only aspects → merge → judge
// (when hooks.reviewJudge is enabled, the default) → verify → reviewer.
const ASPECTS = ['conventions', 'bugs', 'architecture', 'tests', 'security']
const changed = /* `git diff --name-only HEAD`, comma-joined */
const aspects = await parallel(ASPECTS.map(a => () =>
  agent(`Perspective: ${a}. Files changed: [${changed}]`, { agentType: 'zensu:review-aspect' })))
let merged = /* dedupe + sort the five findings lists in-script */
const judge = await agent(`Judge pass. Files changed: [${changed}]\n${merged}`, { agentType: 'zensu:review-judge' })
merged = /* apply JUDGE-* deltas; Panel-FP: verdicts stay visible and mark the referenced finding [Panel-FP-neutralized — do not fix] */
// Finding Verification Gate (hooks.findingVerification, default on): grade every merged
// anchor with `node hooks/lib/finding-verify-v1.js --root <top>` (model-free, always exit 0),
// read each surviving citation yourself, then mark whatever does not hold up
// [Unverified — do not fix] and downgrade it to SUGGESTION. Annotate, never delete.
merged = /* apply the verification verdicts */
const reviewTicket = /* stdout from the top-level Skill command template:
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --review-ticket */
await agent(`PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${reviewTicket}\n${merged}`, { agentType: 'zensu:code-reviewer' })
```

If you cannot review in-script, a worker records a project-scoped marker
(`zensu-log.sh --pending-review --files "<changed>"`); the **next interactive `Stop`** in
that project adopts it and runs the full chain once, then clears it. The orchestrator clears
it itself with `zensu-log.sh --pending-review-done` when it reviewed in-script. Review is
per-implementation over the aggregate diff — **never per spawned worker**.

## Unbindable sessions

Every gate binds the running session to its immutable Session Control record before it decides anything, and a failed bind normally denies. There are **two** relaxed states plus **one named-but-not-relaxed** state, and this table is the authoritative account of them. The first two share one argument — no workflow document is reachable, so no review chain and no Autopilot run exist to enforce and nothing is waived by relaxing — and they are separate predicates, never one widened check, because they are different diagnoses with different remedies. The third is described below them and is deliberately outside that argument.

**No record at all.** `SessionStart` registers a record for any source, so the ordinary ways into this state are gone. What remains is a session where no record could be written at all — an unwritable plugin-data store, a `SessionStart` hook that never ran. The predicate is `zensu_session_unregistered` (shell) / `unregisteredSession` (`hooks/lib/claude-hook-session-v1.js`), true **only** on a clean `ENOENT` of the records directory or the record file.

**Orphaned project root.** A record that is valid in every other respect, pointing at a directory that is gone — most often a git worktree deleted or recycled mid-session. The workflow document lives at `<project_root>/.zensu/state/` and died with it, while the record itself lives in `CLAUDE_PLUGIN_DATA` and survived. The predicate is `zensu_session_orphaned_project_root` (shell) / the `orphaned-project-root` mode of `claude-hook-session-v1.js`, which waives exactly one check — whether `project_root` still exists — and requires that path to be **absent** (`lstat`, never `realpath`, so a dangling symlink stays a present-but-wrong root). Everything else must still validate as `readContext` demands, plus the plugin-root and plugin-data identity checks, so a **second** disagreement is never relaxed alongside the first.

A record that **exists** and disagrees about anything else — runtime digest drift, a foreign plugin root or plugin data, a root that still exists but no longer matches, tampering — is a security signal and is deliberately **not** covered: it keeps failing every gate closed, main thread included. So does any unreadable, unsafe, or ambiguous state.

**Incompatible runtime lineage — named, but never relaxed.** There is a third diagnosis, and it belongs to a different family than the two above. The record is intact in every respect and the sole disagreement is that the executing installation declares an incompatible lineage — what a plugin update landing mid-session produces. The predicate is `zensu_session_incompatible_runtime` (shell) / the `incompatible-runtime` mode of `claude-hook-session-v1.js`, and it uses the **strict** reader: a record that is also orphaned answers no here and is classified by the orphan predicate, which is the heavier remedy. It prints `recorded<TAB>executing` so a caller can name both declared versions.

It is **not** a relaxable state, and the distinction is the whole point. A workflow document is still reachable, so relaxing a write gate would waive a live guarantee rather than a dead one. What the predicate buys is a NAME: before it existed this state fell through to the "no record" wording, which is false and sends the user hunting for a record sitting intact in plugin data. Two consumers act on it — the `/zensu:doctor` binding row and the deny emitter's `incompatible-runtime` scope — and a third **releases** on it: the Stop hook, because it cannot read the chain from an unbound session anyway, and blocking a session whose Edit and Bash channels are already denied only loops it so the remedy never reaches the user. That release is a **deferral**, not a waiver: the document survives untouched and the next Stop after an adoption enforces it again.

**A compatible plugin upgrade is no longer one of those disagreements — it binds, so it never reaches this table.** An update that lands while a session is running leaves the record naming the installation that minted it, and nothing can re-bind a write-once record in place. `servesRecordedRuntime` (`hooks/lib/session-control-core-v1.js`) therefore decides which installation may serve a record: the executing root must be a **sibling** of the recorded one — every marketplace install lands beside the versions it replaces, while a working checkout does not, so a development tree cannot adopt an installed session's record whatever version it declares — and the two versions must share a lineage under `runtimeLineageCompatible`: same major, and while major is `0` the same minor as well, never backwards. `0.17.1 → 0.17.2` keeps the session fully alive; `0.17.x → 0.18.0`, `0.9.2 → 0.17.2` and every downgrade do not, and land in the third column with the whole allowance below as their only reachable command. `CLAUDE.md` "Runtime Lineage" states which changes force the breaking bump.

Every site that compares a record's plugin root against the executing one shares that one predicate — `resolveHookSession` and its `resolveOrphanedProjectRoot` mirror in `hooks/lib/claude-hook-session-v1.js`, `currentClaudeSessionContext`, and both the SessionStart-resume and SubagentStart branches of `hooks/lib/claude-session-control-v1.js`. The last two are what keep the rule from expiring mid-session: a resume or a compaction re-enters SessionStart, and the review chain fans out subagents, so a strict comparison at either would kill the very session the rule exists to keep alive. `relatedClaudeSessionContexts` is deliberately excluded — it compares two records against each other, not a record against the executing runtime. `plugin_data` equality is **not** relaxed anywhere; it is what keeps an inline or development source and an installed marketplace plugin on separate record stores.

**Known gap: the review-evidence lease is not lineage-relaxed.** `hooks/lib/review-evidence-lease-v1.js` still compares its recorded `plugin_root` strictly, so a lease minted before an upgrade is refused after it, and because `listRecords` validates every record and propagates the first failure, that one lease then fails every later lease operation for the session. The lease record carries no `plugin_version`, so closing it needs a schema change rather than a predicate swap. **Adoption works around this rather than closing it:** it moves every lease naming the previous installation OUT of the records directory into a sibling `superseded/<session-key>/`, because `listRecords` fails on any entry that is not a `.json` lease and a set-aside file left in place would be strictly worse than the stale lease. A lease is a short-lived evidence reservation, so the cost is a repeat, not a guarantee — and the count is reported rather than silently absorbed.

The cost is stated rather than glossed: the digest pin weakens from *the measured code is the enforcing code* to *the enforcing code shares a declared-compatible lineage with the measured code*. What does **not** weaken is the record itself — it stays write-once, `readContext` still computes the runtime digest against the **recorded** root and still requires that root's manifest to declare the recorded version, so a pruned or altered recorded runtime keeps denying. Because the bound runtime and the running one can now differ, an attestation states both: `resolved_plugin_root` / `runtime_digest` name what the session was bound to, and `executing_plugin_root` / `executing_runtime_digest` name what actually ran, the latter measured at attestation time rather than accepted from the caller.

**Two commands are exempt from that, in every bind failure.** What remains of the upgrade case after the lineage rule above is the *incompatible* update — a breaking release, or a downgrade. Denying `/zensu:doctor` there put it behind the very defect it reports, and denying the repair alongside it left a diagnosis with no remedy. `hooks/lib/zensu-doctor-invocation.js` therefore admits exactly two shapes, for the main thread only: a closed set of assignments followed by one `bash <the executing plugin's zensu-doctor.sh>`, or the same followed by `bash <the executing plugin's zensu-session-adopt.sh>` with at most the literal `--confirm`. It is a **whitelist**, not a blacklist of dangerous characters: an operator, a substitution, a redirection, a second command, an undeclared flag, a repeated flag, a symlinked or hard-linked script, or a path under a different root is refused.

The two are admitted on **different** grounds, and folding them into one argument would lose the distinction. The diagnostic writes nothing — the one write in the doctor flow is the expired-`pending-review.json` cleanup, which the model issues as separate, still-gated commands. The adoption *does* write, and its justification is written into the header of `hooks/lib/zensu-session-adopt.sh`: it writes one record for the calling session, one workflow history entry, and moves that session's stale review-evidence leases aside — three classes, all confined to `<plugin_data>/{session-control,review-evidence}` and the recorded project. What **bounds** that write is `readContext` — the session hash, the runtime digest recomputed against the **recorded** root, and that root's declared version — plus the sibling-root and `plugin_data` checks. It is deliberately **not** stated as "every location is derived from the record": `CLAUDE_PLUGIN_DATA` and `CLAUDE_PROJECT_DIR` arrive as caller-supplied literals here exactly as they do for the diagnostic, so that would be a stronger claim than the code enforces. It refuses unless every `adoptableRecord` condition holds, and without `--confirm` it is read-only. Every gate on the `Bash` matcher applies the allowance, plus the all-tool capability gate — a deny from any one of them wins, so a single wired gate would look like a working feature that does not work.

**Adoption — the one exit from an incompatible lineage.** `adoptableRecord` / `adoptContext` (`hooks/lib/session-control-core-v1.js`) let the running installation take an intact record over in place, and the authorising axis is **schema equality, not the version numbers**. That gate closes itself: `validateContext` enforces the record's `schema_version` and `validateWorkflowState` enforces the workflow document's `schema`, so a release that genuinely moves a persisted shape makes one of the two unreadable and adoption declines — nobody has to remember to add a check. Seven conditions are all required; eight refusal reasons name exactly which one failed: `record-unreadable`, `plugin-data-mismatch`, `project-root-mismatch`, `already-served`, `not-a-sibling-installation`, `executing-runtime-unidentified`, `executing-runtime-older`, `workflow-schema-mismatch`.

What it does: mints a new record for the same session under the executing runtime, carrying the original `created_at`; sets the previous record aside as `<session-key>.superseded-<version>.json`, never overwriting it, so *the record is immutable* stays literally true; appends one `RUNTIME_ADOPTED` entry to the workflow history under a reserved phase that `--phase` refuses to mint, exactly as `CHAIN_RECOVERED` is protected. It writes **no new record field** — provenance is the history entry — which is what keeps the release carrying it a `patch` rather than the breaking bump it exists to survive. It records **no bypass-ledger entry**: the ledger records gate escapes so that everything under "Gates bypassed" is true, and adoption escapes no gate. The session is bound again from the next tool call onward, with no restart, because every gate re-evaluates the binding per call.

**The allowance is POSIX-only, deliberately.** On Windows the command token reaches the recognizer over stdin — the one channel MSYS never converts — while the module's own location is already native, and a Git Bash mount path such as `/tmp/…` carries no drive letter to map. Resolving it correctly needs the MSYS mount table, which this repository does not probe; guessing would either admit a path that is not the diagnostic or deny while claiming to allow. So `win32` refuses outright and the diagnostic stays denied there in a bind failure — a **gap, not a regression**, since that is what every host did before. `tests/structure/test-versioned-plugin-upgrade.sh` asserts the deny on Windows and the allow on POSIX, so the gap stays a verified contract rather than an unverified claim.

A compatible upgrade has no column here on purpose: it binds, so every cell would read "behaves as a healthy session". The third column is the **incompatible** remainder.

| Gate | Matcher | No record at all | Orphaned project root | Record present but incompatibly wrong |
|------|---------|------------------|-----------------------|---------------------------------------|
| `pre-reviewer-capability-gate.sh` | `.*` | **main thread only** returns to its pre-Session-Control capabilities (the branch it reaches unrestricted anyway); every reviewer, evidence worker and neutral child stays denied | same relaxation — and it is load-bearing: this gate matches **every** tool, so if it denied here the Bash relaxation below would never be reached and `/zensu:doctor` would stay denied in practice | denies every principal, **except** the two recognized commands on the main thread (see above) |
| `pre-write-secret-scan.sh` | `Bash`, `Edit\|Write\|MultiEdit`, `NotebookEdit` | main thread only, then falls through to the **ordinary** scan decision, which needs no binding — a real secret is still caught on every channel and `Edit`/`Write` content is scanned rather than blanket-denied. Only the bypass ledger is skipped | same relaxation, and also load-bearing: it matches `Bash` too, and a deny from **any** hook on that matcher wins, so leaving it closed reinstates the whole deadlock | denies, except the two recognized commands on the main thread |
| `pre-bash-source-write-gate.sh` | `Bash` | main thread only; keeps exactly its source-write rules (A)/(B)/(C), with `CLAUDE_PROJECT_DIR` pinned explicitly. An absent project root denies every **resolved write operand** (`BSWG_MODE=targets`, which applies the same source-extension and temp-root filters and skips only the two rules that need a root) while letting commands that write nothing through — that is what keeps the diagnostic reachable, since in both relaxed states the anchor is typically gone or unset. An unparseable payload and a parser that fails to run still deny rather than allow unchecked | same relaxation, same rules — the **binding** is relaxed, never the write rules | denies, except the two recognized commands on the main thread |
| `pre-edit-tdd-reminder.sh` | `Edit\|Write\|MultiEdit` | denies — the TDD phase gate cannot evaluate a phase without a workflow document | denies — nothing here can anchor a write to a project | denies |
| `pre-bash-zensu-gate.sh` | `Bash` | already exits before its bind when the command runs no `zensu` CLI binary, so it never contributed | same | denies a `zensu` mutation |
| `plan-approved-delegate.sh` | ExitPlanMode | still emits `PLAN_GATE_BLOCKED code=RUNTIME_UNAVAILABLE`, whose text asserts a durable Autopilot artifact exists — untrue in this state. Advisory `additionalContext`; tracked as a follow-up | same | same |
| `stop-chain-enforcer.sh` | Stop | **releases** — with no record there is no workflow document, so no review chain and no Autopilot run exist to enforce and nothing is waived. Blocking would leave the user with tools but no way to end a turn | **releases** — same argument, reached from the opposite direction; the stderr names the dead path and both remedies (re-create exactly that directory, or start a new session) and advertises no bypass | **releases for a declared-incompatible lineage only** — the binding that resolves the project root is what failed, so the chain cannot be read from here at all; the guarantee is DEFERRED, not waived (the document survives and the next Stop after an adoption enforces it again), and the stderr names both versions and `/zensu:adopt-session --confirm`. Every OTHER disagreement still blocks, naming the states separately; `ZENSU_CHAIN=off` / `hooks.chainEnforcer=false` release the guard explicitly without proving completion |

`/zensu:doctor` distinguishes the two: an orphaned root renders its own binding row naming the dead path, rather than reporting a record as missing while it sits right there.

Consequence worth stating plainly: in either relaxed state the interactive thread keeps working, but **nothing in it is gated or tracked** — no review chain, no Autopilot, and no subagents. `Edit`, `Write` and `MultiEdit` are denied outright by the TDD phase gate, and a Bash write is denied because it cannot be attributed to a project (read-only Bash still runs, which is what keeps `/zensu:doctor` reachable). `NotebookEdit` is the one mutation that still passes — it is not phase-gated in a healthy session either, so the relaxation restores exactly the pre-Session-Control capability set rather than widening it. It is a session you can read a diagnosis in, not one you can work in.

Why it exists: `/zensu:doctor` runs through Bash. The fail-closed denial every stateful helper renders points the user there — and with the three gates that bind before inspecting all denying, that pointer was a dead end, denied by the very defect it names. The two relaxed states above fixed that for the cases where nothing is left to enforce; the recognized-command allowance fixes the remaining one, where a record exists and disagrees. Because it is now reachable in every bind failure, the skill emits the diagnostic as a **single** command and the root preflight lives inside `hooks/lib/zensu-doctor.sh` — a compound `if`/`elif` block could not be recognized without admitting a second command with it.
