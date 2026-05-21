# TDD Plan: Phase B — Project-local config + autoFix Suggestions + autoFix loop guard

## Context

Three coupled enhancements to the Zensu plugin:

1. **Config Resolution Order**: extend resolution to `$ZENSU_CONFIG` -> `$CLAUDE_PROJECT_DIR/.zensu/config.json` -> `$HOME/.zensu/config.json`. REPLACES, does not merge.
2. **`hooks.autoFixIncludeSuggestions: boolean`** (default false): when true, the auto-fix hook routes ALL severities (Critical+Important+Suggestion+Minor+Nit) to `zensu:tdd-manager`.
3. **`hooks.autoFixMaxRounds: number`** (default 2, valid 1..99): loop guard for the code-reviewer to tdd-manager cycle. Counter persisted at `${CLAUDE_PLUGIN_DATA:-$HOME/.zensu/state}/rounds-<session_id>.json`. Atomic write. On exceeded -> emit Convergence additionalContext, do NOT spawn.

Files modified: `hooks/lib/zensu-config.sh`, `hooks/post-review-tdd-delegate.sh`, `config.example.json`, `README.md`, `CHANGELOG.md`. New test files under `evals/config-gate/`.

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash hooks + node-eval JSON | **Test runner**: shell scripts (`bash evals/config-gate/test-*.sh`) | **Coverage**: SKIPPED (no coverage tooling for shell scripts)

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Add `_zensu_resolve_config` helper to zensu-config.sh; project-local + global fallback | evals/config-gate/test-resolution-order-{env-override,project-local,global-fallback}.sh | — | [G] | 1 |
| S2 | Refactor | Replace existing `${ZENSU_CONFIG:-$HOME/.zensu/config.json}` lines in `zensu_hook_enabled` and `_zensu_log_style` with `$(_zensu_resolve_config)` | existing tests (envoverride, missing, log-style-*) | S1 | [RF] | 1 |
| S3 | Feature | Add `zensu_autofix_include_suggestions` boolean reader (default false) | evals/config-gate/test-helper-autofix-flags.sh | S1 | [G] | 1 |
| S4 | Feature | Add `zensu_autofix_max_rounds` integer reader (default 2, valid 1..99, else default) | evals/config-gate/test-helper-autofix-flags.sh | S1 | [G] | 1 |
| S5 | Feature | Restructure `post-review-tdd-delegate.sh`: read flags + session_id + counter logic. INCLUDE_SUGGESTIONS=1 branch emits "ALL findings regardless of severity" directive | evals/config-gate/test-autofix-suggestions-on.sh | S3, S4 | [G] | 1 |
| S6 | Feature | INCLUDE_SUGGESTIONS=0 branch preserves existing directive verbatim | evals/config-gate/test-autofix-suggestions-off.sh | S5 | [G] | 1 |
| S7 | Feature | Counter increment + atomic write to `$CLAUDE_PLUGIN_DATA/rounds-<sid>.json` | evals/config-gate/test-autofix-rounds-increment.sh | S5 | [G] | 1 |
| S8 | Feature | Convergence when count > max: emit convergence text, no tdd-manager spawn | evals/config-gate/test-autofix-rounds-convergence.sh | S7 | [G] | 1 |
| S9 | Feature | Session isolation: separate counter file per session_id | evals/config-gate/test-autofix-rounds-session-isolation.sh | S7 | [G] | 1 |
| S10 | Wire | Add `autoFixIncludeSuggestions: false`, `autoFixMaxRounds: 2` to `config.example.json` | (JSON validity check + integration test via test-autofix-* fixtures) | S3, S4 | [W] | 1 |
| S11 | Wire | Add `autoFixIncludeSuggestions` and `autoFixMaxRounds` rows to README Hook Opt-Out table + new "Config Resolution Order" sub-section + `autoFix:true` prerequisite warning | evals/config-gate/test-readme-coverage.sh | S1, S3, S4 | [W] | 1 |
| S12 | Wire | Add CHANGELOG entry covering all three features | evals/config-gate/test-changelog-coverage.sh | S5..S9 | [W] | 1 |
| S13 | Wire | Update `evals/config-gate/run-eval.sh` to register the 11 new test files under three new sections | self-check exit code | S5..S9 | [W] | 1 |

**Checkpoints**: Run `bash evals/config-gate/run-eval.sh --self-check`; expect all green at end. ShellCheck on `hooks/lib/zensu-config.sh` and `hooks/post-review-tdd-delegate.sh` clean.

### Step S1 — `_zensu_resolve_config` helper
- [x] **RED**: Write `test-resolution-order-env-override.sh`, `test-resolution-order-project-local.sh`, `test-resolution-order-global-fallback.sh`. Each sources `zensu-config.sh`, calls `_zensu_resolve_config`, asserts returned path matches expected fixture. Tests FAIL because `_zensu_resolve_config` is unbound symbol.
- [x] **GREEN**: Add `_zensu_resolve_config()` to `hooks/lib/zensu-config.sh` implementing the 3-stage resolution.

