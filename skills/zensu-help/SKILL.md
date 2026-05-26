# /zensu:zensu-help

Answer questions about how Zensu (the SaaS Product Lifecycle Manager) and the Zensu Claude Code plugin itself work. Acts as an in-conversation glossary, architecture explainer, and config reference — does NOT execute workflows.

## When to Use

- User asks "what is X?", "how does Y work?", "where is Z configured?"
- User asks about plugin internals: agents, hooks, FSM, auto-fix loop, MCP server
- User asks about Zensu concepts: features, ZEN-XXX, tiers, journeys, classifications
- User asks "what changed in version X" or "how do I disable hook Y"
- User is unsure which other skill (`bootstrap` vs `ghost-scan` vs `implement`) applies to their situation

## Do NOT Use For

- Executing workflows → use `/zensu:bootstrap`, `/zensu:ghost-scan`, `/zensu:implement`, `/zensu:security-review`, `/zensu:pulse`, `/zensu:reset-review-limit`
- Modifying Zensu data — this skill is read-only Q&A

## Prerequisites

None. This skill answers from embedded knowledge and the plugin's canonical docs already present in the repository. No MCP connection, no API key, no network required.

## Core Glossary (embedded — stable concepts)

- **Product** — top-level container; owns Components, Tiers, Features, Journeys.
- **Component** — architectural module within a Product (e.g. `auth-service`).
- **Feature** — unit of capability, identified by `ZEN-XXX` (e.g. `ZEN-001`). Lifecycle: `planned → in-progress → testing → released`.
- **Tier** — pricing/availability level (e.g. Free, Pro, Team). Features map to tiers via the tier matrix.
- **Journey** — user path through one or more Features; contributes to release readiness.
- **Security Classification** — `public | internal | confidential | restricted`. Drives the 0–10 security score.
- **Security Score** — computed from classification + OWASP tags + compliance tags + security tests + reviews.
- **Revision** — versioned snapshot of a Feature's implementation summary.

## Three Layers (embedded — architecture overview)

1. **Planning** (`zensu-plm` agent) — `/zensu:bootstrap` (greenfield) or `/zensu:ghost-scan` (brownfield) produce tracked features.
2. **Implementation** (`zensu:tdd-manager` + `zensu:code-reviewer` agents) — strict RED→IMPL→GREEN TDD enforced by a PreToolUse FSM gate, followed by 5 sequential code-review perspectives, then an auto-fix loop.
3. **Tracking** — web dashboard surfaces security scores, journey health, tier matrix, coverage trends.

## Agents (embedded — one-liners)

- `zensu-plm` — orchestrates planning workflows (bootstrap, ghost-scan, security review, release readiness).
- `tdd-manager` — RED→IMPL→GREEN TDD discipline, FSM-gated edits, 3-retry IMPL escalation, completeness audit.
- `code-reviewer` — single READ-ONLY agent running 5 sequential perspectives: conventions, bugs, architecture, tests, security.

## Topic Routing (live read for volatile facts)

Before answering questions in the right column, `Read` the source file in the left column and quote `file:line` in the answer.

| Question type | Source to Read |
|---|---|
| Plugin version, declared skills/agents | `.claude-plugin/plugin.json` |
| MCP server URL, MCP tool surface | `.mcp.json` + `.claude-plugin/plugin.json` |
| Hook flags (`autoTdd`, `autoReview`, `autoFix`, `autoFixIncludeSuggestions`, `autoFixMaxRounds`, `combinedSummary`, `pulseSession`) | `README.md` § Configuration → Hook Opt-Out table |
| Config resolution order, `ZENSU_CONFIG` precedence | `README.md` § Config Resolution Order |
| Environment variables (`ZENSU_API_KEY`, `ZENSU_TDD_GATE`, `ZENSU_TEST_WITNESS`, `CLAUDE_AGENT_TYPE`, `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA`) | `README.md` § Environment Variables |
| TDD FSM details, phase transitions, gate logic, three-channel logging | `docs/tdd-manager-workflow.md` |
| Hook scripts (what each does, when it fires) | `README.md` § Hooks (7) table + `hooks/<script>.sh` source |
| Data flow, what's transmitted, retention, self-hosting | `README.md` § Data & Privacy |
| Pulse session lifecycle, idempotency, privacy guarantees | `skills/pulse/SKILL.md` + `README.md` § Data & Privacy |
| Resetting the auto-fix rounds counter / "max rounds reached" recovery | `skills/reset-review-limit/SKILL.md` + `hooks/post-review-tdd-delegate.sh:100-101` (convergence branch) |
| Workflow step order (new product / existing codebase / quick feature) | `README.md` § Typical Workflows |
| "What changed in version X" | `CHANGELOG.md` (search for `[X.Y.Z]`) |
| License / Permitted Purpose / Competing Use | `README.md` § License + `LICENSE` file |
| Platform support, Windows caveats | `README.md` § Platform Support |
| Troubleshooting (MCP unreachable, OAuth, gate blocking) | `README.md` § Troubleshooting |

## Response Style

- Cite sources as `README.md:200` or `docs/tdd-manager-workflow.md`.
- If the embedded glossary fully answers it → answer directly, no Read needed.
- If a routed source applies → Read first, quote facts verbatim, cite.
- Never invent tool names, hook names, config flags, or version numbers — verify via Read.
- If a question falls outside this skill's scope (e.g. "implement feature ZEN-042"), point the user at the right action skill instead of half-answering.
- Match the conversational register — terse if the user is terse, fuller if they ask "explain in detail".
