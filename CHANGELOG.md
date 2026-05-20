# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Project-local config resolution: `hooks/lib/zensu-config.sh` now exposes `_zensu_resolve_config` with a 3-stage lookup — `$ZENSU_CONFIG` (env override) -> `$CLAUDE_PROJECT_DIR/.zensu/config.json` (project-local, auto-discovered, no setup needed) -> `$HOME/.zensu/config.json` (global default). Resolution **REPLACES**, does not **MERGE** — the first matched file is used as-is. Downstream projects can commit a `.zensu/config.json` to opt into plugin behavior (e.g. broader auto-fix routing) without touching each developer's global config. Both existing readers (`zensu_hook_enabled`, `_zensu_log_style`) now route through the new helper, so all flags participate in the new resolution order. Backed by 3 new offline tests in `evals/config-gate/test-resolution-order-{env-override,project-local,global-fallback}.sh`.
- `hooks.autoFixIncludeSuggestions` boolean config flag (default `false`). When `true`, the post-review auto-fix hook (`hooks/post-review-tdd-delegate.sh`) routes ALL severities — Critical, Important, Suggestion, Minor, Nit — to `zensu:tdd-manager` as a single feature spec, instead of restricting auto-fix to Critical+Important and buffering Suggestions for the user. Default `false` preserves the legacy backwards-compatible routing. Requires `autoFix:true` to have effect — when `autoFix:false`, the hook short-circuits entirely. Reader `zensu_autofix_include_suggestions` lives in `hooks/lib/zensu-config.sh` and follows the same safe-fallback pattern as `zensu_hook_enabled` (missing file / missing node / malformed JSON / wrong type -> default `false`). Backed by `evals/config-gate/test-autofix-suggestions-on.sh` and `evals/config-gate/test-autofix-suggestions-off.sh` plus the shared reader test `evals/config-gate/test-helper-autofix-flags.sh`.
- `hooks.autoFixMaxRounds` integer config flag (default `2`, valid range `1..99`). Loop guard for the code-reviewer -> tdd-manager cycle. Counter state lives at `${CLAUDE_PLUGIN_DATA:-$HOME/.zensu/state}/rounds-<session_id>.json` (atomic `mktemp` + `mv` write, per-session isolation, ISO-UTC timestamp). The hook increments the counter BEFORE the convergence check so the recorded round reflects the just-completed cycle. When the count exceeds the configured maximum the hook emits a convergence `additionalContext` instructing the main agent to NOT spawn `zensu:tdd-manager` again and to list remaining findings under `### Findings (max rounds reached, manual fix required)`. Reader `zensu_autofix_max_rounds` clamps invalid values (non-integer, out-of-range, malformed) to the default `2`. Backed by `evals/config-gate/test-autofix-rounds-increment.sh`, `evals/config-gate/test-autofix-rounds-convergence.sh`, and `evals/config-gate/test-autofix-rounds-session-isolation.sh`.
- `logging.timestampStyle` user-config flag in `~/.zensu/config.json` controlling inline timestamp prefixes in `zensu:tdd-manager` session logs (`.zensu/logs/`). Three values: `wall` (default, `[HH:MM:SS]` — backward compatible), `relative` (`[+HH:MM:SS]` under 24h, `[+Dd HH:MM:SS]` for longer sessions), `none` (no prefix). Filenames retain `YYYY-MM-DD-HHMM` for uniqueness — only inline prefixes are affected. Falls back to `wall` on missing file / missing `node` / malformed JSON / invalid value. New shared helper `hooks/lib/zensu-log.sh` (CLI wrapper) and `_zensu_log_style` function in `hooks/lib/zensu-config.sh` mirror the safe-fallback pattern from #6. Backed by 8 new offline tests in `evals/config-gate/test-log-style-*.sh` (wall, relative, none, fallback, no-node, bad-epoch with octal-parse regression, negative-delta clamp, long-delta two-tier format)
- PostToolUse hook on `ExitPlanMode` that auto-delegates approved plans to the `zensu:tdd-manager` subagent (with escape hatch for doc-only or trivial plans)
- E2E eval suite for the plan-approval hook in `evals/plan-approval-hook/` (expect-driven interactive test that approves a real plan and asserts hook firing)
- E2E eval suite for the review-chain in `evals/tdd-review-chain/` (asserts that `zensu:tdd-manager` completion auto-invokes `@zensu:code-reviewer` and that other subagents do not trigger the chain)
- Severity-routing hook `hooks/post-review-tdd-delegate.sh` (second `PostToolUse:Agent` command-type hook) that classifies `zensu:code-reviewer` findings by severity and routes ONLY **Critical + Important** findings to `zensu:tdd-manager` as a structured feature spec for proper RED/GREEN-cycle fixes. **Suggestions / Minor / Nits** are NOT auto-fixed: they are buffered in the main agent's response under "### Suggestions (not auto-fixed)" for the user to review. Convergence is preserved — when zero Critical/Important findings remain, the chain ends instead of re-spawning tdd-manager.
- Offline structural eval assertions T6/T7/T8 in `evals/tdd-review-chain/run-eval.sh --self-check` covering (T6) critical+important dispatch directive, (T7) suggestions-only no-dispatch behavior, (T8) clean-review no-dispatch behavior. Backed by the new dedicated assertion script `evals/tdd-review-chain/assert-severity-routing.sh`.

