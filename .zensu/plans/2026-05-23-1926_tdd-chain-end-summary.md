# TDD Plan: Chain-End Combined Summary Directive

## Context

When the user delegates to `zensu:tdd-manager`, the auto-review chain runs
(tdd-manager -> code-reviewer -> optional auto-fix loop). At chain-end branches
(PASS, suggestions-only, max-rounds convergence), the main agent currently
renders only the LAST tool result (code-reviewer findings) so the user loses
visibility on what tdd-manager actually built.

**Goal**: at every chain-end branch, `hooks/post-review-tdd-delegate.sh`
injects an `additionalContext` directive instructing the main agent to render
a three-section summary block (Implementation Summary, Review Summary,
Auto-fix History).

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash + node + posix shell tests | **Coverage**: SKIPPED (bash, no coverage tool wired)

## Preconditions

| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| node | CLI | `command -v node` | present | install (already on PATH) |
| bash | CLI | `command -v bash` | present | install (already on PATH) |
| jq | CLI | `command -v jq` | present | install (already on PATH) |

All preconditions present. No blocking dependencies.

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Config helper `zensu_combined_summary_enabled` | `evals/config-gate/test-helper-autofix-flags.sh` | — | [G] | 1 |
| S2 | Feature | Inject directive in 3 chain-end branches | `evals/config-gate/test-post-review-combined-summary.sh` | S1 | [G] | 1 |
| S3 | Integration | Extend rounds-convergence test + docs + CHANGELOG | `evals/config-gate/test-autofix-rounds-convergence.sh` | S2 | [W] | — |

### Step S1 — Config helper `zensu_combined_summary_enabled`

- [ ] **RED**: Extend `evals/config-gate/test-helper-autofix-flags.sh` with 6 cases for `zensu_combined_summary_enabled`:
  - no config file present -> enabled (return 0)
  - empty `{}` config -> enabled
  - `{"hooks":{"combinedSummary":true}}` -> enabled
  - `{"hooks":{"combinedSummary":false}}` -> disabled (non-zero)
  - `{"hooks":{"combinedSummary":"yes"}}` (non-bool) -> enabled (only literal `false` disables)
  - node missing on PATH -> enabled (fail-open)
  Run test, expect FAIL (helper not yet defined).
- [ ] **IMPL**: add `zensu_combined_summary_enabled` to `hooks/lib/zensu-config.sh`. Mirror `zensu_autofix_include_suggestions` shape but invert default: return 0 (enabled) unless `combinedSummary === false`.
- [ ] **GREEN**: target test passes.

**Checkpoint**: `bash evals/config-gate/test-helper-autofix-flags.sh` pass

### Step S2 — Inject directive in 3 chain-end branches

- [ ] **RED**: NEW `evals/config-gate/test-post-review-combined-summary.sh` with 6 cases:
  1. case A/B (legacy MSG) + flag on (default) -> output contains "CHAIN-END SUMMARY" + 3 section headings
  2. case A/B + flag off -> output does NOT contain "CHAIN-END SUMMARY"
  3. case B (suggestions-on MSG) + flag on (default) -> output contains "ALL findings regardless of severity" AND "CHAIN-END SUMMARY"
  4. case B (suggestions-on MSG) + flag off -> output does NOT contain "CHAIN-END SUMMARY"
  5. max-rounds + flag on -> "Auto-fix convergence" + "CHAIN-END SUMMARY"
  6. max-rounds + flag off -> only "Auto-fix convergence" (no SUMMARY)
  Run test, expect FAIL (directive not yet present).
- [ ] **IMPL**:
  (a) Capture flag once before line 88: `COMBINED_SUMMARY_DIRECTIVE=...`
  (b) Max-rounds branch (line 89): append directive to `CONV_MSG`.
  (c) Both MSG construction branches (lines 104+106): append directive to MSG (before `EXPANDED_MSG` substitution).
- [ ] **GREEN**: 6/6 pass.

**Checkpoint**: `bash evals/config-gate/test-post-review-combined-summary.sh` pass

### Step S3 — Integration: existing tests + docs + CHANGELOG

- [ ] **Extend** `test-autofix-rounds-convergence.sh`: add 1 case asserting CHAIN-END SUMMARY present in max-rounds output when flag enabled (default).
- [ ] **README.md**: Hook descriptions table update (post-review row) + Behavior flags table new row for `combinedSummary`.
- [ ] **docs/tdd-manager-workflow.md** section 9: append paragraph on combined-summary behavior + flag.
- [ ] **CHANGELOG.md** Unreleased -> Added entry.

**Checkpoint**: All config-gate + structure tests pass.

## Final Verification

- [x] `bash evals/config-gate/test-helper-autofix-flags.sh` — 22 PASS / 0 FAIL
- [x] `bash evals/config-gate/test-post-review-combined-summary.sh` — 14 PASS / 0 FAIL
- [x] `bash evals/config-gate/test-autofix-rounds-convergence.sh` — 7 PASS / 0 FAIL
- [x] All config-gate regression suite — PASS (all 54 files green)
- [x] All structure tests still PASS — 87 PASS / 0 FAIL across 8 files
- [x] Manual smoke: `grep -c 'CHAIN-END SUMMARY'` returns 1 with flag on, 0 with flag off
- [x] Coverage: SKIPPED (bash, no coverage tool)
- [x] Build: n/a (bash plugin, no build step wired)
- [x] mtime audit: S1 + S2 — TEST FIRST verified
- [x] Precondition drift audit: clean (node + bash + jq all used as planned)
