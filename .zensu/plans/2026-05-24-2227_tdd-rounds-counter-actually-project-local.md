# TDD Plan: Rounds Counter Actually Project-Local (0.3.21)

## Context

`hooks/post-review-tdd-delegate.sh:52` reads `STATE_DIR="${CLAUDE_PLUGIN_DATA:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}"`. claude-code ALWAYS sets `CLAUDE_PLUGIN_DATA` for plugin hooks (resolves to `~/.claude/plugins/data/zensu-inline/`), so the 0.3.20 "project-local fallback" is unreachable in real claude-code execution. The auto-fix rounds counter therefore lives user-global, accumulates across tasks within one long claude session, and crosses the 5-round cap permanently after a few review chains — disabling auto-fix delegation for every subsequent task even on its first review pass.

Approach (Option A): invert the env-var precedence. Introduce `CLAUDE_PLUGIN_DATA_OVERRIDE` as the new opt-in power-user override. Default resolves to `${CLAUDE_PROJECT_DIR:-.}/.zensu/state`. claude-code's auto-set `CLAUDE_PLUGIN_DATA` is intentionally IGNORED by this hook (other hooks may still honor it).

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash + node + jq (offline tests) | **Coverage**: SKIPPED (no coverage tooling configured for bash scripts; per-test pass/fail is the contract)

## Preconditions

| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| bash | CLI | `command -v bash` | present | install (already present) |
| node | CLI | `command -v node` | present | install (already present) |
| jq | CLI | `command -v jq` | present | install (already present) |
| `hooks/post-review-tdd-delegate.sh` | fixture | `[ -f ]` | present | install (already present) |
| `evals/config-gate/test-rounds-default-location.sh` | fixture | `[ -f ]` | present | install (already present) |

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Extend `test-rounds-default-location.sh` with new env-var precedence cases, then flip hook line 52 to use `CLAUDE_PLUGIN_DATA_OVERRIDE` | `evals/config-gate/test-rounds-default-location.sh` | — | [G] | 1 |
| S2 | Refactoring | Rename `CLAUDE_PLUGIN_DATA` → `CLAUDE_PLUGIN_DATA_OVERRIDE` in the 4 existing rounds tests + 2 stdout-only suggestions tests + combined-summary test, so they exercise the override path | (above tests) | S1 | [RF] | 1 |
| S3 | Integration | Update grandfathered header comment in `post-review-tdd-delegate.sh:12` to reference the new env var | hook header | S1 | [W] | 1 |
| S4 | Integration | README Environment Variables row + Hooks row + `autoFixMaxRounds` row updated to reference `CLAUDE_PLUGIN_DATA_OVERRIDE` and clarify that claude-code's auto-set `CLAUDE_PLUGIN_DATA` is intentionally ignored | `README.md` | S1 | [W] | 1 |
| S5 | Integration | `docs/tdd-manager-workflow.md` section 7 Files Produced — update rounds-counter env-var name (lines 190+206) | `docs/tdd-manager-workflow.md` | S1 | [W] | 1 |
| S6 | Integration | CHANGELOG.md — add `## [0.3.21] - 2026-05-24` section under `[Unreleased]`, explicitly acknowledge 0.3.20 misshipped (fallback unreachable). Existing Unreleased witness-scenario entry stays where it is | `CHANGELOG.md` | S1 | [W] | 1 |
| S7 | Integration | `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` bumped 0.3.20 → 0.3.21 in the SAME commit per repo convention. README version badge also bumped | `.claude-plugin/*.json`, `README.md` | S6 | [W] | 1 |

### Step S1 — RED: extend test-rounds-default-location.sh

- [ ] **RED**: Extend `test-rounds-default-location.sh` with three new case blocks:
  - C6: `CLAUDE_PLUGIN_DATA` SET + `CLAUDE_PROJECT_DIR` set + `CLAUDE_PLUGIN_DATA_OVERRIDE` unset → counter file MUST write to `${CLAUDE_PROJECT_DIR}/.zensu/state/rounds-<sid>.json` (NOT to `CLAUDE_PLUGIN_DATA`). This is the bug-fix invariant: claude-code's auto-set `CLAUDE_PLUGIN_DATA` is ignored.
  - C7: `CLAUDE_PLUGIN_DATA_OVERRIDE` SET + `CLAUDE_PROJECT_DIR` set + `CLAUDE_PLUGIN_DATA` unset → counter file MUST write to `${CLAUDE_PLUGIN_DATA_OVERRIDE}/rounds-<sid>.json` (override wins over project-local default).
  - C8: BOTH `CLAUDE_PLUGIN_DATA` and `CLAUDE_PLUGIN_DATA_OVERRIDE` set + `CLAUDE_PROJECT_DIR` set → OVERRIDE wins over both project-local AND `CLAUDE_PLUGIN_DATA`.
  - Existing C1-C5 must still pass (the existing "explicit override still wins over project-local" case is rebased to assert against `CLAUDE_PLUGIN_DATA_OVERRIDE`, not `CLAUDE_PLUGIN_DATA`).
  - Run → expect FAIL on C6 and C7 and C8 (current code reads `CLAUDE_PLUGIN_DATA`, ignores the new env var).
