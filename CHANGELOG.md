# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- PostToolUse hook on `ExitPlanMode` that auto-delegates approved plans to the `zensu:tdd-manager` subagent (with escape hatch for doc-only or trivial plans)
- E2E eval suite for the plan-approval hook in `evals/plan-approval-hook/` (expect-driven interactive test that approves a real plan and asserts hook firing)
- E2E eval suite for the review-chain in `evals/tdd-review-chain/` (asserts that `zensu:tdd-manager` completion auto-invokes `@zensu:code-reviewer` and that other subagents do not trigger the chain)

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
