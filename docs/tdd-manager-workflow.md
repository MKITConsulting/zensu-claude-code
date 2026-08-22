# TDD Workflow (`/zensu:tdd`)

End-to-end reference for the Zensu main-thread implementation workflow: vanilla by default, with strict Red/Green TDD and its PreToolUse phase gate available when configured.

> **0.4.0+ architecture.** Implementation moved from the `zensu:tdd-manager` *subagent* into the **main agent** (the subagent lost too much implementation context). The workflow now lives in `skills/tdd/SKILL.md`; its review stage uses five parallel `zensu:review-aspect` subagents, an optional `zensu:review-judge`, and one consume-mode `zensu:code-reviewer`. Sections 7–8 describe the shipped installed-plugin eval harness.

---

## 1. Overview

**What it is.** A main-thread skill (`/zensu:tdd`) that takes a feature specification and produces working, tested code. It runs in **vanilla implementation mode by default**: no RED→GREEN ceremony, while the plan, evidence audits, and review chain stay enforced. With `hooks.tddImplementation:true`, it additionally declares RED → IMPL → GREEN → REFACTOR transitions and a PreToolUse FSM gate blocks edits that violate the strict cycle (see §5). Strict is also reachable without touching config: `/zensu:tdd-mode --strict` records it for the session, and a calling skill can carry its own default into the spec as a single `TDD-MODE: strict` line — which is how `/zensu:pr-fix-findings` runs strict out of the box.

**When to invoke.**

```
Use the Skill tool with skill='zensu:tdd' and the feature spec as input
```

The skill is also auto-invoked by the `ExitPlanMode` PostToolUse hook when the user approves a plan that adds executable code, and by `/zensu:implement` Step 3.

**Inputs.**

- A feature specification (free-form text, or a path to `evals/.../prompts/*.md` in eval context).
- Project context — the agent discovers tech stack, test commands, coverage tooling automatically.

**Outputs.**