### Removed
- Removed the `SubagentStop:zensu:code-reviewer` prompt-type hook (the previous "present findings to user" prompt). Replaced by the severity-routing `PostToolUse:Agent` hook above, which decides between auto-fix-via-tdd-manager and present-suggestions-only based on finding severity.

### Changed
- SubagentStop hook for `zensu:tdd-manager` now auto-invokes `@zensu:code-reviewer` via a new `PostToolUse:Task` command-type hook (`hooks/post-tdd-review-delegate.sh`) that filters on `subagent_type == "zensu:tdd-manager"` and injects a verbatim directive as `additionalContext`. Replaces the user-owned `/reflect` command (not a plugin concern) and works around two architectural blockers verified empirically: subagents cannot spawn other subagents, and `SubagentStop` hooks (a) do not support `additionalContext` injection and (b) route their output to the stopping subagent (which has no `Task` tool) rather than the main agent. PostToolUse on the `Task` tool fires after subagent completion and routes to the main agent, which DOES have `Task` and can spawn the reviewer.
- tdd-manager Phase 6 step 7 no longer asks the user about code review — that decision is centralized in the SubagentStop hook
- Plugin manifest no longer declares `"hooks": "./hooks/hooks.json"` — that path is auto-loaded by Claude Code, and an explicit declaration causes a `Duplicate hooks file detected` load error that disables all plugin hooks. (Reverts the defensive declaration added earlier in the 0.3.x series; the original assumption that the Desktop App needed it was wrong, and the side effect broke hook loading entirely.)
- Plan-approval hook prompt sharpened: delegation is now mandatory for all code-related plans; override requires an EXPLICIT TDD negation phrase (e.g. "no tdd", "kein tdd-manager"); generic urgency phrases like "gleich arbeiten" or "go ahead" no longer count; Auto Mode is explicitly NOT an override
- Plan-approval hook prompt further hardened: explicit prohibition on calling Read/Edit/Write/Bash/MultiEdit before the Agent tool; required acknowledgement line ("Delegating to zensu:tdd-manager" or "Skipping TDD: ..."); explicit instruction to set `subagent_type='zensu:tdd-manager'`
- Plugin manifest now declares `"hooks": "./hooks/hooks.json"` explicitly to ensure loading across all Claude Code surfaces (auto-discovery via convention worked for the CLI but the Desktop App may use a stricter loader)
- Plan-approval hook switched from `type: "prompt"` to `type: "command"` (new script `hooks/plan-approved-delegate.sh`). The prompt-type hook routed the directive through a judge LLM that summarized the instruction before it reached the main agent, which let Claude ignore the delegation requirement. The command-type hook injects the directive verbatim as `additionalContext` next to the tool result, removing the judge layer.
- Data & Privacy disclosure in README
- SECURITY.md with responsible disclosure policy and safe harbor
- CONTRIBUTING.md with contributor guidelines
- CODE_OF_CONDUCT.md (Contributor Covenant 2.1)
- GitHub issue and PR templates
- Troubleshooting section in README
- Platform compatibility documentation
- Default agent override documentation
- Prerequisites and MCP Tools Used table to Pulse skill

### Changed
- Expanded .gitignore to prevent credential and artifact leaks
- Reformatted CHANGELOG to Keep a Changelog specification
- Improved PostToolUse hook with graceful failure handling
- Downgraded version to 0.1.0 (pre-stable API)
- Standardized terminology in agent decision rules

### Fixed
- SessionStart hook detached HEAD handling
- Pinned MCP server URL to v1 endpoint for forward compatibility

## [0.1.0] - 2026-03-01

### Added
- Plugin manifest (`plugin.json`) with full metadata
- MCP server auto-configuration (`.mcp.json`)
- Agent: `zensu-plm` — Product Lifecycle Manager with domain knowledge
- Skill: `/zensu:bootstrap` — Bootstrap products from vision documents
- Skill: `/zensu:security-review` — Comprehensive security review workflow
- Skill: `/zensu:implement` — Feature implementation with artifact linking
- Skill: `/zensu:ghost-scan` — Repository scanning for undocumented features
- Skill: `/zensu:pulse` — Privacy-first developer session journal
- Hook: Post-commit `[ZEN-xxx]` feature reference detection
- Hook: Session-start pulse context preparation
- Default agent configuration (`settings.json`)

[unreleased]: https://github.com/MKITConsulting/zensu-claude-code/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/MKITConsulting/zensu-claude-code/releases/tag/v0.1.0
