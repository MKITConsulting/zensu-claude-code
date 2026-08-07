<p align="center">
  <a href="https://zensu.dev"><img src="assets/zensu-logo.svg" alt="Zensu" width="120"></a>
</p>

# Zensu Plugin for Claude Code

[![License: FSL-1.1-Apache-2.0](https://img.shields.io/badge/License-FSL--1.1--Apache--2.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.16.1-green.svg)](CHANGELOG.md)

Zensu is a Product Lifecycle Manager that treats features as first-class citizens. This plugin covers the **entire development lifecycle** inside Claude Code — from product planning through disciplined implementation to release readiness.

## The Three Layers

```
Planning              →  Implementation  →  Tracking
main-thread skills       /zensu:tdd         Zensu Dashboard
/zensu:bootstrap         code-reviewer      (Web UI)
/zensu:ghost-scan        auto-fix loop
/zensu:implement         (main thread)
```

**Layer 1 — Planning (WHAT is being built?):** Bootstrap a greenfield product from a vision document (`/zensu:bootstrap`), or scan an existing codebase to discover and import undocumented features (`/zensu:ghost-scan`) — or, for a brownfield repo that *also* ships a forward plan doc, run the **hybrid**: ghost-scan what is built, then add the plan's not-yet-built items as `planned` features. All end with features tracked in Zensu with security profiles, user journeys, and pricing tiers. Each discovered feature is seated at a **v1 build-out baseline** (a revision); features grow from there through deeper revisions (stages) and subfeatures (parts).

**Layer 2 — Implementation (HOW is it built securely?):** `/zensu:tdd` runs in the main thread in vanilla implementation mode by default. Opt-in strict TDD (Test-Driven Development — write a failing test first, then the minimum implementation to make it pass, then refactor) is available via `hooks.tddImplementation:true` and enforced by the PreToolUse RED→IMPL→GREEN FSM gate (`pre-edit-tdd-reminder.sh`). Both modes keep the evidence audits and guaranteed read-only review chain: five parallel specialist aspects → optional judge (default on) → consume-mode code-reviewer → auto-fix loop → self-review.

**Layer 3 — Tracking (HOW is progress tracked?):** Web dashboard for POs and stakeholders — security scores, tier matrix, journey health, coverage trends. No terminal required.

## Agent & Workflow Overview

The Implementation layer shows both modes: **vanilla** (`hooks.tddImplementation`
default `false`) skips the RED→GREEN ceremony and lets the edit gate pass
through; set it `true` for the strict gate. The review chain and evidence audits
run in both.

```mermaid
flowchart TD
    subgraph Planning["Layer 1: Planning"]
        A1["/zensu:bootstrap<br/>(greenfield)"] --> B["Main-thread skill workflow"]
        A2["/zensu:ghost-scan<br/>(brownfield)"] --> B
        B --> C["Features in Zensu"]
    end

    subgraph Implementation["Layer 2: Implementation"]
        C -->|"/zensu:implement"| D["Load Feature Context"]
        PLAIN["Plan approval (ExitPlanMode)<br/>plain Claude Code, no Zensu"] -->|"ask, then invoke skill on yes"| E
        D --> E["/zensu:tdd skill<br/>(main thread)"]
        E --> MODE{"hooks.tddImplementation?"}
        MODE -->|"false · vanilla (default):<br/>no RED→GREEN, gate passes through"| VAN["IMPL — write code directly<br/>(tests at discretion)"]
        MODE -->|"true · strict (opt-in)"| RED["RED — write failing test"]
        VAN --> K
        RED --> IMPL["IMPL — minimum code"]
        IMPL --> GREEN{"GREEN — test passes?"}
        GREEN -->|"No (≤ 3 retries)"| IMPL
        GREEN -->|"Yes"| NEXT{"More steps?"}
        NEXT -->|"Yes"| RED
        NEXT -->|"No"| K["code-reviewer Agent"]
        K --> L["Review Report"]
        L -->|"auto-fix (≤ autoFixMaxRounds)"| E
        L -->|"converged (PASS / max rounds)"| SR["/zensu:self-review<br/>(terminal · ≤ 1 fix round)"]
        SR --> FR(["Final Report"])
        GATE["PreToolUse FSM gate"] -.guards.-> RED
        GATE -.-> IMPL
        GATE -.-> GREEN
    end

    subgraph Tracking["Layer 3: Tracking"]
        FR -->|"link artifacts"| M["Zensu Dashboard"]
        M --> Q["Release Gate"]
        M --> P["Journey Health"]
        M --> O["Tier Matrix"]
        M --> N["Security Scores"]
    end

    style A1 fill:#4a9eff,color:#fff
    style A2 fill:#4a9eff,color:#fff
    style PLAIN fill:#4a9eff,color:#fff
    style E fill:#ff6b6b,color:#fff
    style MODE fill:#fff3bf,color:#1e293b
    style VAN fill:#b197fc,color:#fff
    style GATE fill:#888,color:#fff
    style K fill:#ffa94d,color:#fff
    style SR fill:#dcfce7,stroke:#166534,color:#1e293b
    style M fill:#51cf66,color:#fff
```

## Evidence Discipline

One rule runs underneath every other mechanism in this plugin: **an agent may state only what it has actually observed.** A plausible sentence nobody checked is the most expensive defect the plugin can produce, because every later stage — the review chain, the Phase 6 audits, the PR body, the user's decision — treats it as established fact and builds on it.

[`docs/evidence-discipline.md`](docs/evidence-discipline.md) is the single source of truth: no unobserved assertion; cite the observation behind every claim; mark what could not be verified as unverified instead of smoothing it over; settle assumptions with a check before acting and surface the ones you cannot; never invent a path, symbol, identifier, command, flag, API shape, version, or citation; never restate a build/test/coverage result this session did not produce. It lives under `docs/` on purpose — that directory is inside the Session Control runtime digest, so the declared source of truth is tamper-evident within a session exactly like the carriers that quote it.

It reaches every process through three deliberately redundant carriers, because each one alone has a hole:

| Carrier | Reaches | Hole it covers |
|---------|---------|----------------|
| `hooks/session-start-evidence-discipline.sh` | the main thread on every `SessionStart` (including `resume`/`compact`) and every subagent on `SubagentStart` | free-form work that never invokes a skill, and context lost to a compaction |
| `agents/*.md` | every spawned agent | a child whose hook context is advisory or absent |
| `skills/*/SKILL.md` | every invoked workflow | a session that started before the plugin was installed or updated |

The hook reads the block out of the canonical file at run time rather than carrying its own copy, so it cannot drift from the 28 prompt carriers when the rule is reworded.

It is the only **advisory** hook without a config flag — `hooks.sessionBanner:false`, or disabling every other hook, does not silence it. Other hooks carry no flag either (`session-start-session-control.sh`, `pre-reviewer-capability-gate.sh`, `session-start-autopilot-resume.sh`, the two `review-evidence-subagent-*` hooks), but those are enforcement or evidence-plumbing hooks that must not be disableable at all; what makes this one unusual is that every other *advisory, context-injecting* hook is flagged. It is also fail-silent: an unknown event, a malformed payload, a missing `node`, or an absent, symlinked, or malformed block exits `0` with no output, so an always-on hook can never block a prompt or a spawn.

**The block names no file, on purpose.** A `reviewer-readonly-v1` subagent resolves tool paths against the *project* root, not the plugin root, so a `docs/evidence-discipline.md` pointer inside the block could only ever resolve into the repository under review — letting a hostile repo plant that path and have its own text ingested as the authoritative rule. The two leased `evidence-worker-v1` agents would additionally burn a bounded turn on a read their lease denies. So the block declares itself complete and forbids any workspace file claiming to be the rule from overriding it; agents act on the block, humans and the hook read the file.

`tests/structure/test-evidence-discipline.sh` keeps the three carriers honest: the condensed block is extracted from between the canonical file's markers and must appear **verbatim** in every agent and every skill, so a newly added surface that omits it fails the suite instead of shipping without the rule. Anti-vacuity is pinned too — extraction hard-aborts rather than degrading to an empty pattern, the carrier predicate is exercised against missing, paraphrased and unterminated fixtures, and the content assertions run against the hook's *emitted* context rather than its source text.

The prose is the floor, not the ceiling. Where the discipline can be enforced by machinery it already is — the [witness cross-check](#hooks-21) matches every claimed `cmd="…"` against an independent record of what actually ran, REVIEW PACKET v1 makes reviewers reject an evidence-less spawn rather than review from imagination, `/zensu:verify-feature` reports `PARTIAL` instead of inferring an outcome, and `/zensu:wargame` marks an unsettled assumption `RECON NEEDED` with the check that settles it. When extending the plugin, prefer a check that fails closed over a sentence asking the model to be careful.

## CLI Write-Gate

The `zensu` CLI is **read-free, write-gated**. Any state-mutating command (creating or
updating features, security classifications, tiers, journeys, revisions, …) run directly
on the main thread is **denied by default** — it must run inside a skill that declared its
work, so "freelance" writes cannot bypass the dedup, user-journey, baseline-revision and
security-review conventions the skills enforce. Reads and telemetry are always allowed.

The gate is a PreToolUse(Bash) hook (`pre-bash-zensu-gate.sh`): it parses `zensu <noun> <verb>`
out of the Bash command, resolves each to its canonical tool
name via `hooks/lib/zensu-cli-map.sh`, and classifies it with the same `hooks/lib/zensu-mcp-tools.sh`
source of truth. It is a **convention-nudge, not a hard boundary** — once the CLI's OAuth token
is cached on disk an agent could `curl` the backend directly; the gate enforces the workflow
conventions, not a security control (the same role, and the same `ZENSU_MCP_GATE=off` escape, as
the MCP write-gate it replaced).

```mermaid
flowchart TD
    A["zensu CLI command<br/>(Bash, main thread)"] --> B{"Read / telemetry / --help?<br/>list / get / search / suggest verbs<br/>+ pulse, journeys health, --help …"}
    B -->|"yes"| ALLOW(["ALLOW"])
    B -->|"no — state mutation"| C{"ZENSU_MCP_GATE=off (env or inline)<br/>or hooks.mcpGate=false<br/>or localhost backend?"}
    C -->|"yes (escape hatch)"| ALLOW
    C -->|"no"| E{"Inside an active main-thread skill workflow?<br/>workflowActive = true<br/>AND tool in workflowTools (per-skill scope)"}
    E -->|"yes"| ALLOW
    E -->|"no"| DENY(["DENY<br/>run the matching skill<br/>in the interactive main thread"])

    style A fill:#4a9eff,color:#fff
    style ALLOW fill:#51cf66,color:#fff
    style DENY fill:#ff6b6b,color:#fff
```

A skill opens a **scoped** window with
`zensu-log.sh --workflow-begin --tools "<exact tool set>"`: the bypass then allows **only**
that skill's declared tools — so `/zensu:implement` cannot forge a `set_security_classification`
it never declared — and `--workflow-end` closes it again. The `--tools` list stays tool-name-keyed;
the gate maps each CLI command back to its canonical tool name to check membership. `ZENSU_MCP_GATE=off`
disables the gate for a deliberate one-off — honored both as a session env and as an **inline prefix**
(`ZENSU_MCP_GATE=off zensu …`). The gate is scoped to its threat model (a low-context agent writing to the
*real tracked product*), so it also never fires on reads or `--help`/`-h`, or on a write whose target backend
(`--api-url` flag / `ZENSU_API_URL` env) is **localhost** — a throwaway dev/test DB where the conventions are
meaningless. A structure test (`tests/structure/test-skill-workflow-markers.sh`)
fails the build if any skill runs a mutation command without the `--workflow-begin` /
`--workflow-end` markers, so a new skill cannot silently regress the contract.

## Source-Write Gate

A second PreToolUse(Bash) hook (`pre-bash-source-write-gate.sh`) protects **source files** from
raw shell writes that bypass the Edit/Write tools. The Edit/Write gate (`pre-edit-tdd-reminder.sh`)
only ever sees `Edit|Write|MultiEdit`; an agent can route around it with `printf >> file.rs`,
`cat > file.rs <<EOF`, `sed -i`, `tee`, or `dd of=` — and, worse, `cd` into a sibling/main checkout
and clobber **another session's working tree**.

The gate denies a write through one of those channels to a source-extension file when either:

- **(A) Clobber** — the target already **exists and is git-tracked** inside the project (a raw
  shell overwrite of real tracked source), or
- **(B) Escape** — the resolved path lands **outside the session root** (`CLAUDE_PROJECT_DIR`, else
  the command's cwd) — a sibling or main checkout. Relative targets resolve against a cwd that
  **tracks `cd` across the command**, so `cd ../main && printf … >> src/x.rs` is caught. (B) fires
  even for a new file, since writing fresh source into another checkout is the breach.

Never denied: creating a **new** file inside the project, gitignored/untracked files, non-source
extensions, and temp roots (`$TMPDIR`, `/tmp`, `/private/tmp`, `/var/folders`; override the set with
`ZENSU_BSWGATE_TEMP_DIRS`). `mv`/`cp` are out of scope. Like the CLI gate this is a
**convention-nudge, not a hard boundary** — bypass a deliberate one-off with an inline
`ZENSU_BASH_WRITE_GATE=off` (or `ZENSU_MCP_GATE=off`) prefix, or disable it via `hooks.bashWriteGate:false`.
`tests/structure/test-bash-source-write-gate.sh` pins the behavior.

## Secret Scan

A third PreToolUse gate (`pre-write-secret-scan.sh`) inspects **what** is about to be written,
complementing the source-write gate's **which files**: Write `content`, Edit `new_string`,
MultiEdit `edits[].new_string`, NotebookEdit `new_source`, and — whenever the shared parser
(`detectChannels`) reports a write channel (redirect, `tee`, `sed -i`, `dd of=`, heredoc) —
the Bash command text. Payloads are matched against the curated rule set in
`hooks/lib/secret-patterns.js` (AWS, GitHub `gh[pousr]_`/`github_pat_`, Slack, Stripe
`sk_live_`/`rk_live_`, private-key PEM headers incl. PKCS#8, plus a Shannon-entropy assignment
heuristic — deliberately no naive key/password catch-all); decision logic lives in
`hooks/lib/secret-scan-decide.js`. Never denied: **file-tool** targets under a `test(s)/`, `__tests__/`,
`spec(s)/`, `testdata/`, `evals/` or `fixtures/` segment and `*.example.*` files (the path exemption does not apply to
the Bash channel — its targets are not resolved; use the marker or escape hatch there), lines
carrying the `zensu-secret-allow` marker, obvious placeholders (`EXAMPLE`, `YOUR_...`,
`{{...}}`, `${...}`), and Bash commands with an inline `ZENSU_SECRET_SCAN=off` prefix. Parser
errors **fail open** with a stderr note. Bypass with `ZENSU_SECRET_SCAN=off` (env, or inline
for Bash); disable via `hooks.secretScan:false`.
`tests/structure/test-secret-scan-gate.sh` pins the behavior.

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
  relative tool paths. Fresh `startup`/`clear` events may create that binding;
  `resume`/`compact` require the existing record and reuse its original project
  even when the current directory changed. A missing lifecycle source, a
  continuation without its record, or a fresh cross-project reuse of the same
  session id fails closed instead of creating a replacement anchor. The five
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
See [Session Control release gate](docs/session-control-release-gate.md).

**Getting a guaranteed review for a Workflow-triggered run.** Because the worker `Stop`
no-ops, run the review **once over the aggregate diff** — either in-script (recommended) or
deferred:

```js
// Orchestrator-driven: after all implementation agents have joined, run ONE
// review pass over the combined diff — 5 read-only aspects → merge → judge
// (when hooks.reviewJudge is enabled, the default) → reviewer.
const ASPECTS = ['conventions', 'bugs', 'architecture', 'tests', 'security']
const changed = /* `git diff --name-only HEAD`, comma-joined */
const aspects = await parallel(ASPECTS.map(a => () =>
  agent(`Perspective: ${a}. Files changed: [${changed}]`, { agentType: 'zensu:review-aspect' })))
let merged = /* dedupe + sort the five findings lists in-script */
const judge = await agent(`Judge pass. Files changed: [${changed}]\n${merged}`, { agentType: 'zensu:review-judge' })
merged = /* apply JUDGE-* deltas; Panel-FP: verdicts stay visible and mark the referenced finding [Panel-FP-neutralized — do not fix] */
const reviewTicket = /* stdout from the top-level Skill command template:
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --review-ticket */
await agent(`PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${reviewTicket}\n${merged}`, { agentType: 'zensu:code-reviewer' })
```

If you cannot review in-script, a worker records a project-scoped marker
(`zensu-log.sh --pending-review --files "<changed>"`); the **next interactive `Stop`** in
that project adopts it and runs the full chain once, then clears it. The orchestrator clears
it itself with `zensu-log.sh --pending-review-done` when it reviewed in-script. Review is
per-implementation over the aggregate diff — **never per spawned worker**.

## Installation

The minimum supported Claude Code version is **2.1.211**. Local Session Control
Promptfoo profiles can pin an exact Claude Code version for reproducible host
behavior; GitHub Actions does not install Claude Code or run those profiles.

```bash
claude plugin marketplace add MKITConsulting/zensu-claude-code
claude plugin install zensu --scope project
```

The marketplace entry uses Claude Code's GitHub source object and pins the
plugin to the immutable tag matching its manifest version (`v<plugin version>`).
A release commit landing on `main` is therefore not itself an activation: the
new version becomes resolvable only after the publish workflow validates that
exact main SHA, uploads its evidence, and creates the referenced tag. The normal
install and update commands stay unchanged for end users.

## Updating

Already installed an earlier version? Pull the latest release:

```bash
claude plugin marketplace update zensu   # refresh the catalog to the latest release
claude plugin update zensu@zensu         # pull the new version into the installed plugin
```

[Claude Code installs each plugin version into a separate cache directory](https://code.claude.com/docs/en/plugins-reference#plugin-caching-and-file-resolution).
An already-running session keeps its previous `CLAUDE_PLUGIN_ROOT`; fresh
sessions load the new version and create that version's immutable Session
Control binding. Claude retains orphaned previous-version directories for
about 14 days so concurrent sessions can finish; those roots are ephemeral and
must never store persistent state. This is the supported zero-downtime upgrade
path. Claude may add only its own root-level `.in_use/<pid>` and
`.orphaned_at` lifecycle metadata to those cached copies; Zensu runtime payload
bytes remain immutable.

Never replace bytes under an already-published version/cache directory, and do
not run `/reload-plugins` in a session that must continue on its old runtime.
Both operations explicitly migrate the running session to new hook bytes. Zensu
does not support that transition for Session Control because it cannot rely on
the original binding lifecycle being replayed at the migration boundary. Every
release must use a new SemVer version and immutable `v<version>` source tag.

The former `~/.zensu/plugin-root` locator is neither read, migrated, nor
rewritten during install or update. Delete it only once no Claude Code session
from an older Zensu plugin installation is still running in the same home; the
plugin never deletes it automatically.

## Authentication

### OAuth Browser Login (Recommended)

No configuration needed. When you first use a Zensu tool, Claude Code will automatically open your browser to sign in. Tokens are cached and refreshed automatically.

### API Key (CI/CD)

For headless environments where browser login isn't available, authenticate the `zensu` CLI with an API key instead of the OAuth browser flow — pipe it to the token form (a bare `zensu auth login` opens a browser and never reads the env var):

```bash
# ZENSU_API_KEY from your CI secrets
echo "$ZENSU_API_KEY" | zensu auth login --with-token -
```

Verify the session with `zensu auth status`; clear it with `zensu auth logout`. Run `zensu auth --help` for where the token is cached and the headless-auth options.

To point the CLI at a self-hosted Zensu backend, see [Self-hosting](#self-hosting) below.

## What's Included

### CLI (`zensu`)

The plugin drives Zensu through the typed `zensu` CLI — install it with `curl -fsSL https://zensu.dev/install.sh | sh` and authenticate with `zensu auth login`. It provides commands for feature CRUD, security analysis, tier management, user journeys, product bootstrap, ghost scans, pulse sessions, and more (`zensu --help`). The hosted MCP server (`mcp.zensu.dev`) still exists for the Zensu web app's own AI assistant, but is no longer wired into this plugin.

### Agents (6)

| Agent | Role | How It Works |
|-------|------|--------------|
| **zensu-plm** | Read-only planning analyst | Explains and decomposes Zensu lifecycle work. It receives neutral context but exposes only `Read`, `Grep`, and `Glob`; the matching skill performs mutations in the interactive main thread. |
| **code-reviewer** | Quality Review | Consolidates the review. Standalone: walks 5 specialist perspectives (conventions, bugs, architecture, tests, security) in a single READ-ONLY agent. In the `/zensu:tdd` chain: runs in **fan-out consume mode**, emitting the report the main thread merged from five parallel `review-aspect` agents (no re-read, no build/test). |
| **review-aspect** | Single-Perspective Review | READ-ONLY reviewer scoped to ONE perspective. The `/zensu:tdd` chain spawns five in a single parallel batch (one per perspective), then merges their findings in the main thread. Runs zero build/test commands — the suite already ran in the Phase 6 audit. |
| **review-judge** | Independent Second Pass | READ-ONLY judge spawned AFTER the five-aspect merge (gated by `hooks.reviewJudge`, default on). Re-reads the changed files fresh and covers the panel's structural blind spots: cross-cutting integration, requirement drift against the plan's stable AC-###/FR-### IDs, missed edge cases, and panel quality — a false-positive panel finding gets a `Panel-FP:` meta-verdict that the main thread neutralizes before fix routing. Emits `JUDGE-*` deltas; never repeats panel findings, never runs build/test. |
| **plan-review-worker** | Confined plan validator | Dedicated `/zensu:plan-review` worker with only `Read`, `Grep`, and `Glob`. It reads a private, immutable evidence lease and returns one raw `kind:"plan-review"` JSON object as its final message; only the main thread validates and materializes that result. |
| **pr-review-worker** | Confined PR persona | Dedicated `/zensu:pr-team-review` worker with only `Read`, `Grep`, and `Glob`. It reviews a leased role/area evidence shard and returns one raw `kind:"pr-review"` JSON object; it cannot write files, mutate tasks, message agents, spawn agents, run commands, or publish. |

The built-in reviewer boundary uses each agent's exact
`tools: Read, Grep, Glob` allowlist. There is no shell or Git exception and no
control/agent tool. The first all-tool `PreToolUse` hook is the fail-closed
enforcement point: it revalidates the immutable Session Control context on every
tool call, recognizes Claude Code's plugin-scoped `zensu:code-reviewer`,
`zensu:review-aspect`, `zensu:review-judge`, `zensu:plan-review-worker`, and
`zensu:pr-review-worker` identities (plus exact bare
`--agents` fixtures), then repeats the exact three-tool reviewer allowlist. The
plugin-scoped `zensu:zensu-plm` receives the same strict allowlist. Every other
neutral `host-profile-v1` child may retain ordinary non-command host tools, but
cannot invoke `Bash`, `shell`, `exec`, `exec_command`, `terminal`, or `command`.

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

> **Implementation is no longer delegated to an agent.** Since 0.4.0 `/zensu:tdd` runs in the **main thread** — vanilla by default, with strict RED→GREEN available when configured — because the old `tdd-manager` subagent lost too much implementation context. Since 0.6.0 the review chain fans out to five parallel `review-aspect` subagents, optionally runs `review-judge`, and consolidates through one consume-mode `code-reviewer`, while preserving the round counter, auto-fix loop, and self-review terminus.

#### Custom review personas (repo-local)

Projects extend the review panel without forking the plugin: drop agent definitions at `.claude/agents/zensu-review-*.md` (standard agent frontmatter + body prompt; Claude Code registers them at session start — a file added mid-session is not yet spawnable and gets logged as `PERSONA SKIPPED — <name> (not registered)`). The frontmatter `name:` must equal the filename stem and match `zensu-review-[A-Za-z0-9_-]+` — anything else is skipped as malformed. An optional `activation:` field holds comma-separated glob patterns (items may be quoted) matched against the changed-file paths — `**` crosses directory separators on segment boundaries (`"**/domain/**"` matches `src/domain/x.ts` but not `src/subdomain/x.ts`), `*`/`?` stay within one segment, and a pattern without `/` also matches the basename. Project-agnostic examples: `"**/domain/**"` (DDD rules), `"**/*.tf"` (infrastructure), `"**/*.component.ts"` (frontend components). A persona with no `activation:` field always joins; one whose globs match nothing is skipped AND named in the run log (`PERSONA SKIPPED — <name> (no activation match)`) — never silently omitted; malformed files (bad frontmatter, name/stem mismatch, symlinks) are skipped with a log line and never abort the chain. Extra personas are capped at five per run — glob-matched personas take slots before always-join ones (relevance wins), each group lexicographic; overflow is logged as dropped. **Output contract:** a persona reports exactly like a built-in aspect — `## Aspect: <persona-name>` header with `- [SEVERITY] file:line — finding` bullets — except every finding is prefixed with the persona's uppercased `<NAME>-<n>` ID for provenance. **Trust boundary:** a persona file is a repo-controlled prompt at the same trust level as any `.claude/agents` definition or a checked-in `CLAUDE.md` — the read-only/no-build contract is carried by the spawn prompt and the persona's own `tools:` frontmatter, not by promotion to the built-in reviewer principal. Custom personas stay neutral `host-profile-v1`: the all-tool gate prevents Session Control/workflow-root access and `main-v1` impersonation, but their ordinary host tools remain governed by their own frontmatter. Audit `zensu-review-*.md` files in third-party repos before running `/zensu:tdd` or `/zensu:plan-review` (both spawn personas from the local working checkout; `/zensu:pr-team-review` is base-scoped). Matching is decided deterministically by `hooks/lib/persona-activation.js` (changed files on stdin, personas dir as argv; verdict lines `spawn`/`skip`/`drop`).

Here, “ordinary host tools” means non-command tools only: neutral personas are
denied every shell/command alias regardless of their frontmatter.
**Three consumers, one file.** The same `.claude/agents/zensu-review-*.md` persona feeds three review flows: `/zensu:tdd`'s Phase 6 fan-out, `/zensu:pr-team-review`'s cast, and `/zensu:plan-review`'s cast. A persona file declares only the *concern* (its body) plus its *activation globs* (frontmatter) and stays **output-format-agnostic**; each flow injects its own output contract at spawn — `/zensu:tdd` wants the `## Aspect: <persona-name>` markdown above, while the two team-review skills want structured JSON (`$WORKDIR/<name>.json` per their shared schema). A body that hardcodes one format still runs under the others (the injected contract wins), but keeping the body format-neutral lets one file serve all three. **Trust boundary for PR review:** `/zensu:pr-team-review` reviews an untrusted PR head, so it discovers personas from the reviewed repo's **base checkout** (`$REPO/.claude/agents`), never the PR-head worktree — a PR cannot introduce its own reviewer. `/zensu:plan-review` and `/zensu:tdd` run against the trusted local working checkout and discover from its git toplevel.

#### Skill overlays (additive-only)

Three skills carry an overlay anchor (`<!-- zensu:overlay <name> -->`): `tdd`, `cover`, and `pr-team-review`. A repo drops team guidance at `.zensu/overlays/<name>.md` (resolved at the git toplevel of the working checkout, worktree-aware, same anchor as templates and personas) and the skill injects it at that point. The contract is **additive-only**: an overlay may ADD conventions, extra checks, and stack particularities; it can NEVER disable, replace, weaken, or reorder the skill's mandatory phases (discipline gates, evidence audits, review chain, chain terminus) — on any conflict the skill text wins and the run surfaces one line naming the ignored overlay directive. Missing or empty file = no-op. **Trust boundary:** overlays are repo-controlled prompts at the same trust level as `.claude/agents` personas or a checked-in `CLAUDE.md` — the additive-only rule is carried by the skill instruction, not enforced by code; audit `.zensu/overlays/` in third-party repos before running. Example overlay (`.zensu/overlays/tdd.md`):

```markdown
- Team convention: every new module gets an ADR reference in its header.
- Extra check: flag any new dependency added without a lockfile update.
```

#### Templates (repo-overridable)

Three artifact skeletons ship as plugin defaults under `templates/` and resolve with the repo winning: a consumer uses `.zensu/templates/<name>.md` at the git toplevel of the working checkout (`git rev-parse --show-toplevel` — worktree-aware, same anchor as persona discovery) when it exists, else `<absolute-plugin-root>/templates/<name>.md`. The top-level Skill obtains that concrete root from Claude's native `${CLAUDE_PLUGIN_ROOT}` substitution; a supporting file loaded with `Read` must receive the already-resolved value from its parent instead of expecting another substitution pass. An override REPLACES the default wholesale — it MUST keep the mandatory sections, because the Phase 5/6 audits and `/zensu:converge` anchor on them (a structure test can only pin the plugin defaults, so for overrides this is a documented contract):

| Template | Consumer | Mandatory sections |
|----------|----------|--------------------|
| `tdd-plan.md` | `/zensu:tdd` Phase 2 | `## Requirements` (ID/Covers), `## Preconditions`, `## Cross-Layer Value Flow Pairings`, Status Legend, Steps table with Status+Covers, `## Final Verification` |
| `autopilot-spec.md` | `/zensu:autopilot` Phase 0.C | numbered stable `AC-###` criteria, out-of-scope section, resolved recipe |
| `autopilot-pr-body.md` | `/zensu:autopilot` step 3 | per-AC checklist table (deprecated rows kept), `Gates bypassed during build:` audit line |

#### /zensu:tdd — How It Enforces Discipline

Unlike prompt-based TDD ("please write tests first"), the `/zensu:tdd` workflow **structurally prevents** violations via a PreToolUse FSM gate on Edit/Write/MultiEdit:

- **Phase declaration.** Before any edit, the main agent declares the current TDD phase through the top-level Skill command template `CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --phase <PHASE> --step <step_id>`. Claude renders both native plugin placeholders in top-level Skill/Agent content. The helper then uses the host-exposed `CLAUDE_CODE_SESSION_ID` only inside that Bash process to validate the exact immutable record and derive its internal selectors; it never trusts an ambient plugin-private selector. Valid phases: `RED_WRITE`, `RED_RUN`, `RED_FAIL`, `IMPL`, `GREEN_RUN`, `GREEN_PASS`, `REFACTOR`.
- **Gate enforcement.** The PreToolUse hook (`pre-edit-tdd-reminder.sh`) blocks edits whose declared phase violates FSM transitions. In particular, `IMPL` requires a prior `RED_FAIL` marker for the **same step** — there is no path to production code without a failing test on record.
- **State.** Phase markers persist at `.zensu/state/tdd-phase-<scv1-session-key>.json`. Every atomic mutation increments the record revision, and each step's history remains auditable from the file.
- **Activation.** Phase 0 of the skill calls `zensu-log.sh --tdd-begin`, which sets a per-session chain-state `active` flag. Given a valid SessionStart baseline, the TDD gate (and Bash witness) enforce **only** while that flag is set; a valid inactive baseline passes through. A missing, malformed, or unreadable mandatory baseline is an integrity failure and fails closed in Session Control plus the edit/Stop guards. (Pre-0.4.0 this keyed on `CLAUDE_AGENT_TYPE=zensu:tdd-manager`.) Bypass via `ZENSU_TDD_GATE=off` for legitimate non-TDD edits explicitly authorized by the user. The strict gate described above is **opt-in**: `hooks.tddImplementation` defaults to `false`, so out of the box the workflow runs in **vanilla mode** — the gate passes through and the RED→GREEN ceremony is dropped while the evidence audits and review chain stay enforced. Set `hooks.tddImplementation:true` to enforce the strict RED→GREEN gate (see the Hook Opt-Out table).

Additional features: dependency graph for independent-step sequencing, 3-retry IMPL escalation on GREEN-fail with progressive context, completeness audit (mtime discipline + edit landing + build verification), real-time progress log at `.zensu/logs/`.

**Full workflow reference:** [docs/tdd-manager-workflow.md](docs/tdd-manager-workflow.md) — Mermaid flow chart, per-step FSM state diagram, hook gate behavior table, environment variables contract, discipline patches 1-10, four-channel logging.

#### Code Reviewer — 5 Sequential Specialist Perspectives

The code-reviewer agent is a single READ-ONLY agent (no `Edit` / `Write` / `Task` tools) that walks five perspectives in order:

> In the `/zensu:tdd` review chain (since 0.6.0) these five perspectives are fanned out to parallel `review-aspect` subagents and merged in the main thread; the sequential walk described here is what a direct standalone `code-reviewer` invocation does.

| Reviewer | Scope |
|----------|-------|
| conventions-checker | CLAUDE.md compliance, naming, formatting |
| bug-hunter | Logic errors, off-by-one, null checks, race conditions |
| architecture-reviewer | Layer separation, dependency direction, patterns |
| test-analyzer | Coverage gaps, assertion quality, missing scenarios |
| security-reviewer | Secrets, injection, auth checks, input validation |

Anti-hallucination rules: every finding requires file:line reference, confidence >= 80, must Read the file before reporting.

### Skills (22)

> The count is the workflow skills in this table. The read-only diagnostics skill is documented separately in **Diagnostics** below and is intentionally kept out of this table (23 skills are registered in `plugin.json`).

| Skill | Description |
|-------|-------------|
| `/zensu:bootstrap` | Bootstrap a product from a vision document — creates features, journeys, security profiles, tiers |
| `/zensu:implement` | Implement a feature end-to-end with artifact linking and revision tracking |
| `/zensu:pilot` | Interactive pipeline conductor — probes a feature's real state (backend status, release gate, git, PR review threads), renders a status card, offers the next step via AskUserQuestion, delegates to the matching sibling skill, and executes confirmed status transitions along the server FSM. Loops probe → offer → delegate until released or exit; resumable across sessions because the backend status IS the pipeline state. The guided counterpart to `/zensu:autopilot`. |
| `/zensu:cover` | Author durable, right-level tests (unit → integration → E2E) for a change — generic across stacks. Green-first coverage of existing code, report-only on surfaced bugs; reuses the `zensu:review-aspect` fan-out + `zensu:code-reviewer`. The durable-test complement to `/zensu:autopilot`'s one-shot validation (persist its ACs via `--from-acs`). |
| `/zensu:verify-feature` | Live-verify an already-built feature against the current worktree or a deployed preview. Builds a diff-grounded P0/P1/P2 matrix, drives the real UI through the pinned, integrity-locked Playwright MCP configuration, and reports DOM/data, visual, console, and network evidence. Credential-blind and report-only: it neither fixes code nor writes committed tests. The exact origin, page routes, and `declared-safe` evidence mode must already be present in the parent navigation policy; unknown dynamic ports require discovery followed by a restarted policy-configured session. Every MCP server start materializes a private npm generation from the SRI-pinned lockfile outside the plugin root; concurrent servers never share `node_modules`, while npm's normal cache avoids unnecessary downloads. See [Playwright MCP runtime integrity](docs/playwright-mcp-runtime.md). |
| `/zensu:converge` | Bidirectional flow-back audit: evaluate the current code state against the newest plan's `## Requirements` table (stable `AC-###`/`FR-###` IDs), classify gaps (`missing` / `partial` / `contradicts` / `unrequested`), split unrequested work into business rules vs implementation details, and propose plan edits with freshly allocated stable IDs — applied only after explicit user confirmation (report-only in non-interactive runs; legacy plans without a Requirements table stop cleanly). Offered at the `/zensu:tdd` chain end; `/zensu:autopilot` runs it report-only before opening the PR. |
| `/zensu:tdd` | Guided implementation in the main thread — vanilla by default, opt-in strict RED→IMPL→GREEN enforced by the PreToolUse phase-gate; ends by spawning `zensu:code-reviewer` with a Stop-hook-guaranteed auto-fix chain. Invoked by plan-approval (on your confirmation), `/zensu:implement`, or directly. |
| `/zensu:docs` | Author code-grounded documentation for a tracked feature (or a whole product/component in one batch) so it honestly clears the hardened `docs_complete` release gate — one feature-specific doc per feature from the REAL linked source, published to the wiki (or a per-feature repo file) and linked via `zensu link docs`; forbids placeholder / metadata-dump stubs. Idempotent, batchable, and logs every feature skipped or failed. |
| `/zensu:wargame` | Wargame a hard mission before a cheaper executor runs it — an executable-blind battle plan (every move + expected observation, likely failure + counter-move, forks, abort conditions, verification runs, red-team pass, graded against an 8-point standard). Also handles `/goal` property-proof contracts; code/feature missions reuse the Zensu review chain to converge. |
| `/zensu:autopilot` | Take a feature from a plain-language idea to a ready, validated GitHub or GitLab pull/merge request — one interactive planning gate, then an autonomous build via vanilla `/zensu:tdd`, gates, converge report, PR/MR via the pluggable VCS driver, one `/zensu:pr-team-review` pass, `/zensu:pr-fix-findings`, and a validate↔fix loop driven by a pluggable, credential-blind driver. Stops at a ready PR/MR; never merges or deploys. |
| `/zensu:pr-fix-findings` | Fix every unresolved review comment on a GitHub or GitLab pull/merge request end-to-end: locate the PR/MR via the VCS driver, pull unresolved threads, triage, implement each fix through vanilla `/zensu:tdd`, push, and resolve the threads on the forge. Built to run standalone or repeatedly until no unresolved threads remain. |
| `/zensu:plan-review` | Revalidate an implementation/design plan **before** coding: dynamically casts a tailored parallel batch (default 6, from a 12-persona pool) of dedicated `zensu:plan-review-worker` validators behind one private evidence lease, then consolidates one report with a GO / GO-WITH-CHANGES / REVISE / NO-GO verdict plus concrete plan amendments. Workers return raw JSON through their final messages; only the main thread materializes accepted results. Reviews the plan only — writes no code, triggers no TDD. |
| `/zensu:pr-team-review` | Multi-agent review of an **existing GitHub or GitLab PR/MR**: scouts it via the VCS driver, auto-casts dedicated `zensu:pr-review-worker` personas from a 25-persona pool (always-on holistic core: coverage, correctness, maintainability, anti-groupthink), **always runs an explicit test-coverage evaluation that flags uncovered files and paths** (mandatory `### Test Coverage` section; `--coverage-gate` to block on uncovered production files, `--run-coverage` to run the real tool), fetches it into an isolated git worktree (main checkout untouched), and leases exact role/area evidence shards to parallel read-only workers. The main thread validates and materializes their raw JSON, runs the anti-groupthink synthesis, and shows the final preview. Standalone publication waits for explicit approval; delegated runs continue unattended through reconciliation and publish — GitHub as one atomic review via `gh api`, GitLab as a summary note plus inline discussions via `glab`. Every inline anchor is pre-validated against the diff (`hooks/lib/valid-diff-lines.js`) with nearest-line remap so no finding is lost. Complements `/zensu:plan-review` (which validates a plan before code exists). |
| `/zensu:security-review` | Comprehensive security review: classification, analysis, STRIDE threat model, review completion |
| `/zensu:ghost-scan` | Scan a repository with a multi-perspective agent fan-out to discover undocumented features, user journeys, and docs, and import them |
| `/zensu:pulse` | Developer journal — track coding sessions with privacy-first activity logging |
| `/zensu:reset-review-limit` | Atomically reset the current task's integrated `reviewRound` and `stopBlockCount` counters and re-arm `chainDone=false`, `codeReviewDone=false`, and `selfReviewFixed=false` through exactly one revision-pinned Session Control CAS mutation. It touches only the exact validated `tdd-phase-<scv1-session-key>.json`; no file scan, deletion, or cross-worktree fallback exists. |
| `/zensu:recover-chain` | Diagnose the current session's review chain (`zensu-log.sh --chain-status` reports its shape, whether it is wedged, and the supported next command) and, only for the single shape no supported command can leave — a pending rearm receipt that disagrees with its own workflow document, which makes every future review ticket refuse, permanently — restore it with one guarded, revision-bumping transition taken under the same lease every other ticket writer holds. It drops the disagreeing receipt and writes its `history` provenance in that same revision — nothing else. `chainDone`, `codeReviewDone`, `selfReviewFixed`, `reviewRound`, `stopBlockCount`, the bypass ledger, the ticket slot and every Autopilot link field survive untouched, so it can neither close a chain, skip findings, grant another auto-fix round, nor unbind a generation. In particular it refuses (rather than normalizes) an inconsistent `reviewTicketConsumed`, because writing `true` there would complete the precondition of the unqualified no-ticket terminus. Refuses on every reachable shape naming the command that applies — an outstanding unclaimed ticket, an outstanding deferred-review claim, an inconsistent review-ticket slot, the specific blocker the row names — see `/zensu:recover-chain` for the full roster. That shape is not produced by any in-plugin transition: it comes from an externally corrupted or restored state document, so the skill is repair for that damage class rather than a routine chain step. |
| `/zensu:self-review` | Terminal self-reflection stage of the review chain. After `zensu:code-reviewer` converges, re-reads this session's own changes across 7 dimensions, takes at most one fix round under the phase-gate (never re-running the reviewer), then owns the chain terminus (`--chain-done`) and renders the final report with a `## Self-Review Summary`. Hard-enforced via `codeReviewDone`/`selfReviewFixed`; gated by `hooks.selfReview`. |
| `/zensu:setup` | Interactive first-run configuration — verifies the zensu CLI + auth (offers `zensu auth login`), asks global vs project-local, then walks a curated set of high-impact plugin settings via AskUserQuestion and writes them with a jq-free deep-merge that preserves every other key. |
| `/zensu:zen-mode` | Focused low-noise response mode for working at reduced capacity. Keeps every bit of technical substance but strips presentation noise: each answer opens with a one-line recap of what just happened, states the result first, stays around eight lines, withholds trade-offs and alternatives until asked, asks at most one question per turn, and ends with exactly one next step. Activation writes a session-scoped marker under `.zensu/state/` and `user-prompt-zen-mode.sh` re-injects the contract on every prompt, so the style cannot quietly fade the way a one-time skill load does; while active it overrides any compressed or telegraphic style mode, because fragments cost a low-capacity reader more than they save. Security warnings, irreversible actions, and credential handling are never compressed. The hook itself watches for `zen off` / `zen-mode off` / `turn off zen` / `stop zen` anywhere in a prompt, plus a bare `normal mode` as the whole prompt, and drops the marker, so deactivation still works after the model has drifted. Disable the reminder with `hooks.zenMode:false`. |
| `/zensu:zensu-help` | Q&A skill — explains Zensu PLM concepts and plugin internals (agents, hooks, FSM, config flags). Read-only; routes workflow requests to the appropriate action skill. |

`/zensu:verify-feature` also has an agentic Promptfoo E2E suite under
`evals/verify-feature/`. Its live runner exercises the current plugin worktree against an
isolated browser fixture and checks the unsafe-remote-URL boundary; the corresponding structure
test remains offline and deterministic for the default repository suite.

### Diagnostics — `/zensu:doctor`

A read-only health check for the install, for when something is not firing and you want to see why. `/zensu:doctor` runs `hooks/lib/zensu-doctor.sh` and prints one four-block ✅/⚠️/❌ table:

- **CLI & tooling** — zensu CLI present + authenticated, node version, the forge CLI for the detected provider (`gh`/`glab`) present + authenticated, and the pinned, integrity-locked Playwright MCP config used by `/zensu:verify-feature` (plus the `/zensu:autopilot` browser driver). Doctor validates the declaration and lockfile offline without executing `npm`; “configured” remains a warning until loaded MCP tools prove runtime readiness.
- **Plugin integrity** — every `hooks.json` command resolves to a script on disk (and every hook script is referenced), and `plugin.json` ↔ `marketplace.json` versions agree.
- **Config** — the effective config files are valid JSON and free of the **quoted-boolean trap**: a value written as the string `"true"`/`"false"` is silently ignored by the strict `=== true` checks, so the feature stays at its default until you drop the quotes. Doctor names each offending key.
- **Session state** — the state dir is writable, every canonical `tdd-phase-<scv1-session-key>.json` is a valid CAS workflow document, and an expired `pending-review.json` is surfaced. `reviewRound` and `stopBlockCount` live inside that document and are never treated as cleanup markers. Each valid document also reports its **review-chain shape** (keyed by a truncated session key), and a wedged chain is raised as a ⚠️ naming the command that actually applies — `/zensu:recover-chain` when the chain is recoverable, the specific blocker (incomplete Autopilot linkage, outstanding deferred-review claim, inconsistent review-ticket slot, latched `selfReviewFixed`) when it is not, or a separate "at a dead end" row when no repair applies and only a fresh generation exits. A chain repaired earlier renders `repaired N×`, counted from durable history entries.

The helper never writes and always exits `0` — a red ❌ is a finding in the report, not a failed command. The skill may remove only an expired, non-symlink `pending-review.json` after explicit confirmation; it never deletes CAS workflow documents. Use `/zensu:setup` to edit config, `/zensu:reset-review-limit` for a transactional review-budget reset, and `/zensu:recover-chain` — from the session that owns the chain — for a wedged one.

### Hooks (21)

| Hook Script | Event | Config Flag | Description |
|-------------|-------|-------------|-------------|
| `session-start-session-control.sh` | SessionStart + SubagentStart | — | SessionStart creates the immutable Session Control v1 record and emits the principal-specific context; it neither reads nor writes `CLAUDE_ENV_FILE` and exports no plugin-private selectors to model or subagent shells. A payload with neither `agent_id` nor `agent_type` receives interactive `main-v1`; `claude --agent` SessionStart payloads use the same exact reviewer/neutral classifier as later tool hooks. SubagentStart reads the parent record and injects `reviewer-readonly-v1` for the five exact plugin-scoped reviewers (`code-reviewer`, `review-aspect`, `review-judge`, `plan-review-worker`, `pr-review-worker`) or neutral `host-profile-v1` for every other child, including `zensu:zensu-plm`. Because Claude Code cannot block on SubagentStart, this hook's child-side failure is diagnostic; the first PreToolUse gate performs the mandatory fail-closed revalidation. Stateful model commands receive Claude's native plugin root/data values at the call site and validate the host-exposed session id against this record inside the helper process only. |
| `pre-reviewer-capability-gate.sh` | PreToolUse `*` | — | First enforcement hook for every tool. Derives and revalidates session id, installed plugin root, plugin-data store, private record, workflow-state anchor, current canonical `cwd`, and live runtime digest directly from standard hook metadata; it never assumes SessionStart shell exports reach hook processes. Missing or mismatched bindings return a structured `permissionDecision: deny`; launcher/runtime failures are normalized to Claude's blocking exit code 2 with a sanitized diagnostic. The five exact plugin-scoped reviewers and `zensu:zensu-plm` may invoke only `Read`/`Grep`/`Glob`; plan/PR workers are further limited to their private exact-file/safe-subtree lease and all leased paths are revalidated against their creation snapshot on every call. Only the top-level interactive thread receives `main-v1`. Other `host-profile-v1` children retain ordinary non-command host tools, while all shell/command aliases, direct or ancestor traversal into Session Control/workflow-root state, mutations below the installed-plugin/private plugin-data roots, and mutating Zensu operations are blocked. `Grep`/`Glob` require a concrete safe subtree rather than an omitted path or a project/plugin/plugin-data ancestor. |
| `session-start-evidence-discipline.sh` | SessionStart + SubagentStart | — | **Evidence discipline** (see [Evidence Discipline](#evidence-discipline)). Injects the plugin-wide anti-hallucination rule as model-facing `additionalContext` so every process carries it — the main thread and every spawned subagent alike. The directive text is read at run time from `docs/evidence-discipline.md` (the single line between the `zensu:evidence-discipline` markers), never duplicated in the script, so this carrier cannot drift from the block the agents and skills quote; `docs/` is inside the Session Control runtime digest, so that file is tamper-evident within a session. Deliberately unlike `session-start-primer.sh` in three ways: it reads **no config** (there is no opt-out flag; in particular `sessionBanner:false` does not silence it), it has **no fresh-start filter** (it also fires on `resume`/`compact`, where the rule would otherwise vanish with the compacted context), and it applies to **every principal** rather than only `main-v1`. The emitted `hookEventName` echoes the event actually received. Fail-silent by construction: an unknown event, a malformed payload, a missing `node`, or an unreadable block exits `0` with no output, so it can never block a prompt or a spawn. The one branch that is deliberately not silent is the shared plugin-root guard: an inherited `CLAUDE_PLUGIN_ROOT` that does not match the executing plugin refuses with exit `2`. |
| `session-start-pulse.sh` | SessionStart | `pulseSession` | Emits HEAD/branch banner and prepares pulse session context at startup |
| `session-start-banner.sh` | SessionStart | `sessionBanner` | User-facing "Zensu PLM vX active" banner + usage hints (Plan mode → ask whether to run `/zensu:tdd`, gate-enforced edits when you do, skills list). Plain stdout, shown to the user. Fires only on fresh starts (`source=startup`/`clear`), silent on `resume`/`compact`. Skipped when `sessionBanner:false`. |
| `session-start-primer.sh` | SessionStart | `sessionBanner` | Model-facing orientation: injects a short `additionalContext` primer so the agent proactively uses Plan mode and asks before running `/zensu:tdd`. Same fresh-start filter + `sessionBanner` gate as the banner. |
| `session-start-autopilot-resume.sh` | SessionStart | — | Read-only durable Autopilot recovery context. On `resume`/`compact`, it requires the private session record and reads only its immutable project; a `CwdChanged` location can never select Autopilot state. On concurrent fresh `startup`/`clear`, it prefers an already-valid record and otherwise uses Claude's stable `CLAUDE_PROJECT_DIR`, never payload `cwd`. A matching top-level owner receives the exact validated run stage and closed next-action code. Missing bindings/absent state stay silent; corrupt or foreign-owner state is reported without reflecting untrusted bytes or mutating progress. |
| `pre-edit-tdd-reminder.sh` | PreToolUse Edit/Write/MultiEdit | `ZENSU_TDD_GATE` (env) | TDD Phase Gate. Enforces RED→IMPL→GREEN FSM via `.zensu/state/tdd-phase-<sid>.json`. Active only while the session's chain-state `active` flag is set (by `zensu-log.sh --tdd-begin`); pre-0.4.0 it keyed on `CLAUDE_AGENT_TYPE=zensu:tdd-manager`. Bypass with `ZENSU_TDD_GATE=off`. Bash file mutations are intentionally **not** gated — they remain the responsibility of the `/zensu:tdd` prompt discipline + PostToolUse code-reviewer chain. |
| `pre-bash-zensu-gate.sh` | PreToolUse `Bash` | `mcpGate` (+ `ZENSU_MCP_GATE` env) | Zensu CLI write-gate. Parses `zensu <noun> <verb>` from the Bash command, resolves each via `hooks/lib/zensu-cli-map.sh`, and classifies via `hooks/lib/zensu-mcp-tools.sh`: read/telemetry commands (`zensu_is_read_tool`) pass ungated; every state-mutating command is **default-denied** unless it is declared in an active main-thread skill workflow window (opened by `zensu-log.sh --workflow-begin --tools "…"`, e.g. inside `/zensu:implement` or `/zensu:bootstrap`) or a bypass is set (`ZENSU_MCP_GATE=off` env **or inline prefix** / `mcpGate:false` config). A `zensu-plm` child is neutral and receives no mutation exemption. Reads, `--help`/`-h`, and writes whose target backend (`--api-url` flag / `ZENSU_API_URL` env) is **localhost** are never gated — the gate is scoped to writing the real tracked product, not a throwaway dev/test DB. A deny returns `permissionDecision:deny` with remediation pointing at the matching main-thread skill. A convention-nudge, not a hard boundary (once the CLI's token is on disk an agent can `curl` the API directly): forces mutations through the workflow conventions (dedup, user journeys, baseline revisions, security classification, release-readiness gates) instead of raw CLI calls. |
| `pre-bash-source-write-gate.sh` | PreToolUse `Bash` | `bashWriteGate` (+ `ZENSU_BASH_WRITE_GATE` env) | Source-write integrity gate. Inspects raw Bash writes (`>`/`>>`, `tee`, `sed -i`, `dd of=`, `cat > f <<EOF`) and **denies** a write to a source-extension file when either (A) it overwrites an **existing git-tracked** file inside the project, or (B) the resolved path **escapes the session root** (`CLAUDE_PROJECT_DIR`, else the command's cwd) into a sibling or main checkout — relative targets resolved against a cwd that tracks `cd`, so (B) catches `cd ../main && printf … >> src/x.rs` even for a new file. Never gated: new files inside the project, gitignored/untracked files, non-source extensions, and temp roots (`$TMPDIR`/`/tmp`/`/private/tmp`/`/var/folders`, overridable via `ZENSU_BSWGATE_TEMP_DIRS`); `mv`/`cp` are out of scope. Bypass a one-off with an inline `ZENSU_BASH_WRITE_GATE=off` (or `ZENSU_MCP_GATE=off`) prefix; disable with `bashWriteGate:false`. A convention-nudge that closes the Bash-write blind spot of `pre-edit-tdd-reminder.sh`, not a hard boundary. |
| `pre-write-secret-scan.sh` | PreToolUse Edit/Write/MultiEdit + NotebookEdit + `Bash` | `secretScan` (+ `ZENSU_SECRET_SCAN` env) | Secret gate. Scans the payload about to land in a file — Write `content`, Edit `new_string`, MultiEdit `edits[].new_string`, NotebookEdit `new_source`, and (for Bash) the command text whenever the shared parser (`detectChannels` in `bash-source-write-parse.js`) reports a write channel (`>`/`>>`, `tee`, `sed -i`, `dd of=`, heredoc; fd-dups like `2>&1` are not channels) — against the curated rules in `hooks/lib/secret-patterns.js` (AWS access key + secret assignment, GitHub `gh[pousr]_`/`github_pat_`, Slack `xox*`, Stripe `sk_live_`/`rk_live_`, private-key PEM headers incl. PKCS#8, Shannon-entropy assignment heuristic for quoted and unquoted values); decision logic in `hooks/lib/secret-scan-decide.js`. **Denies** with the matched rule name(s) and remediation. Never denied: **file-tool** paths under `test(s)/`/`__tests__/`/`spec(s)/`/`testdata/`/`evals/`/`fixtures/` or `*.example.*` files (path exemption does not apply to Bash — targets are not resolved there), lines carrying the `zensu-secret-allow` marker, obvious placeholders, and Bash commands with an inline `ZENSU_SECRET_SCAN=off` prefix. Parser/node errors **fail open** with a stderr note. Bypass with `ZENSU_SECRET_SCAN=off` (env; inline prefix for Bash); disable with `secretScan:false`. A convention-nudge complementing the source-write gate: that one guards *which files*, this one guards *what content*. |
| `plan-approved-delegate.sh` | PostToolUse ExitPlanMode | `autoTdd` | After the user approves a Plan-mode plan that adds executable code, directs the main agent to ask whether to run `/zensu:tdd` in-thread, with the existing doc-only, explicit-preference, and non-interactive fast paths. A validated `<!-- zensu-autopilot:<run> -->` plan instead advances its owner-bound durable run and delegates directly to the bound TDD attempt; this takes precedence over `autoTdd:false` because Autopilot already used its one planning gate. |
| `post-review-tdd-delegate.sh` | PostToolUse Agent | `autoFix` (+ `autoFixIncludeSuggestions`, `autoFixMaxRounds`, `combinedSummary`) | Auto-fix loop. After `zensu:code-reviewer` completes, atomically increments `reviewRound` in the validated, revisioned `tdd-phase-<scv1-session-key>.json`, routes the configured severities back to the main thread, and re-spawns the reviewer. Concurrent completions serialize through Session Control CAS. Terminal outcomes mark `codeReviewDone` for `/zensu:self-review` or `chainDone` when self-review is disabled; an owning durable Autopilot run is reconciled to its exact recorded return stage. Every chain-end branch appends a `CHAIN-END SUMMARY`; disable it with `combinedSummary:false`. |
| `post-bash-witness.sh` | PostToolUse Bash | `ZENSU_TEST_WITNESS` (env) | Test-Run Witness. Records every Bash tool invocation (command, exit code, stdout tail) to `${CLAUDE_PROJECT_DIR:-.}/.zensu/logs/witness-<scv1-session-key>.log`. It is active only while that exact Session Control workflow is active; foreign or legacy state is never adopted. The Phase 6 audit cross-checks each CHECKPOINT/AUDIT claim against this independent evidence. Bypass with `ZENSU_TEST_WITNESS=off`. |
| `stop-chain-enforcer.sh` | Stop | `chainEnforcer` + `autopilotEnforcer` (`ZENSU_CHAIN` / `ZENSU_AUTOPILOT` env) | Hierarchical backstop. The inner TDD review chain routes first; each nudge atomically increments the integrated `stopBlockCount` field and reviewer progress resets it. Once the inner chain permits Stop, an active durable Autopilot run still blocks until `DONE`, `BLOCKED`, or `CANCELLED`; inner completion is reconciled to its exact return stage. `ZENSU_CHAIN=off` disables only the inner chain, while `ZENSU_AUTOPILOT=off` records audited `BLOCKED` for the outer run. Before any routing the event must bind to its immutable Session Control record; the three states that prevent that (library missing, record unbindable, record no longer matching an existing project root) each block with their own cause and remedy, and honor both release switches so a deleted or moved worktree cannot wedge a session forever. Spawned agents always no-op. |
| `user-prompt-context-nudge.sh` | UserPromptSubmit | `context.compactionNudge` (+ `context.nudgeThreshold`, `context.windowSize`) | Context-compaction nudge. On each user prompt it tail-reads the session transcript's most recent `usage` block, computes context occupancy (`input_tokens + cache_read_input_tokens + cache_creation_input_tokens` ÷ context size — when `context.windowSize` is unset the nudge stays silent at or below 200k occupancy and treats occupancy past 200k as a proven 1M window) and, once usage reaches `context.nudgeThreshold` (default `50`%), injects a model-facing `additionalContext` reminder so the **main-thread** agent proactively proposes `/compact` to the user. It never triggers compaction itself (only the user can) and never blocks the prompt — missing `node`/transcript, sub-threshold usage, or any error exits 0 silently. A per-session state file (`${CLAUDE_PROJECT_DIR:-.}/.zensu/state/context-nudge-<sid>.txt`) records the last 10%-band that fired, so the reminder repeats once per band climb (50→60→70…) instead of every prompt and re-arms after a compaction shrinks the context. All three settings live under the top-level `context` node of `.zensu/config.json` (not `hooks`); disable with `context.compactionNudge:false`. |
| `user-prompt-intent-router.sh` | UserPromptSubmit | `intentRouter` | Product-planning intent router. On each user prompt a whole-word, case-insensitive regex (`zensu`, `product`, `feature`, `roadmap`, `milestone`, `bootstrap`, `ghost scan`, `journey`, `tier`, plus inflections) screens for Zensu planning/tracking intent; on a hit it injects a model-facing `additionalContext` directive steering the interactive agent to run the greenfield/brownfield/hybrid triage — ask the three project-context questions, then invoke `/zensu:bootstrap`, `/zensu:ghost-scan`, or the hybrid sequence in the same main thread — instead of running freelance `zensu` CLI commands or delegating mutations to a child. The directive carries an explicit dismiss clause so an ordinary coding/UI/debug task that merely mentions a word like "product"/"feature"/"tier" is answered normally. Advisory steering, not a hard gate; silent on no-keyword prompts, missing `node`, or `intentRouter:false`. |
| `user-prompt-zen-mode.sh` | UserPromptSubmit | `zenMode` | zen-mode re-injection. While the current session carries a zen-mode marker (`${CLAUDE_PROJECT_DIR:-.}/.zensu/state/zen-mode-<scv1-session-key>.json`, written by `hooks/lib/zensu-zen-mode.sh --on` through the `/zensu:zen-mode` skill), the hook injects the mode contract as `additionalContext` on every prompt — recap line, result first, ~8 lines, depth on demand, one question and one next step per turn, `Step N of M` anchor, and the never-compress carve-out for security warnings, irreversible actions, and credentials. It explicitly **overrides** any other compressed or telegraphic style mode for the duration. A skill is loaded once and fades after a handful of turns, which a low-capacity user is the least likely to notice — hence the per-prompt reminder. Deactivation is performed by the HOOK, not the model: a prompt carrying `zen off` / `zen-mode off` / `turn off zen` / `stop zen`, or consisting solely of `normal mode`, removes the marker directly, so the off-switch still works after the model has drifted — and the OFF context is emitted only once the marker is actually gone. The marker is keyed by the resolved Session Control key **and** rooted at `zensu_resolve_project_dir` (the accessor the writer uses, not the host-native `ZENSU_PROJECT_ROOT`, which is a different namespace on Git Bash), so a fresh session always starts with the mode off and a sibling session in the same project is unaffected. Symlinked markers are refused on both the read and the write side. The marker test runs before the prompt is ever read, so a session with the mode off never pays for prompt extraction; the hook is otherwise a no-op for non-main principals and under `zenMode:false`. Every path after the plugin-root identity check exits 0 and never blocks the prompt. |
| `user-prompt-tdd-reminder.sh` | UserPromptSubmit | `tddReminder` | Per-turn TDD reminder for **direct (non-Plan-mode)** requests. The Plan-mode path (`plan-approved-delegate.sh`) only fires on plan approval, so a direct "implement X" / "fix the bug" prompt otherwise reaches no TDD trigger. On each prompt this hook injects a model-facing `additionalContext` directive — mirroring the plan-approval decision logic + fast-paths — so the agent decides whether the request is a code change and, unless a fast-path applies, **asks** (via `AskUserQuestion`) whether to run `/zensu:tdd` before its first edit. **No prompt regex** — the (multilingual) model classifies intent, so detection is language-independent. Silent when `tddReminder:false`, when the payload has no prompt, or when a TDD session is already active for the session (reusing `pre-edit-tdd-reminder.sh`'s session resolution). Advisory steering — it never blocks an edit. |

## Typical Workflows

### New Product (Planning → Implementation → Release)

```
1. /zensu:bootstrap          → Create product, features, journeys, tiers
2. /zensu:implement ZEN-1    → Load context, plan implementation
3. /zensu:tdd                → Guided main-thread implementation (vanilla; opt-in strict RED→GREEN)
4. review chain              → 5 parallel review-aspect agents → optional review-judge → consume-mode code-reviewer (Phase 6, Stop-hook guaranteed)
5. auto-fix loop             → Critical/Important findings fixed in-thread, then re-reviewed, capped at autoFixMaxRounds
6. /zensu:security-review    → OWASP, threat model, release gate check
```

### Existing Codebase

```
1. /zensu:ghost-scan         → Discover features + journeys + docs (multi-agent fan-out); seat each at a v1 build-out baseline
2. /zensu:security-review    → Assess security posture per feature
3. /zensu:tdd                → Add tests via TDD for untested features
```

### Hybrid (Existing Codebase + Forward Plan)

For a brownfield repo whose plan/vision doc also describes not-yet-built features:

```
1. /zensu:ghost-scan         → Import what is built (each feature seated at a v1 baseline)
2. (agent) create_feature    → Plan doc's not-yet-built items → planned features
3. /zensu:implement KEY-N    → Build the planned items; v1 revision at implement-time
```

No separate skill — the agent runs ghost-scan, then creates the remainder as planned features.

### Quick Feature (No Full TDD)

```
1. /zensu:implement ZEN-42   → Context-aware implementation with artifact linking
2. @code-reviewer            → Quality review
```

## Graceful Degradation

The TDD workflow and code reviewer work **without a Zensu account**. No `zensu` CLI needed for:
- `/zensu:tdd` orchestration (vanilla by default; strict RED→GREEN when configured)
- Code review (5 parallel specialist aspects → optional judge → consume-mode reviewer)
- Progress logging (`.zensu/logs/`)

When the `zensu` CLI is installed and authenticated, additional capabilities activate:
- Automatic `zensu link test` and `zensu link source` after TDD completion
- Feature status updates (`zensu features status`)
- Revision creation with implementation summary (`zensu features revision`)
- Security findings fed into `zensu security review`
- Release gate validation (`zensu security validate`)

## Configuration

### Hook Opt-Out

Zensu ships twenty-one automatic hooks that fire across the development lifecycle (full enumeration in the [Hooks (21)](#hooks-21) table above). The configurable subset is listed below; `pre-edit-tdd-reminder.sh` has no on/off flag of its own — it is bypassed per call via the `ZENSU_TDD_GATE` env var and passes through for whole sessions frozen into vanilla mode by `tddImplementation` (see that row below), and `session-start-evidence-discipline.sh` has none by design (see [Evidence Discipline](#evidence-discipline)). Any flagged hook can be disabled via `~/.zensu/config.json` without forking, editing, or uninstalling the plugin.

**Visible opt-outs (bypass ledger).** Env-var escapes stay free — no gate ever blocks on them — but they are no longer silent: while a TDD session is active (chain-state `active`), each gate records the escape it was bypassed through (`ZENSU_TDD_GATE`, `ZENSU_BASH_WRITE_GATE`, `ZENSU_MCP_GATE`, `ZENSU_SECRET_SCAN`, `ZENSU_CHAIN`, `ZENSU_TEST_WITNESS` — env or inline prefix) into the per-session state file, deduplicated per gate name and carrying gate names only (never command payloads or values; entries are validated against the closed six-gate allowlist at write and read, pre-existing junk sanitized and bounded by the closed allowlist + per-name dedup). The ledger records gate escapes ONLY, so every name rendered under "Gates bypassed" is genuinely a gate that was escaped; operator interventions that are not escapes — notably the `/zensu:recover-chain` repair — record their provenance as a workflow `history` entry inside their own transaction instead of borrowing this surface. One recording semantic for every site: the escape is recorded when it short-circuits the gate's **decision point** — the witness records once per session on the first command it would otherwise have witnessed; the zensu CLI gate records when a `zensu` invocation is actually present; `ZENSU_MCP_GATE` is also honored (and therefore also recorded) by the Bash source-write gate at its own any-Bash-command decision point, so it can appear in sessions that never ran the zensu CLI; the secret-scan gate's inline escape records only on write-channel commands while its exported env escape records on the first scanned payload of any kind; inline prefixes are reported by the command parsers themselves (quoted spellings and mixed commands included; heredoc bodies, argument mentions, and channel-less commands excluded), and a command that ends up DENIED never mints a ledger entry from the denying gate — deny wins over markers WITHIN each gate (sibling hooks on the same tool call decide independently, so a gate that individually allowed may still have recorded its own escape even when another gate denied the call; over-reporting, never under-reporting). A config-disabled gate (`hooks.<flag>:false`) has no decision point — deliberate standing configuration is not ledgered. The chain-end summary surfaces the list as `Gates bypassed during this session: …` (`/zensu:autopilot` prints the build-level union into the PR body as `Gates bypassed during build: …`), sourced via `zensu-log.sh --bypass-list` (`none` when clean; `--bypass-note <gate>` is the write verb, itself scoped to active sessions). The ledger resets at every `--tdd-begin` (which echoes any non-empty outgoing ledger as `previous-run bypasses (cleared now): …` so multi-run unions have a durable trace) and `--tdd-reset`; recording is fail-open — a ledger failure never breaks the gate.

| Flag | Hook Script | Effect when `false` (boolean flags) or value (numeric flags) |
|------|-------------|---------------------|
| `autoTdd` | `plan-approved-delegate.sh` | Skips the post-approval TDD prompt entirely — no question is asked and the main agent implements the approved plan directly |
| `tddImplementation` | `zensu-log.sh --tdd-begin` + `pre-edit-tdd-reminder.sh` + `plan-approved-delegate.sh` + `user-prompt-tdd-reminder.sh` + `post-review-tdd-delegate.sh` + `stop-chain-enforcer.sh` + `session-start-banner.sh` / `session-start-primer.sh` + `/zensu:tdd` | When `false` (the default), the `/zensu:tdd` workflow implements in **vanilla mode**: no RED→GREEN ceremony, no FSM phase markers, the PreToolUse edit gate passes through (direct edits to `.zensu/state/` stay denied while a session is active), tests are at the agent's discretion. Everything else stays enforced — plan/log/tasks, Phase 5/6 audits (build, coverage, witness evidence cross-check), the 5-aspect review fan-out → judge second pass (`review-judge`, gated by `hooks.reviewJudge`, default on) → `code-reviewer` → auto-fix loop → `/zensu:self-review`, and the Stop-hook chain guarantee. The mode is frozen per session at `--tdd-begin` (the command echoes `mode: strict` / `mode: vanilla`) into the state file's `vanilla` flag — config flips mid-session change nothing. The ask-hooks still ask before implementation, with wording adjusted to "Zensu workflow (vanilla implementation + review chain)". The Stop-hook block reason appends a mode-aware state legend (`mode=vanilla` / `mode=strict`) so the inert `phase`/`history` fields of a vanilla session are not misread as a corrupt or never-started chain — wording only; the routing decision is identical in both modes. Note: a project-local `.zensu/config.json` checked into a repository pre-selects the mode for every clone (overlay wins per key) — the session banner and the `mode:` echo at `--tdd-begin` are the per-session signals to watch for an unexpected downgrade. Default `false` — vanilla mode is the out-of-the-box behavior; set `true` to enforce the strict RED→GREEN gate. |
| `chainEnforcer` | `stop-chain-enforcer.sh` | Disables the Stop-hook review-chain backstop. When `false`, the main agent may end its turn without completing the `zensu:code-reviewer` chain (the skill still spawns the reviewer once at Phase 6; only the hard guarantee is dropped). Replaces the retired `autoReview` flag. |
| `autopilotEnforcer` | `stop-chain-enforcer.sh` | When `false` during an active durable Autopilot run, records an audited `BLOCKED` transition and permits Stop; it never writes `DONE`. This is independent of `chainEnforcer`: disabling only the inner review backstop cannot release the outer run. Default `true`. |
| `autoFix` | `post-review-tdd-delegate.sh` | Skips auto-routing of Critical/Important findings into the main-thread fix loop |
| `autoFixIncludeSuggestions` | `post-review-tdd-delegate.sh` | When `true`, the auto-fix hook routes ALL severities (Critical, Important, Suggestion, Minor, Nit) into the main-thread fix loop instead of only Critical+Important. Default `false` preserves legacy routing. **Requires `autoFix:true`** — if `autoFix` is `false`, the entire auto-fix hook short-circuits and this flag has no effect. |
| `autoFixMaxRounds` | `post-review-tdd-delegate.sh` | Integer loop guard (default `5`, valid range `1..99`). Caps code-reviewer → in-thread-fix cycles per task. The current count is the bounded `reviewRound` field inside the project-local, revisioned `tdd-phase-<scv1-session-key>.json`; malformed values invalidate the whole workflow document and fail closed. |
| `combinedSummary` | `post-review-tdd-delegate.sh` | When `true` (default), the chain-end directive instructs the main agent to render a narrative summary (Problem → What I built → How I built it → Open, with a one-sentence TL;DR last) at every chain end (PASS, suggestions-only, max-rounds convergence). Set `false` to restore the terse stop behavior. Contrast `autoFixIncludeSuggestions` which defaults to disabled — `combinedSummary` defaults enabled to match user preference. |
| `selfReview` | `post-review-tdd-delegate.sh` + `stop-chain-enforcer.sh` | When `false`, disables the terminal `/zensu:self-review` hand-off — the review chain terminates at `zensu:code-reviewer` convergence (`chainDone`) instead of running the self-review stage. Default `true` (since 0.5.0). |
| `pendingReviewTtlHours` | `stop-chain-enforcer.sh` | Integer freshness window (default `6`, valid range `0..8760`) for the deferred-review `pending-review` marker. When the next interactive `Stop` finds a marker whose `ts` is older than this many hours, it is treated as abandoned — cleared instead of adopted — so a stale marker (e.g. from a crashed Claude Code Workflow orchestrator that never called `--pending-review-done`) cannot hijack an unrelated later session. `0` disables the guard. With `logging.timestampStyle:none`, the marker intentionally carries no `ts`, so freshness falls back to the regular file's `mtime`; timestamp formatting never disables the TTL guard. |
| `pulseSession` | `session-start-pulse.sh` | Skips the HEAD/branch banner at session start |
| `sessionBanner` | `session-start-banner.sh` + `session-start-primer.sh` | Skips the "Zensu active" user banner AND the agent-orientation primer at fresh session starts (startup/clear) |
| `tddReminder` | `user-prompt-tdd-reminder.sh` | When `false`, suppresses the per-turn TDD reminder for direct (non-Plan-mode) implementation requests — the hook injects no `additionalContext` and the agent is never prompted to ask about `/zensu:tdd` outside the Plan-mode path. Default `true`. The reminder is advisory (never blocks an edit) and is already silent when a prompt is empty or a TDD session is active. |
| `zenMode` | `user-prompt-zen-mode.sh` | When `false`, suppresses the per-prompt zen-mode reminder — the `/zensu:zen-mode` skill still runs and still writes its marker, but the contract is no longer re-injected, so the mode fades after a few turns like any one-time instruction. Default `true`. While the mode is off the hook still pays its principal check, session bind, and config read before the marker test short-circuits it — cheap, but not free; it reads no prompt and emits nothing. |
| `intentRouter` | `user-prompt-intent-router.sh` | When `false`, suppresses the UserPromptSubmit product-planning intent router — keyword-bearing prompts are no longer screened and no main-thread planning-skill triage steer is injected. Default `true`. Advisory steering only; it never blocks a prompt. |
| `mcpGate` | `pre-bash-zensu-gate.sh` | When `false`, disables the Zensu CLI write-gate — state-mutating `zensu` commands are no longer default-denied on the main thread. Read/telemetry commands are always allowed regardless of this flag. Only active main-thread skill workflow windows are exempt while the gate is on; neutral subagents such as `zensu-plm` are not. For a deliberate one-off main-thread mutation use `ZENSU_MCP_GATE=off` (honored inline as a command prefix). Reads, `--help`, and writes to a localhost backend (`--api-url`/`ZENSU_API_URL`) are never gated regardless of this flag. Default `true`. |
| `bashWriteGate` | `pre-bash-source-write-gate.sh` | When `false`, disables the source-write integrity gate — raw Bash writes (`>`/`>>`, `tee`, `sed -i`, `dd of=`, heredoc) to source files are no longer inspected. While enabled (the default), it denies overwriting an existing git-tracked source file inside the project (A) or writing a source file outside the session root into a sibling/main checkout (B); new files inside the project, gitignored/untracked files, non-source extensions, and temp roots are never gated. For a deliberate one-off use an inline `ZENSU_BASH_WRITE_GATE=off` (or `ZENSU_MCP_GATE=off`) prefix; the temp-root set is overridable via `ZENSU_BSWGATE_TEMP_DIRS`. Default `true`. |
| `reviewJudge` | `/zensu:tdd` review chain (agent stage, not a hook script) | When `false`, the review chain skips the `review-judge` second pass — the consume-mode `code-reviewer` receives the five-aspect merge unchanged (the pre-judge chain behavior). While enabled (the default), ONE `zensu:review-judge` agent runs between the aspect merge and the consume-mode reviewer: it re-reads the changed files fresh, adds `JUDGE-*` findings for cross-cutting issues, requirement drift, and missed edge cases, and its `Panel-FP:` meta-verdicts neutralize false-positive panel findings before the auto-fix loop routes them. Default `true`. |
| `secretScan` | `pre-write-secret-scan.sh` | When `false`, disables the secret gate — Write/Edit/MultiEdit/NotebookEdit payloads and Bash raw-write command text are no longer matched against `hooks/lib/secret-patterns.js`. While enabled (the default), a payload matching a curated rule (provider tokens, PEM headers incl. PKCS#8, high-entropy assignment) is denied with the rule name and remediation; file-tool `test(s)/`/`__tests__/`/`spec(s)/`/`testdata/`/`evals/`/`fixtures/`/`*.example.*` paths, `zensu-secret-allow` lines, and placeholders are never gated, and parser errors fail open. For a deliberate one-off use `ZENSU_SECRET_SCAN=off` (env, or inline prefix on a Bash command). Default `true`. |
| `context.compactionNudge` | `user-prompt-context-nudge.sh` | When `false`, suppresses the UserPromptSubmit context-compaction nudge entirely — the hook reads no transcript and never proposes `/compact`. Default `true`. Lives under the top-level `context` node (not `hooks`). |
| `context.nudgeThreshold` | `user-prompt-context-nudge.sh` | Integer percent (default `50`, valid range `1..99`) of context-window occupancy at or above which the nudge fires. Out-of-range or non-integer values fall back to `50`. **Requires `context.compactionNudge:true`.** |
| `context.windowSize` | `user-prompt-context-nudge.sh` | Optional integer token budget used as the 100% denominator when computing occupancy (valid range `1000..100000000`). **Unset by default** — since hooks aren't handed the real window size, the nudge then stays silent at or below 200k occupancy (a near-full 200k session is handled by Claude Code's own auto-compaction) and treats occupancy past 200k as a proven 1M window. Set it explicitly to the model's true window (e.g. `1000000` for a 1M model — or a sub-200k value to opt into earlier nudges) for accurate percentages on any window. **Requires `context.compactionNudge:true`.** |

**Resolution rules:**

- File missing -> all hooks active (default, backward compatible)
- Key missing -> hook active
- Only an explicit boolean `false` disables a hook
- Override the config path via the `ZENSU_CONFIG` environment variable

> Flag names are **case-sensitive** and must be **JSON booleans**, not strings. A misspelled key or a quoted `"false"` is silently treated as enabled.

**Disable everything:**

```json
{
  "hooks": {
    "autoTdd": false,
    "chainEnforcer": false,
    "autopilotEnforcer": false,
    "autoFix": false,
    "pulseSession": false
  }
}
```

**Selective opt-out (e.g. silence the pulse banner only):**

```json
{
  "hooks": {
    "pulseSession": false
  }
}
```

A complete reference file with all flags enabled is included as [`config.example.json`](config.example.json) at the repo root. Copy it to `~/.zensu/config.json` if you prefer an explicit baseline.

> **Auto-fix prerequisite:** `autoFix:true` is required for `autoFixIncludeSuggestions` and `autoFixMaxRounds` to have any effect. If `autoFix:false`, the scoped reviewer completion is still claimed exactly once and receives a ticket-bound close/self-review handoff, but no findings are changed and no auto-fix loop runs.

### Config Resolution Order

The plugin **deep-MERGES** the config files field by field to build the effective `config.json` — global as the base, the project-local file overlaid on top. Precedence, lowest to highest:

1. `$HOME/.zensu/config.json` (global base). Every key here applies unless a higher level overrides it.
2. `$CLAUDE_PROJECT_DIR/.zensu/config.json` (project-local overlay). Wins **per key** over the global file; keys it does not set **fall through** to the global value. Auto-discovered — `CLAUDE_PROJECT_DIR` is set by Claude Code for all hook subprocesses, no user setup required.
3. `$ZENSU_CONFIG` (environment override). When set, it is used **verbatim as a full override — no merge**, the explicit escape hatch for a single shell session.

A missing or malformed file is treated as `{}`, and any key absent from the merged result falls back to the hook's built-in default. So a downstream project can commit a project-local `.zensu/config.json` that sets only a few keys (e.g. enabling `autoFixIncludeSuggestions:true`) and the developer's other global settings still apply.

> If your project commits a `.zensu/config.json` and a developer also has `~/.zensu/config.json`, the two are **merged field by field** — the project-local file wins per key, and keys it omits keep the developer's global value. Use `ZENSU_CONFIG=/path/to/other.json` to bypass the merge entirely for one session.

### Log Timestamp Style

The `/zensu:tdd` workflow writes a session log under `.zensu/logs/YYYY-MM-DD-HHMM_tdd-<slug>.log` with one line per RED/IMPL/GREEN phase. The wall-clock prefix on each line can be reformatted or suppressed via `~/.zensu/config.json`:

| Style | Inline format | Example |
|---|---|---|
| `wall` (default) | `[HH:MM:SS]` | `[14:23:45] step1 RED test_isOdd — FAIL` |
| `relative` | `[+HH:MM:SS]` from session start (< 24h); `[+Dd HH:MM:SS]` for deltas ≥ 24h | `[+00:01:23] step1 RED test_isOdd — FAIL` / `[+1d 03:45:12] step42 GREEN test_persist — PASS` |
| `none` | no prefix | `step1 RED test_isOdd — FAIL` |

Filenames retain the `YYYY-MM-DD-HHMM` session timestamp for uniqueness across multiple sessions on the same day; only the inline log-entry prefixes are affected.

Example (relative timestamps):

```json
{
  "logging": {
    "timestampStyle": "relative"
  }
}
```

Invalid values, missing keys, malformed JSON, or a missing `node` binary all fall back to `wall`.

### Claude Environment and Native Placeholders

| Variable | Default | Description |
|----------|---------|-------------|
| `ZENSU_API_KEY` | — | API key for headless/CI-CD auth — piped to `zensu auth login --with-token -` (see [Authentication](#authentication)); not needed when using OAuth browser login |
| `ZENSU_API_URL` | `https://api.zensu.dev` | Points the `zensu` CLI at a self-hosted Zensu backend (overridden per-invocation by the `--api-url` global flag). See [Self-hosting](#self-hosting). |
| `ZENSU_TDD_GATE` | — | Set to `off` to disable the TDD Phase Gate for legitimate non-TDD edits during a main-thread `/zensu:tdd` session. Any other value (or unset) leaves the gate active while the session's chain-state `active` flag is set. |
| `ZENSU_TEST_WITNESS` | — | Set to `off` to disable the test-run witness hook (`post-bash-witness.sh`) for the current session. Any other value (or unset) leaves the witness active while the exact Session Control key's chain-state `active` flag is set. Per-Bash-call recording lives at `${CLAUDE_PROJECT_DIR:-.}/.zensu/logs/witness-<scv1-session-key>.log`. |
| `ZENSU_CHAIN` | — | Set to `off` to disable only the inner TDD review-chain backstop. Equivalent to `hooks.chainEnforcer:false` but scoped to the shell; it does not release an active outer Autopilot run. Exception: in the three session-binding blocks that precede routing (most often a deleted or moved worktree, whose immutable record can never resolve again) no outer run can be read or advanced either, so both switches release there — the stderr line states that no completion was proven, only that the guard was waived. |
| `ZENSU_AUTOPILOT` | — | Set to `off` to stop an active durable Autopilot run through an audited `BLOCKED` transition. Equivalent to `hooks.autopilotEnforcer:false`; it never records `DONE`, merge, release, or deployment success. |
| `CLAUDE_AGENT_TYPE` | — | Legacy introspection variable only. Security decisions use the trusted top-level `agent_type` from each hook payload, never this environment variable. |
| `CLAUDE_PLUGIN_ROOT` | — | Claude-native plugin placeholder in top-level Skill/Agent content and plugin-root environment value in hook subprocesses. Stateful Skill commands use the rendered absolute value; every hook also verifies the executing plugin root. No user setup required. |
| `CLAUDE_PLUGIN_DATA` | — | Claude-native plugin data placeholder in top-level Skill/Agent content and plugin-data environment value in hook subprocesses. Stateful Skill commands pass the rendered value only to that helper invocation; Session Control validates its private record below this directory. |
| `CLAUDE_CODE_SESSION_ID` | — | Host-provided environment value in Bash and hook subprocesses. It matches the hook payload session id but is **not a secret or capability**; stateful helpers accept it only after the private plugin-data record, executing root, runtime digest, and project binding all validate. |
| `CLAUDE_SESSION_ID` | — | Claude-native session placeholder available in top-level Skill content. Zensu does not copy it into a public selector; the state helper binds from `CLAUDE_CODE_SESSION_ID` and the private record at each call. |
| `CLAUDE_PROJECT_DIR` | — | Stable project directory supplied by Claude. Fresh SessionStart registration uses it where required; the immutable record remains the workflow-state anchor after `CwdChanged`. |
| `CLAUDE_ENV_FILE` | — | Claude's general shell-environment propagation file. Zensu Session Control deliberately never reads or writes it, so plugin-private authority cannot leak into main or subagent Bash environments. |

## Data & Privacy

When using this plugin, certain data is transmitted by the `zensu` CLI to the Zensu backend API.

**What data is transmitted:**
- Product names, feature titles, and descriptions
- Security classifications and OWASP tags
- File paths (not file contents), git SHAs, and branch names
- Vision documents (may contain product strategy and roadmap details)
- Pulse session metadata: tool names, durations, feature IDs, file paths

**Where it goes:**
- Default: `https://api.zensu.dev` (all data transmitted via HTTPS)
- Self-hosted Zensu deployments — see [Self-hosting](#self-hosting) below

**What is NOT transmitted:**
- Source code content
- File contents (only paths)
- Error messages (unless `freetext_logging` is explicitly enabled for Pulse)

**Data retention:**
- Pulse sessions: 90 days by default (configurable)

### Self-hosting

The `zensu` CLI talks to the SaaS default backend (`https://api.zensu.dev`). To point it at your own Zensu deployment, set the API URL — via the `--api-url` global flag, the `ZENSU_API_URL` environment variable, or the CLI's stored host (`zensu auth login` against your deployment):

```bash
export ZENSU_API_URL=https://api.example.internal
# or per-invocation:
zensu --api-url https://api.example.internal features list --product <id>
```

See `zensu --help` / `zensu auth --help` for the precedence between the flag, the env var, and the stored host. The hosted MCP server (`mcp.zensu.dev`) — used by the Zensu web app's own AI assistant — is no longer wired into this plugin. The plugin `.mcp.json` contains only the local Playwright driver used for live verification; it has no Zensu API or hosted-MCP endpoint to redirect.

**Regulated environments:**
If you operate under GDPR, CCPA, or similar data protection regulations, review the data transmission above and consider using a self-hosted instance to maintain full control over your data.

## Platform Support

Hooks use `bash -c` and require a POSIX-compatible shell. Supported platforms:
- macOS
- Linux

Windows users need WSL or Git Bash. Native `cmd.exe` and PowerShell are not supported for hooks.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `zensu` CLI not found | Install the CLI (`curl -fsSL https://zensu.dev/install.sh \| sh`) and ensure it is on `PATH` — the session banner warns when it is missing |
| Backend unreachable / `zensu` command errors | Verify network connectivity to `https://api.zensu.dev` (or your self-hosted `ZENSU_API_URL` — see [Self-hosting](#self-hosting)), and that `zensu auth status` shows a logged-in session |
| Invalid API key | Verify `ZENSU_API_KEY` format (`zsk_...`) and re-run `echo "$ZENSU_API_KEY" \| zensu auth login --with-token -` — see [API Key (CI/CD)](#api-key-cicd) |
| Hook errors on Windows | Use WSL or Git Bash (see [Platform Support](#platform-support)) |
| Planning agent cannot mutate Zensu state | Expected: `zensu:zensu-plm` receives neutral `host-profile-v1` context but its agent definition and enforcement gate expose only `Read`/`Grep`/`Glob`. Return to the top-level interactive thread and invoke the matching `/zensu:bootstrap`, `/zensu:ghost-scan`, `/zensu:implement`, or `/zensu:security-review` skill there. If even the interactive thread is neutral, run `/zensu:doctor` and compare the installed Claude Code version with the pinned supported version; a host/runtime mismatch requires updating or restoring the supported host, then starting a fresh session. |
| OAuth login not opening | Check your default browser settings |
| Review chain will not advance (`--review-ticket` refuses, `--current-review-ticket` reports nothing, `/zensu:reset-review-limit` not applicable) | Run `zensu-log.sh --chain-status` (or `/zensu:doctor`) to read the chain shape and its supported next command. Only a receipt that disagrees with its own workflow document is a true wedge; `/zensu:recover-chain`, from the session that owns the chain, repairs exactly that and nothing else. Never arm a fresh chain to work around a lock or commit failure — those report their own message and leave the budget intact. |
| TDD phase gate blocking a legitimate edit | Set `ZENSU_TDD_GATE=off` for that edit only, or let the top-level `/zensu:tdd` Skill declare the correct phase via `CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --phase <PHASE> --step <step_id>` first |
| Stateful helper reports that its rendered Session Control binding is unavailable | Confirm Claude Code `2.1.211` or newer. If the plugin was updated normally, keep already-running sessions on their previous version and start a fresh session for the new version. Do not run `/reload-plugins` or overwrite a loaded cache directory during this migration; restore that session's previous cache bytes if either occurred. Do not source an internal binder or search for another plugin root. The retired `~/.zensu/plugin-root` locator is never consulted by the updated plugin. Delete it only once no Claude Code session from an older installation is still running; the plugin never deletes it automatically. |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on reporting bugs, suggesting features, and submitting pull requests.

## Security

See [SECURITY.md](SECURITY.md) for our responsible disclosure policy.

## License

**Functional Source License, Version 1.1, Apache 2.0 Future License** ([FSL-1.1-Apache-2.0](LICENSE)).

The FSL is a source-available license designed for SaaS projects. In short:

- **You can use it for any Permitted Purpose** — internal use, modifications, forks, commercial projects, professional services for clients, education, research.
- **You cannot use it for a Competing Use** — i.e. you may not offer a commercial product or service that substitutes for the Zensu plugin or the Zensu SaaS, or provides substantially similar functionality, while this restriction is in effect.
- **Auto-conversion to Apache 2.0** — each release converts to the Apache License 2.0 on the second anniversary of its public availability. After that date, that release is unrestricted OSS.

The full text and the canonical FAQ live at [fsl.software](https://fsl.software/). For commercial-use questions outside the Permitted Purpose, contact [contact@zensu.dev](mailto:contact@zensu.dev).