| Artifact | Path | Purpose |
|----------|------|---------|
| Plan | `.zensu/plans/{ts}_tdd-{slug}.md` | Design decisions, Requirements table (stable AC-###/FR-### IDs), step table with per-step `Covers` traceability, preconditions, audit checklist |
| Log | `${CLAUDE_PROJECT_DIR:-.}/.zensu/logs/{ts}_tdd-{slug}.log` | Append-only execution trace, phase markers, attempts, audit results |
| State | `.zensu/state/tdd-phase-<scv1-session-key>.json` | Runtime FSM/review state (per session, ephemeral) |
| Source | test + implementation files | The actual code |
| Audit | included in log + final report | Build, coverage, mtime discipline, edit landing, precondition drift |

The plan and log are per-run artifacts, and the plugin never auto-stages or
commits them. Whether they END UP committed is the repository's call: they are
gitignored in THIS one, and deliberately committed as an audit trail in many
consuming repos — which is why they are written to be publishable in the first
place (see [Publication safety](#publication-safety-of-the-plan-and-log) and
[CLAUDE.md](../CLAUDE.md)). The tracked source/tests and the final user-facing
report remain the durable repository outputs either way.

---

## 2. Two-Level Mental Model

Two distinct phase concepts share the word "phase". Keep them separate.

**Workflow Phases (0-6)** — the agent's overall journey for a single task. Linear, one-shot per invocation.

**TDD-FSM phases** — per-step state that the PreToolUse hook reads from the state file. Cyclical, repeated for each step inside Phase 4.

Each step inside Workflow Phase 4 cycles the TDD-FSM through `RED_WRITE → RED_RUN → RED_FAIL → IMPL → GREEN_RUN → GREEN_PASS` (and optionally `REFACTOR`). When all steps complete, the agent advances to Workflow Phase 5.

---

## 3. High-Level Workflow

```mermaid
flowchart TD
    Start([Main agent invokes /zensu:tdd skill]) --> P0[Phase 0: Pre-flight<br/>--tdd-begin, SESSION_TS, first TaskCreate]
    P0 --> P1[Phase 1: Discover Project<br/>Tech stack, test cmds, coverage tool]
    P1 --> P15[Phase 1.5: Precondition Discovery<br/>CLIs / secrets / endpoints / fixtures]
    P15 --> Q{Missing<br/>preconditions?}
    Q -->|Yes| Ask[AskUserQuestion<br/>install · substitute · skip]
    Ask --> P15
    Q -->|All present or resolved| P2[Phase 2: Plan + Log<br/>.zensu/plans/ts_tdd-slug.md<br/>.zensu/logs/ts_tdd-slug.log]
    P2 --> P3[Phase 3: Create ALL Tasks<br/>3 per TDD step + 1 per integration]
    P3 --> P4[Phase 4: Execute TDD Cycles<br/>RED to IMPL to GREEN per step]
    P4 --> P5[Phase 5: Checkpoint<br/>full suite + linter]
    P5 --> P6[Phase 6: Audit and Final Report<br/>build · coverage · drift audit · mtime]
    P6 --> Review[Phase 6: --tdd-complete<br/>skill spawns zensu:code-reviewer<br/>Stop hook guarantees it]
    Review --> Findings{Critical or<br/>Important findings?}
    Findings -->|Yes| AutoFix[Fix in-thread RED→GREEN<br/>gate active · max 5 rounds]
    AutoFix --> Review
    Findings -->|None or max rounds| SelfRev["/zensu:self-review<br/>terminal · ≤ 1 fix round"]
    SelfRev --> Done([Final Report])

    style P15 fill:#fef3c7,stroke:#92400e,color:#1e293b
    style P6 fill:#fef3c7,stroke:#92400e,color:#1e293b
    style Ask fill:#fee2e2,stroke:#991b1b,color:#1e293b
    style SelfRev fill:#dcfce7,stroke:#166534,color:#1e293b
```

**Phases at a glance:**

| Phase | Goal | Key outputs |
|-------|------|-------------|
| 0. Pre-flight | Capture `SESSION_TS` + `SESSION_EPOCH` + `BASELINE_SHA`, create first task | session timestamps + baseline commit |
| 1. Discover Project | Read CLAUDE.md hierarchy, detect tech stack, test runners, coverage tool + threshold | tech-stack context |
| 1.5. Precondition Discovery | Enumerate every external CLI/secret/endpoint/fixture named by the spec, verify presence, escalate misses | Preconditions table in plan |
| 2. Plan + Log | Write plan markdown (incl. Requirements table with stable AC-###/FR-### IDs + per-step `Covers` mapping) + initialize log file | plan + log on disk |
| 3. Create ALL Tasks | 3 tasks per TDD step (test/impl/verify) + 1 per integration step | TaskList populated |
| 4. Execute TDD Cycles | Per step: RED → IMPL → GREEN (+ REFACTOR if applicable) | source code + tests |
| 5. Checkpoint | Run full test suite + linter, batch-update plan statuses | checkpoint log entry |
| 6. Audit & Final Report | Build verification, coverage, mtime discipline, edit landing audit, precondition drift audit, requirements coverage cross-check (warning level), summary | audit log + final report |

See [skills/tdd/SKILL.md](../skills/tdd/SKILL.md) for the canonical main-thread phase definitions.

---

## 4. Per-Step TDD-FSM

Inside Phase 4, each step cycles through a small state machine. The PreToolUse hook ([hooks/pre-edit-tdd-reminder.sh](../hooks/pre-edit-tdd-reminder.sh)) reads the current phase from the state file and allows or denies Edit/Write/MultiEdit tool calls based on it.

```mermaid
stateDiagram-v2
    [*] --> UNINITIALIZED
    UNINITIALIZED --> RED_WRITE: zensu-log.sh --phase RED_WRITE
    RED_WRITE --> RED_RUN: --phase RED_RUN
    RED_RUN --> RED_FAIL: test FAILS (correct RED)
    RED_RUN --> RED_WRITE: test PASSES (fake-green, rewrite)
    RED_FAIL --> IMPL: --phase IMPL
    IMPL --> GREEN_RUN: --phase GREEN_RUN
    GREEN_RUN --> GREEN_PASS: test PASSES
    GREEN_RUN --> IMPL: test FAILS (retry, max 3)
    GREEN_PASS --> REFACTOR: --phase REFACTOR (optional)
    GREEN_PASS --> [*]: next step
    REFACTOR --> [*]: next step

    note right of UNINITIALIZED
      Hook denies all Edit/Write
    end note
    note right of RED_FAIL
      Hook allows test paths only
    end note
    note right of IMPL
      Hook allows iff RED_FAIL
      for this step in history
    end note
    note right of GREEN_PASS
      Hook allows test paths only
      (no prod edits without REFACTOR)
    end note
```

Phase transitions are recorded by invoking the log helper:

```bash
CLAUDE_PLUGIN_DATA="<resolved-plugin-data>" \
  bash "<absolute-plugin-root>/hooks/lib/zensu-log.sh" \
  --phase {PHASE} --step {step_id} [--reason "..."]
```

The top-level `/zensu:tdd` Skill receives Claude's native plugin root/data
substitution and replaces both angle-bracket values before the command runs.
This supporting document is loaded through `Read`, so it deliberately does not
assume a second native-substitution pass. Each stateful invocation passes only
the concrete plugin-data directory to the helper process. The helper reads the
host-exposed `CLAUDE_CODE_SESSION_ID`, validates it against the private immutable
record, and derives its internal selectors in that process only. Do not source
the internal binder, cache its selectors, or use a shared home-directory pointer.

The phase helper mutates workflow state through the Session Control v1 CAS API;
narrative log lines are appended separately by the skill. Its token- and inode-bound lock generations
serialize concurrent processes, recover only dead stale owners, and reject
malformed state instead of resetting its revision. `SessionStart` creates a
mandatory baseline before tools run. A subsequently missing baseline or an
existing malformed, non-object, or unreadable state file is therefore a
fail-closed integrity failure: the all-tool context gate denies further tools,
and the edit/Stop guards deny rather than treating the session as inactive.
A fresh session is required to create trustworthy state.

---

## 5. Hook Gate Behavior

The PreToolUse hook fires on `Edit | Write | MultiEdit` tool calls. It allows or denies based on `(phase, file path type)`.

| Phase | Production file edit | Test file edit |
|-------|---------------------|----------------|
| `UNINITIALIZED` | DENY | DENY |
| `RED_WRITE` | ALLOW | ALLOW |
| `RED_RUN` | (transient, no edits expected) | (transient) |
| `RED_FAIL` | DENY | ALLOW |
| `IMPL` | ALLOW iff this step has `RED_FAIL` in history | ALLOW |
| `GREEN_RUN` | (transient) | (transient) |
| `GREEN_PASS` | DENY | ALLOW |
| `REFACTOR` | ALLOW | ALLOW |

**Test-path detection** ([hooks/lib/zensu-tdd-phase.sh::tdd_is_test_path](../hooks/lib/zensu-tdd-phase.sh)):

1. Path prefix match: `**/test/**`, `**/tests/**`, `**/__tests__/**`, `**/spec/**`, `**/specs/**`, plus top-level variants (case-insensitive)
2. Basename match: `_test.*`, `*_test.*`, `.test.*`, `.tests.*`, `.spec.*`, `.specs.*`, `_spec.*`, `_specs.*`
3. Hard-link rejection: files with link count > 1 fail closed (prevents `ln target.test.ts innocent.ts` bypass)
4. Symlink rejection: `[ -L "$path" ]` → not a test
5. Inline-header sniff (last resort): read first 20 lines, strip BOM, match `^(func Test|describe\(|it\(|test\(|@Test|def test_|#\[test\]|#\[cfg\(test\)\])`. Comment-prefix lines like `// describe(` are NOT matched (anchored at line start, no leading comment chars).

**Hook scope.** With a valid SessionStart baseline, the phase gate is active **only** while the per-session chain-state `active` flag is set — written by `zensu-log.sh --tdd-begin` in Phase 0 of the `/zensu:tdd` skill. A valid inactive baseline exits silently before `--tdd-begin`; it must not be confused with a deleted, malformed, or unreadable mandatory baseline, which fails closed in the all-tool Session Control gate and the edit/Stop guards. This replaces the pre-0.4.0 `CLAUDE_AGENT_TYPE=zensu:tdd-manager` scoping that only worked while TDD ran in a subagent. It remains a deliberate trust-boundary for Claude host-tool workflow decisions, not an OS sandbox against malicious same-UID processes.

**Vanilla implementation mode (`hooks.tddImplementation:false`).** At `--tdd-begin` the mode is resolved ONCE and frozen into the state file's `vanilla` flag; the command echoes the effective mode (`mode: strict` / `mode: vanilla`) so the skill knows which deltas to apply. The config flag is rank 3 of a FOUR-RANK ladder in that resolution — the session choice `/zensu:tdd-mode` recorded wins, then the caller's `--tdd-begin --tdd-mode strict` (a skill's own default; a lone `TDD-MODE: strict` line in the specification is what tells Phase 0 to pass it), then the config, then vanilla. Rank 2 is **escalation-only**: `strict` is the only value the helper accepts, because that value travels through a model-read specification and a spec body is not always user-authored — `/zensu:pr-fix-findings` builds one from PR review-comment bodies. Lowering the discipline stays the user's own `/zensu:tdd-mode --vanilla`. Because the winner is frozen, a switch governs the NEXT chain and never the running one, exactly as a config flip does not. While `vanilla` is `true` the gate exits 0 right after the `active` check — the whole phase matrix above is bypassed, no phase markers are required, and tests are at the agent's discretion. The gate reads ONLY the state flag, never live config: flipping the config mid-session can neither un-gate a strict session nor re-arm a vanilla one (whose phase stays `UNINITIALIZED` and would otherwise deny everything). Still enforced in vanilla mode: the Bash witness, the Phase 5/6 evidence audits (build, coverage, witness cross-check), the review fan-out → judge second pass (`review-judge`, gated by `hooks.reviewJudge`, default on — fresh-read deltas + `Panel-FP:` neutralization between the aspect merge and the consume-mode reviewer) → Finding Verification Gate (step 4c, gated by `hooks.findingVerification`, default on — the model-free `hooks/lib/finding-verify-v1.js` anchor grade plus the main thread's own read of every surviving citation, marking whatever does not hold up `[Unverified — do not fix]` and downgrading it rather than deleting it) → `code-reviewer` → auto-fix loop → `/zensu:self-review`, and the Stop-hook chain guarantee. `--tdd-reset` clears the flag; a later `--tdd-begin` re-freezes it from the then-current precedence chain (session marker → caller flag → config → vanilla). The Stop-hook adoption of a deferred review is the one other place that freezes this flag; it resolves the same chain minus rank 2, which has no carrier there (session marker → config → vanilla). The Stop block reason appends a state legend built from the same frozen flag — `mode=vanilla` / `mode=strict` plus the live `implComplete` / `chainDone` values — because a vanilla session's `phase` and `history` carry no signal and have been misread as a corrupt or never-started chain. Wording only: the routing decision is identical in both modes.

---

## 6. Host Environment and Native Placeholders

| Variable | Where set | Effect |
|----------|-----------|--------|
| `CLAUDE_AGENT_TYPE` | Legacy environment hint. | Never trusted for Session Control or reviewer authorization. Those decisions use the top-level host hook payload. |
| `CLAUDE_PLUGIN_ROOT` | Claude native substitution in top-level Skill/Agent content; hook environment. | Supplies the exact installed helper path. The helper independently verifies that path against its own executable. |
| `CLAUDE_PLUGIN_DATA` | Claude native substitution in top-level Skill/Agent content; hook environment. | Passed to each stateful helper invocation and validated as the private record store. It is not exported by SessionStart. |
| `CLAUDE_CODE_SESSION_ID` | Claude Bash/hook environment. | Host session id used to locate the private record. It is not secret and grants no authority without all record checks. |
| `CLAUDE_ENV_FILE` | Claude shell environment propagation mechanism. | Deliberately ignored: SessionStart neither reads nor writes it, and no plugin-private selector is exported through it. |
| `ZENSU_TDD_GATE` | User sets in shell | Set to `off` to bypass the phase-gate entirely for legitimate non-TDD edits (docs, config, one-offs). |
| `ZENSU_CHAIN` | User sets in shell | Set to `off` to disable the `Stop`-hook review-chain backstop ([hooks/stop-chain-enforcer.sh](../hooks/stop-chain-enforcer.sh)) so the main agent may end its turn without completing the review chain. It is also honored in the session-binding blocks that precede routing, where an outer Autopilot run cannot be read or advanced either. It is not needed for a session whose recorded project root is gone — that state releases on its own. |
| `ZENSU_HOOK_LOG` | Eval wrapper sets per isolated test dir | Opt-in mirror of denial reasons. Hook writes 4 lines (`TDD-Phase-Gate`, `Current phase:`, `Expected:`, `permissionDecision=deny`) on denial. Empty file in production. |
| `CLAUDE_PROJECT_DIR` | Claude host environment/native substitution. | Stable input for fresh registration. Each stateful helper resolves and uses the immutable record's project root even after `CwdChanged`. |

Session Control stores its baseline and all TDD workflow transitions only in
the immutable record-bound project's `.zensu/state`. There is no
caller-controlled state-directory override.

---

## 7. Files Produced Per Task

```mermaid
flowchart LR
    subgraph Inputs
      Spec[Feature Spec]
    end
    subgraph Plan_Phase[Phase 2: Plan + Log]
      Plan[.zensu/plans/<br/>ts_tdd-slug.md]
      Log[.zensu/logs/<br/>ts_tdd-slug.log]
    end
    subgraph Runtime_State[Phase 4: Runtime State]
      State[.zensu/state/<br/>tdd-phase-scv1_hash.json<br/>FSM + reviewRound + stopBlockCount]
      Context[&lt;plugin-data&gt;/session-control/v1/<br/>records/scv1_hash.json]
    end
    subgraph Production[Phase 4: Production Artifacts]
      Tests[test files]
      Code[implementation files]
    end
    Spec --> Plan
    Spec --> Log
    Plan --> State
    Log --> State
    Context --> State
    State --> Tests
    State --> Code
```

The plan + log files form a local, per-run audit pair for the active session;
they are gitignored and not repository provenance. Mutable state files are
also ephemeral per session and live project-locally under `.zensu/state/`; the
immutable session record lives separately under
`CLAUDE_PLUGIN_DATA/session-control/v1/records/`. State filenames use the
domain-separated `scv1_…` key, contain the matching session hash, and increment
a monotonic revision on every atomic mutation. The raw host session id is not
persisted, but Claude exposes it as `CLAUDE_CODE_SESSION_ID` in Bash and hook
subprocesses; it is not a secret or capability on its own. The review-loop
budget (`reviewRound`) and Stop anti-deadlock budget
(`stopBlockCount`) are validated bounded integers in this same CAS document. They
have no independently writable `rounds-*.json` or `*.stopblocks` sidecars.

`SessionStart` is the only context writer. It binds the canonical project and
executed plugin roots, plugin-data directory, plugin version, source revision,
and a digest over all runtime-relevant files. A fresh `startup`/`clear`/`fork`
may create the record; an existing fresh event must still name the bound
project. `resume`/`compact` preserve the existing record's exact project and
workflow-state bytes even when `CwdChanged` reports a descendant or an external
detached worktree. Any session id with no record yet is registered like a cold
start — a `fork` always lands here because its id is new, as does a
continuation whose record was pruned or invalidated by a plugin upgrade —
because leaving it unbound would fail every stateful hook closed for the rest
of the session, which is strictly worse than one ungated gate. A missing or
malformed lifecycle source still fails closed; an unknown but well-formed one
does not, so the next source Claude Code adds cannot repeat that outage.
Only a host payload with neither `agent_id` nor `agent_type` receives `main-v1`.
Claude also reports `agent_type` on `SessionStart` for top-level `claude --agent`
sessions; those events use the same exact reviewer/neutral classifier as
PreToolUse and can never inherit main authority. Claude reports plugin-shipped
agents to hooks through their scoped `agent_type`. `SubagentStart` reads that same parent record and
injects `reviewer-readonly-v1` for the five exact reviewer identities
`zensu:code-reviewer`, `zensu:review-aspect`, and
`zensu:review-judge`, plus the dedicated `zensu:plan-review-worker` and
`zensu:pr-review-worker`. Every other child receives neutral `host-profile-v1`,
including the plugin-scoped PLM identity `zensu:zensu-plm`; that exact PLM
identity is nevertheless subject to the strict read-only capability profile
described below. Claude Code cannot block a child from `SubagentStart`, so the
first all-tool `PreToolUse` hook revalidates session id, plugin root, plugin
data, project, record path, and live runtime digest before every tool call. The
session id plus its private
plugin-data record bind the session; the record's `project_root` remains the
immutable anchor for workflow state. By contrast, the host-reported payload
`cwd` is canonical location metadata, not a session authenticator. It may point
inside the original project or at an external detached review worktree after a
`CwdChanged` event, and relative tool paths resolve against that canonical
current directory without rebinding `project_root`. Missing identity/context,
any record mismatch, runtime drift, or an attempted control-context rebind is
denied there. Legacy transcript, PPID, newest-file, and fallback-id discovery is
deliberately ignored; concurrent fresh sessions therefore remain isolated even
inside the same worktree.

The read-only Autopilot SessionStart sibling follows the same location split.
For `resume`/`compact` it resolves the immutable private record before examining
project state and stays silent when that record is unavailable. Because equal
SessionStart matchers run concurrently, `startup`/`clear` prefer an already
valid record and otherwise use Claude's stable `CLAUDE_PROJECT_DIR`; mutable
payload `cwd` is never an Autopilot-state selector.

The plugin-scoped reviewers and `zensu:zensu-plm` expose only the host's `Read`,
`Grep`, and `Glob` tools. The `PreToolUse` gate repeats that exact allowlist after
context revalidation: no shell, Git, control, MCP, or other tool outside that
trio is available to those identities. Other `host-profile-v1` children retain
ordinary non-command tools granted by their agent frontmatter and the Claude
host, including file, Agent/Task, coordination, and report-writing operations
where the host provides them. They cannot invoke `Bash`, `shell`, `exec`,
`exec_command`, `terminal`, or `command`: arbitrary command execution cannot be
confined by scanning its source text for protected tokens. The plugin gate adds
no separate Agent/Task or nesting policy; Claude's host and agent definition
decide those capabilities, and Claude currently prevents a subagent from
spawning another subagent.

The plan/PR worker pair has a second, workflow-specific boundary. Before spawn,
the interactive main thread creates one private lease generation containing
exact evidence files, exact candidates, and narrow safe subtrees; the lease id
and plugin-data path never enter the worker prompt. Creation canonicalizes path
chains, rejects symlink aliases and unsafe roots, and snapshots identity/content
metadata. Every leased `Read`/`Grep`/`Glob` call revalidates that snapshot, so a
replacement, symlink swap, or other TOCTOU drift fails closed. The workers have
no file mutation, task, messaging, nested-agent, Skill, MCP, Web, or command
capability. They return one raw JSON final message with exact `kind` and `role`;
`SubagentStop` captures it privately, and collection binds the host worker id,
kind, role, size, and schema before the main thread may materialize it. The lease
closes after collection and on every failure path. Repository instructions,
diffs, source text, overlays, and refinement context remain untrusted data and
cannot alter this contract.

For every reviewer, PLM, and neutral principal, `Grep`/`Glob` must name a
concrete safe source/docs/test subtree. A protected root, an ancestor that could
recursively expose protected descendants, or an omitted path whose effective
`cwd` is such an ancestor is denied. Grep content regexes may still mention
terms such as `session-control` or `main-v1`; only traversal roots and path
filters carry this restriction.

For a neutral child, the gate derives the principal only from the trusted hook
payload. It denies command execution independently of command text, blocks
actual canonical access to protected Session Control and workflow-root paths,
blocks every file mutation below the installed-plugin/private plugin-data roots
(including symlink, case, and hard-link aliases), and blocks mutating Zensu
operations. It does not mistake ordinary report text that mentions those terms
for a control attempt, and tool-input prose cannot claim `main-v1`. Mutating
Zensu workflows therefore remain in the interactive main thread and are entered
through the matching skill.

This enforcement boundary is intentionally narrower than an OS sandbox. It
protects Claude host-tool/subagent workflow decisions and serializes
project-local CAS mutations, but it cannot make project-local files a
cryptographic authority against user-authorized build/test programs, external
processes, or a same-UID process racing after a path check. Untrusted repository
code requires an OS sandbox/container, separate identity, and restricted mounts.
Likewise, a third-party MCP tool that exposes arbitrary local execution is
outside this host-tool boundary and must not be granted to an untrusted agent.

---

## 8. Discipline Patches — User-Visible Behaviors

These are the guardrails that protect users from common TDD failure modes. Each is pinned by structure tests in [tests/structure/](../tests/structure/).

| Patch | What it does | User benefit |
|-------|--------------|--------------|
| **1. Rationalization Counters** | Three patterns recognized as agent self-deception: "I'll just write a quick replacement", "I'll commit a placeholder fixture", "user said no questions so I'll guess". Each is labeled a LIE in the agent prompt. | Agent doesn't talk itself into corner-cutting. |
| **2. Hard Ban on substitution** | Forbids substituting a missing required dependency with a hand-rolled equivalent without explicit user approval. | No silent `KNOWN-ISSUES.md` workarounds. No fake adapters. |
| **3. Phase 1.5 Precondition Discovery** | Enumerates every external CLI/secret/endpoint/fixture named in the spec, verifies presence, and on missing → AskUserQuestion (install / substitute / skip). Overrides any prior "no questions" instruction. | Agent stops and asks BEFORE damaging your workspace with placeholder values. |
| **4. Preconditions table in plan** | Plan template includes `## Preconditions` section listing every dependency + verification + user decision. | Auditable record of what was assumed present. |
| **5. Per-step precondition gate** | If a step's IMPL plan references a precondition marked `skip`, the step gets `[!]` status and is bypassed. No partial test, no placeholder. | Skipped dependencies don't leak into half-broken implementations. |
| **6. Phase 6 Precondition Drift Audit** | Greps the log for the contracted tool name versus the user-named substitute. Flags `PRECONDITION DRIFT — {tool}: decision={d}, actual={observed}` when reality diverges from the plan. | Catches silent substitution after the fact. |
| **7. Installed-plugin Claude CLI provider** | Wrapper [scripts/session-control-claude-wrapper.sh](../scripts/session-control-claude-wrapper.sh) invokes pinned Claude Code from a fresh isolated user-scope registry, never with `--plugin-dir`, and emits one wrapper-owned `[control-attestation]`. | Contract runs stay deterministic; live runs prove the real installed cache root, content revision, exact source Git SHA, session hash, runtime digest, state revision, normal/reviewer subagent context, hook sequence, reviewer capabilities, and changed-file hashes. See the [release-gate contract](session-control-release-gate.md). |
| **8. Hook event mirror** | Opt-in via `ZENSU_HOOK_LOG`. Hook writes denial reason lines into the log when the gate fires. | Eval assertions can verify gate behavior without reading hook stderr. |
| **9. Trusted control attestation** | The wrapper reads trusted runtime artifacts before cleanup, neutralizes reserved prefixes in model output, and produces exactly one schema-versioned attestation line. | Assertions never grade model prose or accept a spoofed success claim. |
| **10. Phase 6 Edit Landing Audit** | Implemented by `hooks/lib/zensu-edit-landing.sh` and enforced — `--tdd-complete` refuses without its receipt. Cross-checks every file a step CLAIMED to edit (`IMPL completed — files:` / `WIRED — files:`) against the repo-root-anchored union (`TOP` from `git rev-parse --show-toplevel`) of `git -C "$TOP" diff --name-only HEAD` and `git -C "$TOP" ls-files --others --exclude-standard`, and re-runs on every round that changed a file, including the terminal self-review round. Flags `EDIT NOT LANDED — {step_id}: claimed {file}, git shows no change`. Runs in strict AND vanilla mode. | A mechanical or bulk replacement that matched nothing leaves no diff, so no reviewer ever sees it and the green suite reads as confirmation. This is the check that catches it. |
| **11. Requirements-table gate** | Implemented by `hooks/lib/zensu-plan-requirements.sh` and enforced — `--tdd-complete` refuses a chain whose plan carries no `## Requirements` section, or whose `AC-###`/`FR-###` rows are all still the template's `{curly}` placeholders. The plan comes from `--plan <path>` when the skill passes it, else from the edit-landing receipt's record of the run log it audited (`.zensu/logs/<stem>.log` → `.zensu/plans/<stem>.md`), which anchors the check to the running session rather than to whatever plan is newest. Same scope as patch 10; bypass with `ZENSU_REQUIREMENTS_GATE=off`. Runs in strict AND vanilla mode. | `/zensu:converge` anchors its flow-back audit on that table and reports nothing without one — and in `/zensu:autopilot` the CONVERGE stage is the only edge into `OPEN_PR`, so a missing table let a mandatory gate pass on an audit that examined nothing. |

---

## 9. Auto-Review Chain

At Phase 6 the `/zensu:tdd` skill marks `--tdd-complete` and spawns `zensu:code-reviewer` itself. The `Stop` hook ([hooks/stop-chain-enforcer.sh](../hooks/stop-chain-enforcer.sh), registered on the `Stop` matcher in [hooks/hooks.json](../hooks/hooks.json)) guarantees the chain even if that spawn is skipped: it blocks the main agent from ending its turn while `implComplete && !chainDone`. Reviewer findings are routed back into the main thread by [hooks/post-review-tdd-delegate.sh](../hooks/post-review-tdd-delegate.sh) to be fixed in-thread under the still-active phase-gate, then the reviewer is re-spawned — looping until PASS or max rounds, after which the terminal `/zensu:self-review` stage runs (see below).

```mermaid
flowchart LR
    P6[Phase 6 complete<br/>--tdd-complete] --> Spawn[skill spawns<br/>zensu:code-reviewer]
    Stop[/Stop hook backstop:<br/>block until chainDone/] -.guarantees.-> Spawn
    Spawn --> Reviewer[zensu:code-reviewer<br/>5 perspectives:<br/>conventions, bugs,<br/>architecture, tests, security]
    Reviewer --> Findings{Critical or<br/>Important?}
    Findings -->|Yes| Fix[main agent fixes<br/>in-thread RED→GREEN<br/>gate active]
    Fix --> Spawn
    Findings -->|None or<br/>max rounds| CRD[--code-review-done]
    CRD --> SelfRev["/zensu:self-review<br/>terminal stage:<br/>7-dim self-reflection"]
    SelfRev --> MustFix{must-fix and<br/>not yet fixed?}
    MustFix -->|yes| SRFix[1 fix round<br/>RED→GREEN gate active<br/>set selfReviewFixed]
    SRFix --> SelfRev
    MustFix -->|no / latch set| Done([self-review runs<br/>chainDone · Final Report])

    style Reviewer fill:#fef3c7,stroke:#92400e,color:#1e293b
    style SelfRev fill:#dcfce7,stroke:#166534,color:#1e293b
    style Fix fill:#dbeafe,stroke:#1e40af,color:#1e293b
    style Stop fill:#fee2e2,stroke:#991b1b,color:#1e293b
```

Reviewer returns findings in three tiers:

- **Critical**: blocks ship. Auto-fix attempted.
- **Important**: should land before merge. Auto-fix attempted.
- **Suggestions**: nice-to-have. NOT auto-fixed.

Auto-fix loop runs up to 5 rounds (configurable via `autoFixMaxRounds` in plugin settings). On the 5th round, the harness emits "max rounds reached, manual fix required" and hands off to the terminal self-review stage (below) instead of stopping — preventing infinite loops on intractable findings.

**Terminal self-review stage (0.5.0+).** When `hooks.selfReview` is enabled (default), the code-reviewer chain does NOT close at convergence. On PASS, suggestions-only, or max-rounds, [hooks/post-review-tdd-delegate.sh](../hooks/post-review-tdd-delegate.sh) marks `--code-review-done` and hands off to the `/zensu:self-review` skill ([skills/self-review/SKILL.md](../skills/self-review/SKILL.md)) — a main-thread terminal stage ported from `/reflect`. It re-reads the session's own changes across seven dimensions (architecture, consistency, edge-cases, test coverage, security, simplification, conventions), takes at most ONE fix round under the still-active phase-gate if a must-fix surfaces (latched by `selfReviewFixed`; it never re-spawns the code-reviewer), then owns the chain terminus: it runs `--chain-done` and renders the final report including a `## Self-Review Summary`. The `Stop` hook ([hooks/stop-chain-enforcer.sh](../hooks/stop-chain-enforcer.sh)) routes to self-review while `codeReviewDone && !chainDone`. Set `hooks.selfReview=false` to restore the pre-0.5.0 behavior where code-reviewer convergence closes the chain directly.

**Terminus forms and the zero-change gate.** A standalone chain closes either ticket-bound (`--chain-done --claimed-review-ticket <ticket>`, the normal reviewed path) or unqualified (`--chain-done` alone). The unqualified form can only ever bind a chain in which no review ticket was consumed, so its one sanctioned use is the ZERO-file-change exception the Stop block names — and `zensu-log.sh` verifies that claim instead of trusting it: while `git diff --name-only HEAD` or an untracked non-ignored file still reports a changed file, the terminus is refused with a non-zero exit and the chain stays open. A project root that is not a git worktree, or a repository without a HEAD commit, cannot be evaluated and keeps the legacy behavior. Autopilot-bound chains are unaffected — they carry `--outcome no-changes` into the durable run's audited receipt. If the state says `codeReviewDone=true` but its consumed review ticket is unbindable, the Stop block routes to a repair branch: `/zensu:reset-review-limit` cannot help there (it rebinds a *retained* consumed ticket), so the block names a fresh `/zensu:tdd` entry, whose `--tdd-begin` resets the review ticket, round counter, and chain flags in one transition.

**Reading and repairing a chain that will not advance.** `zensu-log.sh --chain-status` is the read-only diagnosis for this FSM: it classifies the workflow document into one shape (the roster lives in `NEXT_COMMAND` in [hooks/lib/chain-recovery-v1.js](../hooks/lib/chain-recovery-v1.js) and is mirrored by the shape table in [skills/recover-chain/SKILL.md](../skills/recover-chain/SKILL.md)) and names the supported next command, so "the chain is stuck" can be distinguished from "a supported command has not been run yet". Exactly one shape is a true wedge: a pending `reviewRearm` receipt whose `runId`/`attempt`/`chainId` disagree with the document itself. The core validates that receipt's shape only, while `_tdd_issue_review_ticket_critical` additionally requires it to match the current generation, so such a receipt is a legal document that makes `--review-ticket` refuse permanently — and no in-plugin transition can produce it (every writer of the receipt matches the link, and every writer or deleter of the link fields drops the receipt in the same mutation), so it indicates an externally corrupted or restored document. `zensu-log.sh --chain-recover` (surfaced as `/zensu:recover-chain`) repairs exactly that shape under the same lease every ticket writer takes: it drops the receipt and records one `history` entry, in one revision, and writes nothing else. It never writes a terminal flag, never resets `reviewRound`/`stopBlockCount`, never discards an outstanding ticket, never unbinds an Autopilot generation, and refuses while a `deferredReviewClaim` is outstanding — so it restores reachability without granting budget. It also refuses (rather than normalizes) an inconsistent ticket slot: writing `reviewTicketConsumed=true` would complete the precondition of the unqualified no-ticket terminus, which would make the repair a shorter path to a closed chain than the review itself. Shape classification and the receipt predicate live in [hooks/lib/chain-recovery-v1.js](../hooks/lib/chain-recovery-v1.js), shared by the status verb, the recovery transaction, the ticket issuer and `/zensu:doctor`.

**When the host refuses the reviewer spawn.** The block above assumes the demanded `zensu:code-reviewer` spawn is *possible*. It is not when the host permission layer refuses it — an auto-mode classifier verdict, a `deny` rule, or a person declining the prompt. A refused tool call never executes, so no PreToolUse or PostToolUse hook can observe it, and the enforcer would otherwise repeat the same impossible instruction until its Stop cap (`autoFixMaxRounds + 3`) released the guard. The evidence lives in the transcript the Stop payload points at (`transcript_path`), and [hooks/lib/reviewer-spawn-denial-v1.js](../hooks/lib/reviewer-spawn-denial-v1.js) requires **three** conditions together before it calls anything a refusal: the `tool_result` is keyed by `tool_use_id` to an `Agent`/`Task` call whose `subagent_type` is the reviewer, the host's own `is_error` is `true`, and the result text *starts* with one of the `DENIAL_MARKERS` (host literals read out of the installed Claude Code binary, matched as prefixes because the host appends a `Reason:` tail). Keying alone is not enough and assuming it was is a defect this module already carried: for an `Agent` call the tool_result body IS the subagent's returned message, so a reviewer that merely quotes a denial literal would have been read as a refusal. Only the most recent reviewer spawn counts, so a later successful one clears the verdict. A result that carries the host's `is_error` but matches no marker is `errored`, NOT `clear`: it is a refusal shape the module does not recognize, and reporting it as a clean spawn would have the enforcer retire a note an earlier recognized refusal wrote. On a `blocked` verdict the Stop reason names the permission layer as the cause, prints the `permissions.allow` rule `Agent(zensu:code-reviewer)`, states that only the user can apply it and that the agent must never edit a settings file to widen its own permissions, sanctions exactly ONE further attempt once the user says they applied it — withdrawn once the scanner's own `denials` count shows a retry was already spent and refused again, so the sanction cannot be re-issued on every blocked Stop — and offers no terminus beyond the zero-change one — closing a chain with real changes there would claim a review that never ran, which the standalone spelling of that command refuses to do (an Autopilot-bound chain carries `--outcome no-changes` into its audited receipt with no worktree check, as the paragraph above notes). It deliberately does not disclose the Stop cap count. The cap-release diagnosis is emitted above the bound arms so every cap sub-path carries it, not only the standalone release, and the hook leaves a best-effort note at `.zensu/state/reviewer-spawn-denied-<session-key>.json` — written by a per-process exclusive temp file plus rename, refusing a pre-planted link — so `/zensu:doctor` can report it outside that turn. Only a branch that consulted the probe writes one, and the cap path — which consults it above the convergence split — is guarded by hand, so a converged chain never mints a note. It is retired on the next Stop that sees the chain converged (so a refusal from earlier in the same session cannot outlive the spawn that finally succeeded), the chain closed, the implementation unfinished, no active session, either inner-guard escape, an Autopilot escape release, or a BLOCKED outer run owning the current inner generation, on the cap path once the chain has converged, and on a `clear` verdict. Because a session that never Stops again cannot retire its own note, the doctor row also ages one out against the same TTL `pending-review.json` uses, and counts a note as a refusal only when it parses with the schema, kind and timestamp the writer issues AND a workflow document for the same session sits beside it — the state directory is writable from inside the session, so an unbound note is not this plugin's word; a timestamp in the future ages out rather than living forever — a file it cannot vet is reported as one this plugin did not write, never as a refusal. The scanner is a diagnostic, never a gate: an unreadable transcript, a FIFO or symlinked path, a missing field, or a missing module leaves every existing routing decision untouched. Both halves of the note — the write and the clear — run under the same external lease every other writer of `.zensu/state/` takes; it was previously the only artifact there written with none, so a clear could unlink a note a concurrent write had just published. The lease is best-effort in the same sense the note is: when it cannot be acquired the operation still runs, because failing to write the note must never change the Stop decision. And because a session that never Stops again cannot retire its own note, any Stop in that project now reaps one that is unbound or past the TTL — the same TTL, from the same config key, that the doctor ages a row out against, so the sweep changes which files exist and never which findings are reported. A note it cannot parse is deliberately left alone: the doctor reports that as a file this plugin did not write, and deleting it here would destroy something this plugin does not own. **Known gap:** the verdict has no chain-generation bound, so after a cap release and a fresh `/zensu:tdd` the old refusal is still the newest one in the transcript — which is what the one-further-attempt sentence exists to cover. Bounding it would need a "when did this generation arm" instant that the workflow document does not carry: `--tdd-begin` writes no history entry, and `history[].ts` stays empty in vanilla mode where the FSM is never driven. Supplying one is a schema change and therefore a MINOR release, which is why the misroute — bounded to a single Stop, and self-correcting as soon as one spawn is attempted — is accepted instead. Pinned by `tests/structure/test-stop-enforcer-self-review-routing.sh` (T13-T35; there is no T20 — the unit-suite driver that carried that label was renumbered to T26 when the scenarios around it grew), `tests/structure/reviewer-spawn-denial-v1.test.js`, the `P1q`-`P1qr` checks in `tests/structure/test-doctor.sh`, and S14/S15 in `tests/structure/test-autopilot-stop-enforcer.sh` for the two Autopilot-escape retire sites the routing suite cannot reach.

**When the session binding itself cannot be resolved.** Before any routing, the Stop hook must bind the event to the immutable Session Control record of its session. Several states make that impossible, and they split into two groups.

**Three states release.** Two of them because neither leaves any workflow state to enforce, so nothing is waived by letting the turn end. A session with **no record at all** never had a workflow document. A session whose **recorded project root no longer exists** — a deleted or recycled worktree — had one at `<project_root>/.zensu/state/`, and it died with the directory; the binder rejects the record with `session-control-v1: context project root does not exist`, and because the record is immutable, no Stop could ever prove completion from it again. That state used to block forever, which left the session unable to end a turn *and* unable to run `/zensu:doctor` to find out why. It now releases, with the cause, the dead path and both remedies on stderr — re-create exactly that directory to resume the recorded session, or start a new session — and, like the no-record release, it advertises no bypass, because none is needed.

The **third** release is different in kind: the record is intact and the only disagreement is that the running installation declares an incompatible plugin lineage — a mid-session update across a breaking boundary. The binding that resolves the project root is what failed, so the chain cannot be read from here at all; the guarantee is **deferred, not waived** (the workflow document survives untouched and the next Stop after an adoption enforces it again), and the stderr names both declared versions plus `/zensu:adopt-session --confirm`. Blocking instead would loop a session whose Edit and Bash channels are already denied, so the remedy would never reach the user. For a DOWNGRADE the same predicate matches while adoption refuses, so the release is permanent until the newer version is re-installed — the message says so.

**The rest still block**, each with its own reason: the Session Control library is missing from the installation, the record cannot be bound for any other reason (a foreign plugin installation, runtime digest drift, tampering, an unreadable record), or the record no longer resolves against a project root that **still exists** — a symlinked, moved, or re-created directory. Because these blocks sit *above* the routing logic, `ZENSU_CHAIN` and `hooks.chainEnforcer` are evaluated in them too. Both switches are named on stderr for the user and deliberately kept out of the model-facing reason; a release through a switch logs that no completion was proven, only that the guard was waived.

**Chain-end combined summary.** At every chain-end branch — PASS / zero findings, suggestions-only stop, and max-rounds convergence — `hooks/post-review-tdd-delegate.sh` appends a `CHAIN-END SUMMARY` directive to its `additionalContext` output. The main agent then renders a **table-first** summary block — each section is a table plus at most one line of text, never a paragraph, the sole exception being `## Open` — in this fixed order:

| Section | Content |
|---|---|
| `## Problem` | Exactly one sentence: the feature/bug/need this session addressed. |
| `## What I built` | A `# \| Deliverable \| Status \| Link` table, then a `Check \| Verdict` audit table (feature title, files modified, tests created, build status, mtime audit verdict, edit landing verdict, coverage status, plan + log paths) whose non-clean edit-landing lines are carried verbatim, then — when the plan carries a `## Requirements` table — an `ID \| Status` table giving per-requirement status keyed by its stable AC-###/FR-### IDs. |
| `## How I built it` | One line (TDD discipline, final reviewer verdict, findings count by severity, files reviewed), then a `Round \| Findings \| Fixed \| Result` table covering EVERY review round 1..N — clean verification rounds included, marked `PASS — 0 findings, nothing to fix`, so the reader sees the chain converged; skipped only when no review round ran. |
| `## Open` | An `Item \| Type \| Next step` table of deferred suggestions / max-rounds findings requiring manual fix, plus — in the `hooks.selfReview` default, where `/zensu:self-review` renders this section — one row per `EVIDENCE GAP` / `EVIDENCE CONTRADICTION` line the cross-check emitted (carried verbatim, with each `\|` escaped) and one row when the cross-check could not run at all. The single line `Nothing open.` applies only when that table has no rows whatsoever. Then the bypass-ledger disclosure line `Gates bypassed during this session: <output>`. Then, for a **standalone** chain only — never an Autopilot-bound one, which already ran converge report-only at the autopilot skill's own step 2b — and only when the session plan carries a `## Requirements` table, one closing line offering `/zensu:converge` as an optional flow-back audit. That offer is never run unasked and never gates or delays the chain terminus. This is the one section that may carry more than a single line of text. |
| `## TL;DR` | Exactly one sentence, always last. |

This replaces the prior terse-stop behavior so the user retains visibility into the full chain. When `hooks.selfReview` is enabled (default), the terminal `/zensu:self-review` stage renders this summary and inserts a `## Self-Review Summary` section (a `Dimension | Verdict | Note` table) before `## Open`. `hooks.combinedSummary` in `~/.zensu/config.json` (default `true`; set `false` to restore terse stop) governs the delegate-rendered summary only — it has exactly one consumer, `hooks/post-review-tdd-delegate.sh`, so it applies on the `hooks.selfReview:false` path; with self-review enabled the terminal stage renders the report unconditionally. Contrast `autoFixIncludeSuggestions` which defaults to disabled — `combinedSummary` defaults the other way.

---

## 10. Four-Channel Logging Contract

Every `/zensu:tdd` run uses four channels:

| Channel | What | Lifetime | Format |
|---------|------|----------|--------|
| **Plan** | Design decisions, step table, Preconditions, audit checklist | Per session. **Publication-safe by construction** — gitignored in THIS repo, deliberately committed as an audit trail in many consuming repos | Markdown, English-only |
| **Log** | Execution trace: phase markers (`RED_WRITE`, `RED_FAIL`, `IMPL`, `GREEN_PASS`, `REFACTOR`), attempt counts, audit results | Per session. **Publication-safe by construction** — same split as the plan | Append-only timestamped text, English-only |
| **State** | Current FSM phase per session, history array | Ephemeral per session | JSON |
| **Witness** | Independent record of every Bash tool invocation (cmd, exit code, stdout tail, interrupted flag) | Ephemeral per session — **local only, gitignored, never committed** (consumed solely by the in-session Phase 6 cross-check); under promptfoo it lives in the per-test isolated dir | Append-only timestamped text, JSON-escaped fields |

The agent appends to the log via:

```bash
CLAUDE_PLUGIN_DATA="<resolved-plugin-data>" bash "<absolute-plugin-root>/hooks/lib/zensu-log.sh" \
  append --log "${CLAUDE_PROJECT_DIR:-.}/.zensu/logs/{ts}_tdd-{slug}.log" \
  --message "<message>" --start "$SESSION_EPOCH"
```

`append` is the WRITER, and that is the point of it. Until it existed the helper
only ever returned the timestamp PREFIX and the model appended the line itself
with `printf … >> {log}` — so the message never passed through the plugin and
nothing could rewrite what it carried. It does two things: resolves the user's
configured `logging.timestampStyle` (`wall`, `relative`, or `none`) so the format
is consistent across runs, and redacts the message through
`hooks/lib/zensu-artifact-redact-v1.js` (see [Publication safety](#publication-safety-of-the-plan-and-log)).
Add `--truncate` to create the file instead of appending. Do not inline
`$(date +%H:%M:%S)` — that bypasses the user's preference — and do not redirect
into the log by hand, which bypasses the redaction.

`append` deliberately carries **no leading `--`**, so it does not select the
Session Control binding case at the top of `zensu-log.sh`: a log append keeps
working in a shell where `CLAUDE_CODE_SESSION_ID` or `CLAUDE_PLUGIN_DATA` is
absent. It derives the project root from the log path itself
(`<root>/.zensu/logs/x.log`), which needs no environment at all, and adds
`CLAUDE_PROJECT_DIR` as a second candidate root when that variable is set — the
witness hook resolves the root from the Session Control record instead, and the
two must substitute identically or the equality match below reports a gap.

**That derivation is ENFORCED, not assumed.** The destination must resolve to a
real `<root>/.zensu/{plans,logs}/<file>`, with the artifact directory
canonicalized, and the verb refuses otherwise. Without that check `append` would
be a write/truncate primitive with a caller-supplied destination that no Bash
gate can see: it carries none of the redirect, `tee`, `sed -i`, `dd` or heredoc
tokens `bash-source-write-parse.js` recognizes as a channel, so rules (A)/(B) of
the source-write gate never judge it. The same check closes the quieter half — an
unrecognized destination used to leave the derived root empty, which SKIPPED the
project-root rule and wrote a partially redacted line under exit 0.

`--truncate` is deliberately NOT gated on `CLAUDE_PROJECT_DIR`. An earlier
revision made it refuse without that variable and broke the shipped Phase 2
recipe outright: the variable is absent from the model's Bash environment on this
host, which is exactly why `{log_file}` is rendered from
`${CLAUDE_PROJECT_DIR:-.}`. What constrains the destructive mode is the module —
the `logs` bucket only, never a `witness-` name, a canonicalized artifact
directory, and a descriptor judged for `isFile`/`nlink`/dev+ino — not an ambient
variable the caller sets anyway. When it IS set it still travels as
`expectedRoot`, so a bound session gets the stricter check for free.

It does require `node`, and refuses loudly without it rather than writing an
unredacted line — a host without `node` cannot arm a chain in the first place, so
there is no session in which that refusal costs a log entry. `--message` must
carry a value: a flag consumed as the last token would otherwise append a
timestamp-only line to a committed audit log.

### Publication safety of the plan and log

Consuming repos commit both artifacts as an audit trail and may later
open-source the repository. A scan of ~27k committed log lines across four such
repos found **no credential values** and ~436 lines carrying an absolute
developer path (`/Users/<name>/…`), almost all of them inside the `cmd="…"`
field of a CHECKPOINT/AUDIT line, because that field quotes a shell command
verbatim and those commands routinely begin
`cd "/Users/<name>/IdeaProjects/<product>/<repo>/.claude/worktrees/<name>"`.

`hooks/lib/zensu-artifact-redact-v1.js` is the single source of truth and
applies three rules **in this order**: the project root becomes `<project>`,
`$HOME` becomes `~`, and any residual `/Users/<seg>`, `/home/<seg>` or `/root`
prefix becomes `<home>`. Rule 1 must precede rule 2 because the project root is
normally nested under `$HOME`; the residual rule is what makes the guarantee
checkable rather than best-effort. Secret **names** are deliberately NOT
redacted — a name grants no access, and this repo's own workflows carry
`secrets.GITHUB_TOKEN` in public. Credential **values** belong to a different
gate (`hooks/pre-write-secret-scan.sh`).

Three writers apply it:

| Writer | What it covers |
|--------|----------------|
| `zensu-log.sh append` | the narrative log, at write time |
| `hooks/post-bash-witness.sh` | the witness `cmd=` field only — see below |
| `hooks/post-artifact-redact.sh` | the plan (the named `file_path` on PostToolUse `Edit\|Write\|MultiEdit`), plus a bounded sweep on BOTH matchers that catches a hand-rolled `printf >>` and a subagent-written artifact |

The witness is gitignored **in this repository**, and the plugin ships nothing that
makes that true in a consuming one. It writes to
`.zensu/logs/witness-<session-key>.log` — the exact directory, and a name matching
the exact glob, that consuming repos are told to commit — while being the one file
there with a raw `tail=`, no credential scan and an explicit exclusion from every
redaction path. `.zensu/state/` has the same exposure. Nothing in the plugin reads,
writes or checks a consuming repo's `.gitignore`, so this is a rule the consuming
repo has to carry itself:

```gitignore
# Zensu — commit the audit trail, never the ephemeral session state.
.zensu/state/
.zensu/logs/witness-*.log
```

With those two lines in place the witness needs no publication safety of its own.
Without them it is published unredacted, and no part of this design notices. Its `cmd` is redacted for **symmetry**: `zensu-evidence-crosscheck.js`
matches a claim against a witness entry by equality, so redacting one side only
would turn every claim whose command names an absolute path into an
`EVIDENCE GAP`. Its `tail` is deliberately left RAW. Nothing compares it — the
equality match reads `cmd` only — and its single reader is the failure-marker
scan, where redaction is purely subtractive: a `failed` token sitting inside an
absolute path would be swallowed with the path and an `EVIDENCE CONTRADICTION`
would silently downgrade to `verified`.

**One protection was removed and then RESTORED at the new chokepoint.** The old recipe wrote the log with `printf … >> {log}`,
which `hooks/lib/bash-source-write-parse.js` reports as a write channel, so
`hooks/pre-write-secret-scan.sh` scanned the command text — log message included.
`append` carries no redirect, so that incidental scan no longer fires on a log
line. It was never a designed protection, but the reason is not the one an earlier
revision of this paragraph gave: `hooks/lib/secret-scan-decide.js` has no
extension filter at all — it scans the whole command text whenever a channel is
present — so the old redirect form genuinely WAS scanned, and the loss is real
rather than incidental. It also covers both buckets, not just a log line. What
makes it acceptable is that `hooks/pre-write-secret-scan.sh` declares itself
"deliberately NOT a security boundary", and the scan still covers every non-`pathExempt`
Edit/Write/MultiEdit payload — that gate exempts `tests?/`, `specs?/`,
`__tests__/`, `testdata/`, `evals/`, `fixtures/` and `*.example.*` — and every real Bash write channel. Teaching the
shared parser a new channel form would pull the source-write gate's rules
(A)/(B)/(C) onto it too, which is why `append` enforces its own containment
instead. `append` now runs the same curated rules (`hooks/lib/secret-patterns.js`)
over the message before it writes, and REFUSES on a match rather than redacting —
a credential value is not a location, and rewriting one silently would hide it
from whoever has to rotate it. Both escapes the gate
teaches are honoured — `ZENSU_SECRET_SCAN=off` and the `zensu-secret-allow` line
marker, which the refusal names first because it stays visible in the committed
artifact. `hooks.secretScan:false` is deliberately NOT consulted: the config
accessor spawns `node`, and this runs once per log line. The control is
back where the write happens; what is genuinely gone is only the incidental
coverage of the surrounding shell command, which never carried the message.

**The witness log is still written by a shell redirect**, not through
`writeArtifactLine` — which in fact refuses any `witness-` name outright, so the
"the write happens inside the module" invariant is a property of the two
publishable artifacts, not of everything under `.zensu/logs/`. The witness is
rewritten every run and gitignored **in this repository**, so the
descriptor-judged write buys it nothing here; saying so keeps the invariant from
being read as directory-wide. A consuming repo only gets that property by adding
the two `.gitignore` lines above — the plugin cannot add them for it.

**This is writer-side only. No committed OBJECT is rewritten.** The ~436
already-committed lines carrying absolute paths across four consuming repos stay
in git history exactly as they are, and no repo becomes safe to open-source
because of this change alone. One nuance worth stating rather than glossing: the
sweep filters on mtime and knows nothing about git, so an already-committed
artifact whose mtime is refreshed re-enters the window and IS redacted in the
working tree — which shows up as an ordinary uncommitted diff, never as a rewrite
of anything already recorded. What changes is that everything written from now on
is publishable, so committing these artifacts stops adding to that pile.

**Bounds, stated rather than implied.** The rule is textual: a path spelled
through a symlink or an alias that matches no known root is not caught (the one
alias pair handled by hand is macOS's `/private/{tmp,var}`). A git repository
root ABOVE the project root is covered only insofar as `$HOME` covers it. The
PostToolUse sweep — on BOTH registered matchers — only revisits artifacts modified in the last 5 minutes, so plans
from earlier runs are out of reach — this is a writer-side fix, not a history
rewrite. And nothing here can recognize a customer name, an internal hostname,
or a German sentence, which is why the plan template and `skills/tdd/SKILL.md`
carry the authoring rules (English-only, repo-root-relative paths) as well.

Workflow-state phase transitions are atomic:

```bash
CLAUDE_PLUGIN_DATA="<resolved-plugin-data>" \
  bash "<absolute-plugin-root>/hooks/lib/zensu-log.sh" \
  --phase {PHASE} --step {step_id} [--reason "{reason}"]
```

This command updates only the state document through one Session Control v1 CAS
transaction. The CAS serialization prevents lost state revisions between
parallel processes. Narrative log appends use the separate command above and
are intentionally not part of the state transaction.

### Witness channel — anti-hallucination evidence

The witness log at `${CLAUDE_PROJECT_DIR:-.}/.zensu/logs/witness-<scv1-session-key>.log` is written automatically by the `hooks/post-bash-witness.sh` PostToolUse hook on every Bash tool call. Its `cmd` is redacted on the RAW string before the JSON encoding, by the same function the narrative log uses; the `tail` is deliberately left raw — see [Publication safety](#publication-safety-of-the-plan-and-log) for both halves of that rule. The hook records lines only while that exact Session Control key's chain-state `active` flag is set; it never scans for or adopts another session's state. Disable it with `ZENSU_TEST_WITNESS=off`. The **witness** is local-only and gitignored everywhere — single-session anti-hallucination evidence with no audit value past the run that produced it. The narrative `.log` and the plan are a different case: gitignored in THIS repository (`.gitignore` ignores `.zensu/*` except `config.json`), and deliberately committed as an audit trail in many consuming repos, which is what the redaction above exists to make safe.

Each line has the form:

```
[HH:MM:SS] BASH cmd="<JSON-escaped command>" exit=<rc|?> tail="<JSON-escaped last 200 chars of stdout>" interrupted=<true|false>
```

In practice `exit=` is almost always `?`: Claude Code's Bash `tool_response` carries no `exit_code` field (only `stdout`/`stderr`/`interrupted`/`isImage`), so the witness corroborates a run by `cmd=` + the stdout `tail=`, never by exit code. `interrupted=true` flags a killed or timed-out run. The tail is **stdout only** — a runner that prints its failure summary to stderr yields an empty `tail=`, so result-corroboration cannot fire there and the `cmd=` match remains the gate.

The witness log is the source of truth for Phase 5/6 cross-checks. The agent prompt mandates that every test/lint/build run logged in Phase 5 (`CHECKPOINT — cmd="X" exit=N result="..."`) and Phase 6 (`AUDIT — cmd="X" exit=N result="..."`) use the literal command string sent to the Bash tool. Phase 6 step 1 then runs `grep -F -q 'cmd="X"' witness.log` for each claim; an unmatched claim becomes `EVIDENCE GAP — cmd="X" claimed but not in witness log` and marks Phase 6 NOT complete.

Non-Bash test invocations (rare; e.g. an MCP test runner) use the `via=tool_name claim="..."` escape clause instead of `cmd="..."`. Audit treats `via=` as a known-limit (no cross-check possible) and surfaces it prominently in the final report.

---

## See Also

- [skills/tdd/SKILL.md](../skills/tdd/SKILL.md) — canonical main-thread workflow skill
- [hooks/pre-edit-tdd-reminder.sh](../hooks/pre-edit-tdd-reminder.sh) — gate enforcement
- [hooks/lib/zensu-tdd-phase.sh](../hooks/lib/zensu-tdd-phase.sh) — state file I/O
- [hooks/lib/zensu-log.sh](../hooks/lib/zensu-log.sh) — log + phase helper CLI
- [hooks/hooks.json](../hooks/hooks.json) — hook registrations
- [scripts/claude-promptfoo-wrapper.sh](../scripts/claude-promptfoo-wrapper.sh) — eval provider
- [evals/tdd-manager-pretool/](../evals/tdd-manager-pretool/) — 13 promptfoo scenarios verifying the discipline
- [tests/structure/](../tests/structure/) — the structure suites pinning the contract
- [CLAUDE.md](../CLAUDE.md) — repo conventions (English-only, version bumps, PR workflow)
- [CHANGELOG.md](../CHANGELOG.md) — release history
