<p align="center">
  <a href="https://zensu.dev"><img src="assets/zensu-logo.svg" alt="Zensu" width="120"></a>
</p>

# Zensu Plugin for Claude Code

[![License: FSL-1.1-Apache-2.0](https://img.shields.io/badge/License-FSL--1.1--Apache--2.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.8.5-green.svg)](CHANGELOG.md)

Zensu is a Product Lifecycle Manager that treats features as first-class citizens. This plugin covers the **entire development lifecycle** inside Claude Code — from product planning through disciplined implementation to release readiness.

## The Three Layers

```
Planning              →  Implementation  →  Tracking
zensu-plm                /zensu:tdd         Zensu Dashboard
/zensu:bootstrap         code-reviewer      (Web UI)
/zensu:ghost-scan        auto-fix loop
/zensu:implement         (main thread)
```

**Layer 1 — Planning (WHAT is being built?):** Bootstrap a greenfield product from a vision document (`/zensu:bootstrap`), or scan an existing codebase to discover and import undocumented features (`/zensu:ghost-scan`) — or, for a brownfield repo that *also* ships a forward plan doc, run the **hybrid**: ghost-scan what is built, then add the plan's not-yet-built items as `planned` features. All end with features tracked in Zensu with security profiles, user journeys, and pricing tiers. Each discovered feature is seated at a **v1 build-out baseline** (a revision); features grow from there through deeper revisions (stages) and subfeatures (parts).

**Layer 2 — Implementation (HOW is it built securely?):** Strict TDD (Test-Driven Development — write a failing test first, then the minimum implementation to make it pass, then refactor) enforced by a PreToolUse FSM (Finite State Machine — a discipline tracker with a small set of allowed states and transitions) gate (`pre-edit-tdd-reminder.sh`) that blocks edits outside the declared RED→IMPL→GREEN phase. Followed by 5 sequential specialist code-review perspectives.

**Layer 3 — Tracking (HOW is progress tracked?):** Web dashboard for POs and stakeholders — security scores, tier matrix, journey health, coverage trends. No terminal required.

## Agent & Workflow Overview

```mermaid
flowchart TD
    subgraph Planning["Layer 1: Planning"]
        A1["/zensu:bootstrap<br/>(greenfield)"] --> B["zensu-plm Agent"]
        A2["/zensu:ghost-scan<br/>(brownfield)"] --> B
        B --> C["Features in Zensu"]
    end

    subgraph Implementation["Layer 2: Implementation"]
        C -->|"/zensu:implement"| D["Load Feature Context"]
        PLAIN["Plan approval (ExitPlanMode)<br/>plain Claude Code, no Zensu"] -->|"ask, then invoke skill on yes"| E
        D --> E["/zensu:tdd skill<br/>(main thread)"]
        E --> RED["RED — write failing test"]
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
    style GATE fill:#888,color:#fff
    style K fill:#ffa94d,color:#fff
    style SR fill:#dcfce7,stroke:#166534,color:#1e293b
    style M fill:#51cf66,color:#fff
```

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
    A["zensu CLI command<br/>(Bash, main thread)"] --> B{"Read or telemetry command?<br/>list / get / search / suggest verbs<br/>+ pulse, journeys health, …"}
    B -->|"yes"| ALLOW(["ALLOW"])
    B -->|"no — state mutation"| C{"ZENSU_MCP_GATE=off<br/>or hooks.mcpGate=false?"}
    C -->|"yes (escape hatch)"| ALLOW
    C -->|"no"| D{"Caller is the<br/>zensu-plm agent?"}
    D -->|"yes"| ALLOW
    D -->|"no"| E{"Inside an active workflow?<br/>workflowActive = true<br/>AND tool in workflowTools (per-skill scope)"}
    E -->|"yes"| ALLOW
    E -->|"no"| DENY(["DENY<br/>run the matching skill<br/>or delegate to zensu-plm"])

    style A fill:#4a9eff,color:#fff
    style ALLOW fill:#51cf66,color:#fff
    style DENY fill:#ff6b6b,color:#fff
```

A skill opens a **scoped** window with
`zensu-log.sh --workflow-begin --tools "<exact tool set>"`: the bypass then allows **only**
that skill's declared tools — so `/zensu:implement` cannot forge a `set_security_classification`
it never declared — and `--workflow-end` closes it again. The `--tools` list stays tool-name-keyed;
the gate maps each CLI command back to its canonical tool name to check membership. `ZENSU_MCP_GATE=off`
disables the gate for a deliberate one-off. A structure test (`tests/structure/test-skill-workflow-markers.sh`)
fails the build if any skill runs a mutation command without the `--workflow-begin` /
`--workflow-end` markers, so a new skill cannot silently regress the contract.

## Installation

```bash
claude plugin marketplace add MKITConsulting/zensu-claude-code
claude plugin install zensu --scope project
```

## Authentication

### OAuth Browser Login (Recommended)

No configuration needed. When you first use a Zensu tool, Claude Code will automatically open your browser to sign in. Tokens are cached and refreshed automatically.

### API Key (CI/CD)

For headless environments where browser login isn't available, authenticate the `zensu` CLI with an API key instead of the OAuth browser flow. Set `ZENSU_API_KEY` and use the CLI's auth command:

```bash
export ZENSU_API_KEY=zsk_...
zensu auth login   # see `zensu auth --help` for the exact non-interactive / token flags
```

Verify the session with `zensu auth status`; clear it with `zensu auth logout`. Run `zensu auth --help` for where the token is cached and the headless-auth options.

To point the CLI at a self-hosted Zensu backend, see [Self-hosting](#self-hosting) below.

## What's Included

### CLI (`zensu`)

The plugin drives Zensu through the typed `zensu` CLI — install it with `curl -fsSL https://zensu.dev/install.sh | sh` and authenticate with `zensu auth login`. It provides commands for feature CRUD, security analysis, tier management, user journeys, product bootstrap, ghost scans, pulse sessions, and more (`zensu --help`). The hosted MCP server (`mcp.zensu.dev`) still exists for the Zensu web app's own AI assistant, but is no longer wired into this plugin.

### Agents (3)

| Agent | Role | How It Works |
|-------|------|--------------|
| **zensu-plm** | Product Lifecycle Manager | Orchestrates all Zensu workflows — feature tracking, security reviews, release readiness, bootstrap, ghost scans |
| **code-reviewer** | Quality Review | Consolidates the review. Standalone: walks 5 specialist perspectives (conventions, bugs, architecture, tests, security) in a single READ-ONLY agent. In the `/zensu:tdd` chain: runs in **fan-out consume mode**, emitting the report the main thread merged from five parallel `review-aspect` agents (no re-read, no build/test). |
| **review-aspect** | Single-Perspective Review | READ-ONLY reviewer scoped to ONE perspective. The `/zensu:tdd` chain spawns five in a single parallel batch (one per perspective), then merges their findings in the main thread. Runs zero build/test commands — the suite already ran in the Phase 6 audit. |

> **TDD is no longer an agent.** Since 0.4.0 the strict RED→GREEN TDD workflow runs in the **main thread** via the `/zensu:tdd` skill (see Skills below) — the old `tdd-manager` subagent lost too much implementation context. Since 0.6.0 the review chain fans out to five parallel `review-aspect` subagents and consolidates through a single `code-reviewer` spawn, so the existing hook chain (round counter, auto-fix loop, self-review) is unchanged.

#### /zensu:tdd — How It Enforces Discipline

Unlike prompt-based TDD ("please write tests first"), the `/zensu:tdd` workflow **structurally prevents** violations via a PreToolUse FSM gate on Edit/Write/MultiEdit:

- **Phase declaration.** Before any edit, the main agent declares the current TDD phase via `bash $CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-log.sh --phase <PHASE> --step <step_id>`. Valid phases: `RED_WRITE`, `RED_RUN`, `RED_FAIL`, `IMPL`, `GREEN_RUN`, `GREEN_PASS`, `REFACTOR`.
- **Gate enforcement.** The PreToolUse hook (`pre-edit-tdd-reminder.sh`) blocks edits whose declared phase violates FSM transitions. In particular, `IMPL` requires a prior `RED_FAIL` marker for the **same step** — there is no path to production code without a failing test on record.
- **State.** Phase markers persist at `.zensu/state/tdd-phase-<session>.json`. Each step's history is auditable from the file.
- **Activation.** Phase 0 of the skill calls `zensu-log.sh --tdd-begin`, which sets a per-session chain-state `active` flag. The gate (and the Bash witness) enforce **only** while that flag is set; sessions with no active TDD chain-state — other main-thread work, other subagents, plain CLI — are never gated. (Pre-0.4.0 this keyed on `CLAUDE_AGENT_TYPE=zensu:tdd-manager`.) Bypass via `ZENSU_TDD_GATE=off` for legitimate non-TDD edits explicitly authorized by the user. Setting `hooks.tddImplementation:false` switches the workflow to **vanilla mode** — the gate passes through and the RED→GREEN ceremony is dropped while the evidence audits and review chain stay enforced (see the Hook Opt-Out table).

Additional features: dependency graph for independent-step sequencing, 3-retry IMPL escalation on GREEN-fail with progressive context, completeness audit (mtime discipline + build verification), real-time progress log at `.zensu/logs/`.

**Full workflow reference:** [docs/tdd-manager-workflow.md](docs/tdd-manager-workflow.md) — Mermaid flow chart, per-step FSM state diagram, hook gate behavior table, environment variables contract, discipline patches 1-9 + B, four-channel logging.

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

### Skills (11)

| Skill | Description |
|-------|-------------|
| `/zensu:bootstrap` | Bootstrap a product from a vision document — creates features, journeys, security profiles, tiers |
| `/zensu:implement` | Implement a feature end-to-end with artifact linking and revision tracking |
| `/zensu:tdd` | Strict RED→IMPL→GREEN TDD in the main thread, enforced by the PreToolUse phase-gate; ends by spawning `zensu:code-reviewer` with a Stop-hook-guaranteed auto-fix chain. Invoked by plan-approval (on your confirmation), `/zensu:implement`, or directly. |
| `/zensu:plan-review` | Revalidate an implementation/design plan **before** coding: dynamically casts a tailored multi-agent reviewer team via `TeamCreate` (default 6, from a 12-persona pool), runs them in parallel as read-only validators, then consolidates one report with a GO / GO-WITH-CHANGES / REVISE / NO-GO verdict plus concrete plan amendments. Reviews the plan only — writes no code, triggers no TDD. |
| `/zensu:pr-team-review` | Multi-agent review of an **existing GitHub PR**: scouts the PR, auto-casts a tailored reviewer team from a 14-persona pool, fetches the PR into an isolated git worktree (main checkout untouched), spawns the reviewers in parallel, runs a debate + synthesis pass, then publishes one consolidated GitHub review (inline comments + overall body) via `gh api`. Complements `/zensu:plan-review` (which validates a plan before code exists). |
| `/zensu:security-review` | Comprehensive security review: classification, analysis, STRIDE threat model, review completion |
| `/zensu:ghost-scan` | Scan a repository with a multi-perspective agent fan-out to discover undocumented features, user journeys, and docs, and import them |
| `/zensu:pulse` | Developer journal — track coding sessions with privacy-first activity logging |
| `/zensu:reset-review-limit` | Reset the auto-fix loop round counter so the chain can resume past `autoFixMaxRounds` within the same session. Deletes `${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}/rounds-*.json` and re-arms the Stop-hook chain (clears `chainDone` + `*.stopblocks`); idempotent and symlink-safe. |
| `/zensu:self-review` | Terminal self-reflection stage of the review chain. After `zensu:code-reviewer` converges, re-reads this session's own changes across 7 dimensions, takes at most one fix round under the phase-gate (never re-running the reviewer), then owns the chain terminus (`--chain-done`) and renders the final report with a `## Self-Review Summary`. Hard-enforced via `codeReviewDone`/`selfReviewFixed`; gated by `hooks.selfReview`. |
| `/zensu:zensu-help` | Q&A skill — explains Zensu PLM concepts and plugin internals (agents, hooks, FSM, config flags). Read-only; routes workflow requests to the appropriate action skill. |

### Hooks (12)

| Hook Script | Event | Config Flag | Description |
|-------------|-------|-------------|-------------|
| `session-start-pulse.sh` | SessionStart | `pulseSession` | Emits HEAD/branch banner and prepares pulse session context at startup |
| `session-start-banner.sh` | SessionStart | `sessionBanner` | User-facing "Zensu PLM vX active" banner + usage hints (Plan mode → ask whether to run `/zensu:tdd`, gate-enforced edits when you do, skills list). Plain stdout, shown to the user. Fires only on fresh starts (`source=startup`/`clear`), silent on `resume`/`compact`. Skipped when `sessionBanner:false`. |
| `session-start-primer.sh` | SessionStart | `sessionBanner` | Model-facing orientation: injects a short `additionalContext` primer so the agent proactively uses Plan mode and asks before running `/zensu:tdd`. Same fresh-start filter + `sessionBanner` gate as the banner. |
| `pre-edit-tdd-reminder.sh` | PreToolUse Edit/Write/MultiEdit | `ZENSU_TDD_GATE` (env) | TDD Phase Gate. Enforces RED→IMPL→GREEN FSM via `.zensu/state/tdd-phase-<sid>.json`. Active only while the session's chain-state `active` flag is set (by `zensu-log.sh --tdd-begin`); pre-0.4.0 it keyed on `CLAUDE_AGENT_TYPE=zensu:tdd-manager`. Bypass with `ZENSU_TDD_GATE=off`. Bash file mutations are intentionally **not** gated — they remain the responsibility of the `/zensu:tdd` prompt discipline + PostToolUse code-reviewer chain. |
| `pre-bash-zensu-gate.sh` | PreToolUse `Bash` | `mcpGate` (+ `ZENSU_MCP_GATE` env) | Zensu CLI write-gate. Parses `zensu <noun> <verb>` from the Bash command, resolves each via `hooks/lib/zensu-cli-map.sh`, and classifies via `hooks/lib/zensu-mcp-tools.sh`: read/telemetry commands (`zensu_is_read_tool`) pass ungated; every state-mutating command is **default-denied** unless one of — the caller is the `zensu-plm` agent (`agent_type` match), the command is declared in an active skill workflow window (opened by `zensu-log.sh --workflow-begin --tools "…"`, e.g. inside `/zensu:implement` or `/zensu:bootstrap`), or a bypass is set (`ZENSU_MCP_GATE=off` env / `mcpGate:false` config). A deny returns `permissionDecision:deny` with remediation pointing at the matching skill or the zensu-plm agent. A convention-nudge, not a hard boundary (once the CLI's token is on disk an agent can `curl` the API directly): forces mutations through the workflow conventions (dedup, user journeys, baseline revisions, security classification, release-readiness gates) instead of raw main-thread CLI calls. |
| `plan-approved-delegate.sh` | PostToolUse ExitPlanMode | `autoTdd` | After the user approves a Plan-mode plan that adds executable code, directs the main agent to **ask the user** (via the `AskUserQuestion` tool) whether to run the `/zensu:tdd` skill (in-thread, no subagent), then run it on confirmation or implement the plan directly on decline. The question is skipped on fast-paths: doc-only plans, an explicit TDD preference already in the approval message (e.g. `kein tdd` / `mit tdd`), and non-interactive Auto Mode (defaults to running TDD). Skipped entirely when `autoTdd:false`. |
| `post-review-tdd-delegate.sh` | PostToolUse Agent | `autoFix` (+ `autoFixIncludeSuggestions`, `autoFixMaxRounds`, `combinedSummary`) | Auto-fix loop. After `zensu:code-reviewer` completes, routes Critical/Important findings back to the **main thread** to be fixed in-thread under the phase-gate (or ALL severities when `autoFixIncludeSuggestions:true`), then the main agent re-spawns the reviewer. Round counter persisted at `${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}/rounds-<session_id>.json` (project-local default since 0.3.23 — claude-code's auto-set `CLAUDE_PLUGIN_DATA` is intentionally IGNORED so the round budget resets per worktree); on reaching `autoFixMaxRounds` (default 5) it converges — with `hooks.selfReview` enabled (the 0.5.0 default) it marks `codeReviewDone` and hands off to the terminal `/zensu:self-review` stage, which owns `--chain-done`; otherwise it sets `chainDone` directly — and emits a convergence directive instead of routing again — pointing the user at `/zensu:reset-review-limit` to grant another budget without ending the session. At every chain-end branch (PASS, suggestions-only, max-rounds convergence) it appends a `CHAIN-END SUMMARY` directive — a narrative report (Problem → What I built → How I built it → Open, with the one-sentence TL;DR last). Disable summary with `combinedSummary:false`. |
| `post-bash-witness.sh` | PostToolUse Bash | `ZENSU_TEST_WITNESS` (env) | Test-Run Witness. Records every Bash tool invocation (command, exit code, stdout tail) to `${CLAUDE_PROJECT_DIR:-.}/.zensu/logs/witness-<session>.log` as an independent evidence channel. Active only while the session's chain-state `active` flag is set. The Phase 6 audit cross-checks each CHECKPOINT/AUDIT `cmd="..."` claim against the witness log to detect hallucinated test runs. Bypass with `ZENSU_TEST_WITNESS=off`. |
| `stop-chain-enforcer.sh` | Stop | `chainEnforcer` (+ `ZENSU_CHAIN` env) | Review-chain backstop. Blocks the main agent from ending its turn while a TDD session has finished implementation (`implComplete`) but the review chain has not terminated (`chainDone`) — forcing the `zensu:code-reviewer` spawn after implementation and after each in-thread fix round (this replaces the deleted `post-tdd-review-delegate.sh` Agent-completion trigger; since 0.5.0, once `codeReviewDone` is set with `hooks.selfReview` enabled it instead forces the terminal `/zensu:self-review` Skill until `chainDone`). Activation scoped to chain-state `active`; anti-deadlock stop-block budget = `autoFixMaxRounds + 3`. Disable with `chainEnforcer:false` or `ZENSU_CHAIN=off`. |
| `user-prompt-context-nudge.sh` | UserPromptSubmit | `context.compactionNudge` (+ `context.nudgeThreshold`, `context.windowSize`) | Context-compaction nudge. On each user prompt it tail-reads the session transcript's most recent `usage` block, computes context occupancy (`input_tokens + cache_read_input_tokens + cache_creation_input_tokens` ÷ context size — when `context.windowSize` is unset the nudge stays silent at or below 200k occupancy and treats occupancy past 200k as a proven 1M window) and, once usage reaches `context.nudgeThreshold` (default `50`%), injects a model-facing `additionalContext` reminder so the **main-thread** agent proactively proposes `/compact` to the user. It never triggers compaction itself (only the user can) and never blocks the prompt — missing `node`/transcript, sub-threshold usage, or any error exits 0 silently. A per-session state file (`${CLAUDE_PROJECT_DIR:-.}/.zensu/state/context-nudge-<sid>.txt`) records the last 10%-band that fired, so the reminder repeats once per band climb (50→60→70…) instead of every prompt and re-arms after a compaction shrinks the context. All three settings live under the top-level `context` node of `.zensu/config.json` (not `hooks`); disable with `context.compactionNudge:false`. |
| `user-prompt-intent-router.sh` | UserPromptSubmit | `intentRouter` | Product-planning intent router. On each user prompt a whole-word, case-insensitive regex (`zensu`, `product`, `feature`, `roadmap`, `milestone`, `bootstrap`, `ghost scan`, `journey`, `tier`, plus inflections) screens for Zensu planning/tracking intent; on a hit it injects a model-facing `additionalContext` directive steering the agent to run the greenfield/brownfield/hybrid triage — ask the three project-context questions, then route the work through the **zensu-plm** agent — instead of running `zensu` CLI commands directly. The directive carries an explicit dismiss clause so an ordinary coding/UI/debug task that merely mentions a word like "product"/"feature"/"tier" is answered normally. Advisory steering, not a hard gate; silent on no-keyword prompts, missing `node`, or `intentRouter:false`. |
| `user-prompt-tdd-reminder.sh` | UserPromptSubmit | `tddReminder` | Per-turn TDD reminder for **direct (non-Plan-mode)** requests. The Plan-mode path (`plan-approved-delegate.sh`) only fires on plan approval, so a direct "implement X" / "fix the bug" prompt otherwise reaches no TDD trigger. On each prompt this hook injects a model-facing `additionalContext` directive — mirroring the plan-approval decision logic + fast-paths — so the agent decides whether the request is a code change and, unless a fast-path applies, **asks** (via `AskUserQuestion`) whether to run `/zensu:tdd` before its first edit. **No prompt regex** — the (multilingual) model classifies intent, so detection is language-independent. Silent when `tddReminder:false`, when the payload has no prompt, or when a TDD session is already active for the session (reusing `pre-edit-tdd-reminder.sh`'s session resolution). Advisory steering — it never blocks an edit. |

## Typical Workflows

### New Product (Planning → Implementation → Release)

```
1. /zensu:bootstrap          → Create product, features, journeys, tiers
2. /zensu:implement ZEN-1    → Load context, plan implementation
3. /zensu:tdd                → Strict TDD in the main thread (RED→GREEN per step)
4. @code-reviewer            → 5-perspective sequential review (spawned by /zensu:tdd Phase 6, Stop-hook guaranteed)
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
- TDD orchestration (RED→GREEN cycles)
- Code review (5 sequential specialist perspectives)
- Progress logging (`.zensu/logs/`)

When the `zensu` CLI is installed and authenticated, additional capabilities activate:
- Automatic `zensu link test` and `zensu link source` after TDD completion
- Feature status updates (`zensu features status`)
- Revision creation with implementation summary (`zensu features revision`)
- Security findings fed into `zensu security review`
- Release gate validation (`zensu security validate`)

## Configuration

### Hook Opt-Out

Zensu ships twelve automatic hooks that fire across the development lifecycle (full enumeration in the [Hooks (12)](#hooks-12) table above). The configurable subset is listed below; `pre-edit-tdd-reminder.sh` has no on/off flag of its own — it is bypassed per call via the `ZENSU_TDD_GATE` env var and passes through for whole sessions frozen into vanilla mode by `tddImplementation` (see that row below). Any flagged hook can be disabled via `~/.zensu/config.json` without forking, editing, or uninstalling the plugin.

| Flag | Hook Script | Effect when `false` (boolean flags) or value (numeric flags) |
|------|-------------|---------------------|
| `autoTdd` | `plan-approved-delegate.sh` | Skips the post-approval TDD prompt entirely — no question is asked and the main agent implements the approved plan directly |
| `tddImplementation` | `zensu-log.sh --tdd-begin` + `pre-edit-tdd-reminder.sh` + `plan-approved-delegate.sh` + `user-prompt-tdd-reminder.sh` + `post-review-tdd-delegate.sh` + `session-start-banner.sh` / `session-start-primer.sh` + `/zensu:tdd` | When `false`, the `/zensu:tdd` workflow implements in **vanilla mode**: no RED→GREEN ceremony, no FSM phase markers, the PreToolUse edit gate passes through (direct edits to `.zensu/state/` stay denied while a session is active), tests are at the agent's discretion. Everything else stays enforced — plan/log/tasks, Phase 5/6 audits (build, coverage, witness evidence cross-check), the 5-aspect review fan-out → `code-reviewer` → auto-fix loop → `/zensu:self-review`, and the Stop-hook chain guarantee. The mode is frozen per session at `--tdd-begin` (the command echoes `mode: strict` / `mode: vanilla`) into the state file's `vanilla` flag — config flips mid-session change nothing. The ask-hooks still ask before implementation, with wording adjusted to "Zensu workflow (vanilla implementation + review chain)". Note: a project-local `.zensu/config.json` checked into a repository pre-selects the mode for every clone (overlay wins per key) — the session banner and the `mode:` echo at `--tdd-begin` are the per-session signals to watch for an unexpected downgrade. Default `true` (strict TDD). |
| `chainEnforcer` | `stop-chain-enforcer.sh` | Disables the Stop-hook review-chain backstop. When `false`, the main agent may end its turn without completing the `zensu:code-reviewer` chain (the skill still spawns the reviewer once at Phase 6; only the hard guarantee is dropped). Replaces the retired `autoReview` flag. |
| `autoFix` | `post-review-tdd-delegate.sh` | Skips auto-routing of Critical/Important findings into the main-thread fix loop |
| `autoFixIncludeSuggestions` | `post-review-tdd-delegate.sh` | When `true`, the auto-fix hook routes ALL severities (Critical, Important, Suggestion, Minor, Nit) into the main-thread fix loop instead of only Critical+Important. Default `false` preserves legacy routing. **Requires `autoFix:true`** — if `autoFix` is `false`, the entire auto-fix hook short-circuits and this flag has no effect. |
| `autoFixMaxRounds` | `post-review-tdd-delegate.sh` | Integer loop guard (default `5`, valid range `1..99`). Caps the number of code-reviewer → in-thread-fix cycles per session. When the cap is reached the hook sets `chainDone` and emits a convergence directive instead of routing again. State persists per session at `${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}/rounds-<session_id>.json` (project-local default since 0.3.23; claude-code's auto-set `CLAUDE_PLUGIN_DATA` is intentionally IGNORED by this hook). |
| `combinedSummary` | `post-review-tdd-delegate.sh` | When `true` (default), the chain-end directive instructs the main agent to render a narrative summary (Problem → What I built → How I built it → Open, with a one-sentence TL;DR last) at every chain end (PASS, suggestions-only, max-rounds convergence). Set `false` to restore the terse stop behavior. Contrast `autoFixIncludeSuggestions` which defaults to disabled — `combinedSummary` defaults enabled to match user preference. |
| `selfReview` | `post-review-tdd-delegate.sh` + `stop-chain-enforcer.sh` | When `false`, disables the terminal `/zensu:self-review` hand-off — the review chain terminates at `zensu:code-reviewer` convergence (`chainDone`) instead of running the self-review stage. Default `true` (since 0.5.0). |
| `pulseSession` | `session-start-pulse.sh` | Skips the HEAD/branch banner at session start |
| `sessionBanner` | `session-start-banner.sh` + `session-start-primer.sh` | Skips the "Zensu active" user banner AND the agent-orientation primer at fresh session starts (startup/clear) |
| `tddReminder` | `user-prompt-tdd-reminder.sh` | When `false`, suppresses the per-turn TDD reminder for direct (non-Plan-mode) implementation requests — the hook injects no `additionalContext` and the agent is never prompted to ask about `/zensu:tdd` outside the Plan-mode path. Default `true`. The reminder is advisory (never blocks an edit) and is already silent when a prompt is empty or a TDD session is active. |
| `intentRouter` | `user-prompt-intent-router.sh` | When `false`, suppresses the UserPromptSubmit product-planning intent router — keyword-bearing prompts are no longer screened and no zensu-plm triage steer is injected. Default `true`. Advisory steering only; it never blocks a prompt. |
| `mcpGate` | `pre-bash-zensu-gate.sh` | When `false`, disables the Zensu CLI write-gate — state-mutating `zensu` commands are no longer default-denied on the main thread. Read/telemetry commands are always allowed regardless of this flag. The `zensu-plm` agent and active skill workflow windows stay exempt even when the gate is on; for a deliberate one-off main-thread mutation use `ZENSU_MCP_GATE=off`. Default `true`. |
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

> **Auto-fix prerequisite:** `autoFix:true` is required for `autoFixIncludeSuggestions` and `autoFixMaxRounds` to have any effect. If `autoFix:false`, the entire post-review hook short-circuits and both flags are moot.

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

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ZENSU_API_KEY` | — | API key for headless/CI-CD auth — consumed by the `zensu` CLI's auth (see [Authentication](#authentication)); not needed when using OAuth browser login |
| `ZENSU_API_URL` | `https://api.zensu.dev` | Points the `zensu` CLI at a self-hosted Zensu backend (overridden per-invocation by the `--api-url` global flag). See [Self-hosting](#self-hosting). |
| `ZENSU_TDD_GATE` | — | Set to `off` to disable the TDD Phase Gate for legitimate non-TDD edits during a main-thread `/zensu:tdd` session. Any other value (or unset) leaves the gate active while the session's chain-state `active` flag is set. |
| `ZENSU_TEST_WITNESS` | — | Set to `off` to disable the test-run witness hook (`post-bash-witness.sh`) for the current session. Any other value (or unset) leaves the witness active while the session's chain-state `active` flag is set. Per-Bash-call recording lives at `${CLAUDE_PROJECT_DIR:-.}/.zensu/logs/witness-<session>.log`. |
| `ZENSU_CHAIN` | — | Set to `off` to disable the Stop-hook review-chain backstop (`stop-chain-enforcer.sh`) so the main agent may end its turn without completing the `zensu:code-reviewer` chain. Equivalent to `hooks.chainEnforcer:false` but scoped to the shell. |
| `CLAUDE_AGENT_TYPE` | — | Set by Claude Code's harness to identify the active subagent (e.g. `zensu:code-reviewer`). Since 0.4.0 the TDD Phase Gate and witness no longer key on this — activation moved to the per-session chain-state `active` flag. Retained for subagent introspection and the eval harness. |
| `CLAUDE_PLUGIN_ROOT` | — | Set by Claude Code for hook subprocesses. Resolves to the installed plugin root and is used by `hooks.json` to reference hook scripts. No user setup required. |
| `CLAUDE_PLUGIN_DATA_OVERRIDE` | — | Opt-in override for the auto-fix rounds counter location. When set, the post-review hook (`post-review-tdd-delegate.sh`) writes per-session counters to `${CLAUDE_PLUGIN_DATA_OVERRIDE}/rounds-<session_id>.json` instead of the project-local default `${CLAUDE_PROJECT_DIR:-.}/.zensu/state/rounds-<session_id>.json`. Power-user knob for centralizing the round budget across worktrees (e.g. `$HOME/.zensu/state`); leave unset for normal per-worktree behavior. Note: claude-code's auto-set `CLAUDE_PLUGIN_DATA` is intentionally IGNORED by the rounds counter (0.3.20 used it as a fallback but the fallback was unreachable in claude-code; 0.3.23 inverts the precedence so project-local wins by default). No other Zensu hook currently reads `CLAUDE_PLUGIN_DATA` — every per-session state file (`tdd-phase-*.json`, `witness-*.log`) already defaults to `${CLAUDE_PROJECT_DIR:-.}/.zensu/state/` directly. |

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

See `zensu --help` / `zensu auth --help` for the precedence between the flag, the env var, and the stored host. The hosted MCP server (`mcp.zensu.dev`) — used by the Zensu web app's own AI assistant — is no longer wired into this plugin, so there is no `.mcp.json` to redirect.

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
| Invalid API key | Verify `ZENSU_API_KEY` format (`zsk_...`) and re-run `zensu auth login` — see [API Key (CI/CD)](#api-key-cicd) |
| Hook errors on Windows | Use WSL or Git Bash (see [Platform Support](#platform-support)) |
| Agent triggers on non-Zensu tasks | The `zensu-plm` agent's `description:` frontmatter triggers it on Zensu-related keywords. To avoid this, invoke a specific agent explicitly via `@<agent-name>` or refine your prompt. |
| OAuth login not opening | Check your default browser settings |
| TDD phase gate blocking a legitimate edit | Set `ZENSU_TDD_GATE=off` for that edit only, or declare the correct phase via `bash $CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-log.sh --phase <PHASE> --step <step_id>` first |

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