### Step S2 — Wire `_zensu_resolve_config` into existing readers
- [x] **RF (GREEN-BEFORE)**: Existing tests already cover the env/missing/log-style paths -> baseline already green.
- [x] **CHANGE**: Replace both inline `local config="${ZENSU_CONFIG:-$HOME/.zensu/config.json}"` lines with `local config="$(_zensu_resolve_config)"`.
- [x] **GREEN-AFTER**: Re-run `test-helper-envoverride.sh`, `test-helper-missing.sh`, `test-log-style-*.sh`. All still pass.

### Step S3 — `zensu_autofix_include_suggestions`
- [x] **RED**: Add helper test `test-helper-autofix-flags.sh` asserting:
  - flag absent -> returns 1 (false / default off)
  - explicit true -> returns 0
  - explicit false -> returns 1
  - string "true" -> returns 1 (strict ===)
  Test FAILs because `zensu_autofix_include_suggestions` is unbound.
- [x] **GREEN**: Add the boolean reader to `zensu-config.sh`.

### Step S4 — `zensu_autofix_max_rounds`
- [x] **RED**: Extend `test-helper-autofix-flags.sh` (same file) with `zensu_autofix_max_rounds` cases:
  - flag absent -> echoes "2"
  - explicit 5 -> echoes "5"
  - explicit 99 -> echoes "99"
  - 0 -> echoes "2" (out of range)
  - 100 -> echoes "2" (out of range)
  - "five" -> echoes "2" (non-int)
  - 1.5 -> echoes "2" (non-int)
  Test FAILs because reader unbound.
- [x] **GREEN**: Add the int reader.

### Step S5 — INCLUDE_SUGGESTIONS=1 hook branch
- [x] **RED**: Write `test-autofix-suggestions-on.sh` — fixture with `autoFix:true, autoFixIncludeSuggestions:true`, pipe stdin-code-reviewer.json, grep stdout for "ALL findings regardless of severity" AND "Critical, Important, Suggestion, Minor, Nit". FAILs because hook still emits legacy text.
- [x] **GREEN**: Restructure hook with if/else branch. Include round counter logic too (needed for INCLUDE_SUGGESTIONS=1 branch's `round X/Y` status line).

### Step S6 — INCLUDE_SUGGESTIONS=0 backwards-compat branch
- [x] **RED**: Write `test-autofix-suggestions-off.sh` — fixture with `autoFix:true` only (flag absent), pipe stdin-code-reviewer.json, grep for existing "EXCLUDE all Suggestions" instruction AND "Delegating critical+important findings to zensu:tdd-manager". FAILs if S5 broke the legacy branch.
- [x] **GREEN**: Confirm legacy text preserved in else branch.

### Step S7 — counter increment + atomic write
- [x] **RED**: Write `test-autofix-rounds-increment.sh` — tmp CLAUDE_PLUGIN_DATA, invoke hook 3 times same session_id, parse JSON, assert count 1->2->3. FAILs because no counter file exists yet.
- [x] **GREEN**: Hook reads counter -> increments -> atomic mktemp+mv write before convergence check.

### Step S8 — convergence
- [x] **RED**: Write `test-autofix-rounds-convergence.sh` — pre-seed counter=2 in tmp data dir, fixture autoFixMaxRounds=2, invoke once -> assert output contains "Auto-fix convergence: max 2 rounds reached" AND does NOT contain "zensu:tdd-manager" instructions. FAILs because no convergence code.
- [x] **GREEN**: Add convergence branch.

### Step S9 — session isolation
- [x] **RED**: Write `test-autofix-rounds-session-isolation.sh` — invoke with session_id=A then session_id=B; assert two distinct counter files each with count=1. FAILs without session_id parsing.
- [x] **GREEN**: Session id parsed from stdin JSON; counter file name interpolates session_id.

### Step S10 — config.example.json
- [x] **W**: Add two keys. Verified by existing JSON-valid structural check + a tiny grep test.

### Step S11 — README
- [x] **W**: Append two new rows in the Hook Opt-Out table; add the Config Resolution Order subsection; add the `autoFix:true` prerequisite warning. Verified via grep test.

### Step S12 — CHANGELOG
- [x] **W**: Add Unreleased / Added entry for all three. Verified via grep test.

### Step S13 — wire new tests into run-eval.sh
- [x] **W**: Add new section "Phase B offline tests" registering the 8 new tests + the helper-autofix-flags test + coverage tests. Self-check exits 0.

## Final Verification
- [x] `bash evals/config-gate/run-eval.sh --self-check` all green (37/37 PASS, 0 FAIL — 26 existing + 11 new)
- [x] Each new test runnable standalone via `bash evals/config-gate/<file>` and reports PASS/FAIL line, exits non-zero on failure
- [x] `shellcheck hooks/lib/zensu-config.sh hooks/post-review-tdd-delegate.sh` clean (exit 0)
- [x] No regressions: existing 26 tests still pass
- [x] No mutation of real `~/.zensu/` during test runs (verified: `~/.zensu/state/` does not exist after run)
