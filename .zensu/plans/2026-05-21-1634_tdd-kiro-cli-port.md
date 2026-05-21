# TDD Plan: Port Zensu Plugin from Claude Code to Kiro CLI

## Context

Port the Zensu plugin (`zensu-claude-code`, v0.3.14) to a second distribution targeting Kiro CLI (AWS, https://kiro.dev). Produce a new repo at `/Users/marcelkarras/IdeaProjects/dev.zensu/kiro-zensu/` containing: 3 Kiro-style JSON agents (zensu-plm, tdd-manager, code-reviewer) with markdown prompt bodies copied verbatim from source, 5 skills with added YAML frontmatter, MCP HTTP config, ported hook scripts (env-var-free, STDIN-JSON-aware), E2E test harness with engine-adapter pattern (`ENGINE=kiro|claude`), promptfoo exec-wrapper for tdd-manager evals, and an install script.

Authoritative design: `/Users/marcelkarras/.claude/plans/evaluiere-wie-wir-unser-structured-pretzel.md` (web-verified Kiro facts: binary `kiro-cli`, `KIRO_HOME` env var, `--no-interactive`, `--trust-all-tools`, built-in tool names, hook event names, MCP HTTP schema).

Acceptance criteria: all 5 `tests/e2e/` fixtures PASS under `ENGINE=kiro` with identical patterns; all `evals/config-gate/test-*.sh` PASS against ported hook scripts; `kiro-cli` calls connect to MCP; agentSpawn hook logs "zensu: pulse session ready"; promptfoo eval passes.

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash + node + jq (port artifacts); shell-test scripts as test runner | **Coverage**: SKIPPED — bash port, no coverage tool applicable | **kiro-cli**: NOT installed locally → engine-gated runtime tests are `[W]` (verified by script existence + dry-run, not live execution)

## Constraints

- Do NOT modify `/Users/marcelkarras/IdeaProjects/dev.zensu/zensu-claude-code/`
- Prompt bodies in `.kiro/prompts/` are byte-identical to source (everything after YAML frontmatter)
- Skill bodies in `.kiro/skills/<n>/SKILL.md` are byte-identical to source except added frontmatter
- Test fixtures + expected patterns in `tests/e2e/` are byte-identical to source
- No Claude Code branding in README — link back to source repo
- License: MIT (copy LICENSE)
- Conventional commits, no Claude watermarks (per user CLAUDE.md)

## Status Legend
| `[ ]` Not started | `[R]` RED test | `[I]` Implemented | `[G]` GREEN | `[RF]` Refactored | `[!]` Blocked | `[W]` Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| P0.1 | W | Pre-flight: create kiro-zensu repo skeleton + LICENSE + .gitignore | tests/structure/test-repo-skeleton.sh | — | [W] | 1 |
| P0.2 | F | README.md exists, contains install instructions, links to source repo, no Claude branding | tests/structure/test-readme.sh | P0.1 | [G] | 1 |
| P1.1 | F | zensu-plm.json — valid JSON, name=zensu-plm, prompt=file://./prompts/zensu-plm.md, tools array, includeMcpJson=true, model=claude-sonnet-4, hooks.agentSpawn present | tests/structure/test-agent-zensu-plm-json.sh | P0.1 | [G] | 1 |
| P1.2 | F | tdd-manager.json — valid JSON shape, correct tools, hooks present | tests/structure/test-agent-tdd-manager-json.sh | P0.1 | [G] | 1 |
| P1.3 | F | code-reviewer.json — valid JSON shape, correct tools, hooks present | tests/structure/test-agent-code-reviewer-json.sh | P0.1 | [G] | 1 |
| P1.4 | F | All 3 prompt bodies in .kiro/prompts/ are byte-identical to source agent bodies (modulo YAML frontmatter) | tests/structure/test-prompts-byte-identical.sh | P1.1, P1.2, P1.3 | [G] | 1 |
| P2.1 | F | bootstrap SKILL.md has YAML frontmatter (name+description), body byte-identical to source | tests/structure/test-skill-bootstrap.sh | P0.1 | [G] | 1 |
| P2.2 | F | All 5 skills have YAML frontmatter and byte-identical bodies (bootstrap, ghost-scan, implement, pulse, security-review) | tests/structure/test-skills-all.sh | P2.1 | [G] | 1 |
| P3.1 | F | mcp.json — valid JSON, mcpServers.zensu.type=http, url contains "/v1/mcp", env-var fallback present | tests/structure/test-mcp-json.sh | P0.1 | [G] | 1 |
| P4.1 | F | hooks/lib/zensu-config.sh — copied unmodified from source, sources cleanly under set -u | tests/hooks/test-config-helper-copied.sh | P0.1 | [G] | 1 |
| P4.2 | F | hooks/lib/zensu-log.sh — copied unmodified from source, sources cleanly | tests/hooks/test-log-helper-copied.sh | P0.1 | [G] | 1 |
| P4.3 | F | session-start-pulse.sh — does NOT depend on CLAUDE_PLUGIN_ROOT; uses SCRIPT_DIR trick; emits "zensu: pulse session ready" banner with HEAD+branch when in git repo | tests/hooks/test-session-start-pulse.sh | P4.1 | [G] | 1 |
| P4.4 | F | post-tdd-review-delegate.sh — reads STDIN JSON, filters subagent_type=zensu:tdd-manager, emits additionalContext referencing zensu:code-reviewer; works without CLAUDE_PLUGIN_ROOT | tests/hooks/test-post-tdd-review.sh | P4.1 | [G] | 1 |
| P4.5 | F | post-review-tdd-delegate.sh — reads STDIN JSON, filters subagent_type=zensu:code-reviewer, emits additionalContext referencing zensu:tdd-manager; loop guard works; works without CLAUDE_PLUGIN_ROOT | tests/hooks/test-post-review-tdd.sh | P4.1 | [G] | 1 |
| P4.6 | RF | plan-approved-delegate.sh DROPPED — file does NOT exist in port (Kiro has no ExitPlanMode equivalent per risk #1). Reclassified [F]→[RF] (characterization test of intentional absence) | tests/hooks/test-plan-approved-dropped.sh | P0.1 | [RF] | 1 |
| P5.1 | W | Wire agentSpawn hook in zensu-plm.json to absolute-path session-start-pulse.sh; verify JSON parses and references valid existing script | tests/structure/test-hook-wiring.sh | P1.1, P4.3 | [W] | 1 |
| P5.2 | W | Wire postToolUse hook (matcher=subagent) in zensu-plm.json to post-tdd-review-delegate.sh AND post-review-tdd-delegate.sh | tests/structure/test-hook-wiring.sh | P1.1, P4.4, P4.5 | [W] | 1 |
| P6.1 | F | Port tests/e2e/setup-fixtures.sh BYTE-IDENTICAL from source (this is conformance spec) | tests/structure/test-e2e-setup-fixtures-identical.sh | P0.1 | [G] | 1 |
| P6.2 | F | Port all 5 expected/*.pattern files BYTE-IDENTICAL from source | tests/structure/test-e2e-patterns-identical.sh | P0.1 | [G] | 1 |
| P6.3 | F | New tests/e2e/run.sh accepts ENGINE env var; under ENGINE=kiro invokes `KIRO_HOME=$PLUGIN_DIR kiro-cli chat --no-interactive --agent code-reviewer --trust-all-tools`; under ENGINE=claude preserves original behavior; gracefully skips if engine binary missing | tests/structure/test-e2e-run-adapter.sh | P0.1 | [G] | 1 |
| P7.1 | F | Port evals/config-gate/run-eval.sh AND core test-*.sh verbatim; PLUGIN_DIR resolves to kiro-zensu root; tests use CLAUDE_PLUGIN_ROOT compat var (source helper handles both) | tests/structure/test-config-gate-ported.sh | P4.1, P4.3, P4.4, P4.5 | [G] | 1 |
| P7.2 | RF | All 3 remaining ported hooks (plus pre-edit) pass the no-pluginroot-env test (works without CLAUDE_PLUGIN_ROOT). Reclassified [F]→[RF] (characterization of already-green behavior) | tests/hooks/test-no-pluginroot-env-port.sh | P4.3, P4.4, P4.5, P4.7 | [RF] | 1 |
| P8.1 | F | scripts/kiro-promptfoo-wrapper.sh — takes $1=prompt, $2=options-JSON; parses agent name + working_dir via jq; emits kiro-cli command line (verifiable via dry-run env var); executable | tests/structure/test-promptfoo-wrapper.sh | P0.1 | [G] | 1 |
| P8.2 | F | evals/tdd-manager/promptfooconfig.kiro.yaml — valid YAML, provider id is 'exec:' with relative path to wrapper, retains RED/GREEN icontains assertions | tests/structure/test-promptfoo-config.sh | P8.1 | [G] | 1 |
| P9.1 | W | scripts/install.sh — copies/symlinks .kiro/ into ~/.kiro/ (or user-specified KIRO_HOME); idempotent | tests/structure/test-install-script.sh | P0.1 | [W] | 1 |
| P4.7 | F | (added inline mid-execution) Port pre-edit-tdd-reminder.sh + zensu-tdd-phase.sh lib — source has 5th hook script not in spec's "4 hooks" count | tests/structure/test-pre-edit-hook-wiring.sh + test-pre-edit-log-phase-subcmd.sh | P4.1 | [G] | 1 |
| P5.3 | W | (added inline mid-execution) Wire preToolUse hook into tdd-manager.json AND zensu-plm.json (matcher=write\|fs_write); code-reviewer skipped (read-only) | tests/structure/test-pre-edit-hook-wiring.sh | P4.7, P1.1, P1.2 | [W] | 1 |

**Checkpoint A** (after P0-P5): all structure tests + hook tests PASS via `bash tests/run-all.sh`
**Checkpoint B** (after P6-P9): all tests PASS; PR-ready

## Final Verification

- [ ] All structure tests PASS (`tests/run-all.sh`)
- [ ] All hook tests PASS (jq + node + bash with mock STDIN-JSON)
- [ ] All ported config-gate tests PASS against ported hook scripts
- [ ] JSON files are all valid (`jq . < file.json` exits 0)
- [ ] Bash scripts pass `bash -n` syntax check
- [ ] kiro-cli runtime tests are gated to `[W]` (binary not installed locally)
- [ ] Coverage SKIPPED (bash port, no instrumentation)

## Risk Acknowledgements (from authoritative plan, restated)

1. `ExitPlanMode` hook has NO Kiro equivalent → `plan-approved-delegate.sh` DROPPED entirely (test P4.6 asserts absence)
2. Hooks are per-agent in Kiro → ported hooks live inside agent JSONs; tested via mock STDIN-JSON; live execution NOT verified (no kiro-cli)
3. MCP env-var substitution undocumented → port preserves `${ZENSU_MCP_URL:-https://mcp.zensu.dev}/v1/mcp` literal; spike-test deferred
4. Default model pinned to `claude-sonnet-4` in each agent JSON
5. kiro-cli NOT installed → E2E live runs are `[W]` (script existence + syntax verified; runtime cross-engine parity is post-spike work)