- [ ] **IMPL**: 1-line edit `hooks/post-review-tdd-delegate.sh:52` — `CLAUDE_PLUGIN_DATA` → `CLAUDE_PLUGIN_DATA_OVERRIDE`.
- [ ] **GREEN**: new C6/C7/C8 PASS + all preexisting cases of `test-rounds-default-location.sh` PASS.

**Checkpoint**: `bash evals/config-gate/test-rounds-default-location.sh` exits 0, all asserts PASS.

### Step S2 — Refactoring: update existing rounds tests to use CLAUDE_PLUGIN_DATA_OVERRIDE

- [ ] **GREEN-BEFORE**: run the four existing rounds tests and the two suggestions tests + combined-summary test BEFORE refactor — verify which fail (the rounds tests will fail because their setup exports `CLAUDE_PLUGIN_DATA` but the hook now ignores it; the suggestions tests check stdout only, so they should still pass).
- [ ] **REFACTOR**: rename `export CLAUDE_PLUGIN_DATA=...` to `export CLAUDE_PLUGIN_DATA_OVERRIDE=...` in:
  - `evals/config-gate/test-autofix-rounds-convergence.sh`
  - `evals/config-gate/test-autofix-rounds-increment.sh`
  - `evals/config-gate/test-autofix-rounds-sanitize.sh`
  - `evals/config-gate/test-autofix-rounds-session-isolation.sh`
  - `evals/config-gate/test-post-review-combined-summary.sh`
  - `evals/config-gate/test-autofix-suggestions-on.sh` + `test-autofix-suggestions-off.sh` (these only assert stdout — but the hook will write into `~/.claude/.../state/` if neither env is set; safer to rename for hygiene)
  - Inside-file references (label strings in `check ".." PASS`, find paths, file-path concatenation) — update all literal occurrences accordingly.
- [ ] **GREEN-AFTER**: all six (well, seven) test files PASS again.

**Checkpoint**: every `evals/config-gate/test-autofix-rounds-*.sh` plus `test-post-review-combined-summary.sh` + `test-autofix-suggestions-*.sh` exits 0.

### Step S3 — Wire: update grandfathered hook header comment

- [ ] Update `hooks/post-review-tdd-delegate.sh:12` from `# Counter state lives at ${CLAUDE_PLUGIN_DATA:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}/rounds-<session_id>.json.` to reference `CLAUDE_PLUGIN_DATA_OVERRIDE`.

### Step S4 — Wire: README updates

- [ ] Replace the `CLAUDE_PLUGIN_DATA` row in the Environment Variables table with a `CLAUDE_PLUGIN_DATA_OVERRIDE` row + an explicit sentence noting claude-code's auto-set `CLAUDE_PLUGIN_DATA` is intentionally IGNORED by the rounds counter (other hooks may still honor it). Update both occurrences of `${CLAUDE_PLUGIN_DATA:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}` (Hooks row + `autoFixMaxRounds` row) to read `${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}`.
- [ ] Bump version badge: `version-0.3.20-green` → `version-0.3.21-green`.

### Step S5 — Wire: docs/tdd-manager-workflow.md section 7

- [ ] Update lines 190+206 to reference `CLAUDE_PLUGIN_DATA_OVERRIDE` and note the 0.3.21 default-actually-works behavior.

### Step S6 — Wire: CHANGELOG

- [ ] Insert a new `## [0.3.21] - 2026-05-24` section under `## [Unreleased]` (so the Unreleased witness-scenario entry stays). Explicitly acknowledge 0.3.20 misshipped (fallback unreachable because claude-code always sets `CLAUDE_PLUGIN_DATA`).

### Step S7 — Wire: version bump

- [ ] Bump `.claude-plugin/plugin.json` `version` from `0.3.20` to `0.3.21`.
- [ ] Bump `.claude-plugin/marketplace.json` `plugins[0].version` from `0.3.20` to `0.3.21`. (BOTH files in the SAME commit per `CLAUDE.md` Version Bumps section.)

## Final Verification

- [ ] `evals/config-gate/test-rounds-default-location.sh` PASS (extended).
- [ ] `evals/config-gate/test-autofix-rounds-{convergence,increment,sanitize,session-isolation}.sh` PASS (env-var rename applied).
- [ ] `evals/config-gate/test-autofix-suggestions-{on,off}.sh` PASS.
- [ ] `evals/config-gate/test-post-review-combined-summary.sh` PASS.
- [ ] `tests/structure/test-*.sh` PASS (no regression — none of them reference `CLAUDE_PLUGIN_DATA`).
- [ ] Manual smoke: claude-code-style invocation with `CLAUDE_PLUGIN_DATA` set + `CLAUDE_PROJECT_DIR` set writes counter to project-local, NOT to `CLAUDE_PLUGIN_DATA`.
- [ ] Manual smoke: `CLAUDE_PLUGIN_DATA_OVERRIDE` set wins over project-local.
- [ ] README + workflow doc + CHANGELOG updated; plugin.json + marketplace.json bumped to 0.3.21 (same commit).
