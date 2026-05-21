# TDD Plan: Round-3 CHANGELOG suite-size accuracy fix

## Context

Reviewer finding (round 4 of post-review auto-fix loop):

`CHANGELOG.md:37` — Suite-size statement is wrong: `Suite size: config-gate grew from 57 to 61 PASS`. The file-level runner count is unchanged at 57/57; the +4 is at the **assert level** (intra-file). A maintainer auditing the runner output for "61" will not find it. Reviewer reproduced: `bash evals/config-gate/run-eval.sh --self-check` outputs `SELF-CHECK: 57/57 PASS (0 FAIL)`.

Fix: replace line 37 with `Suite size: config-gate stays at 57/57 file-level PASS; assert count grows by +4 (+2 in test-pre-edit-concurrent-write.sh internally, +2 in test-pre-edit-greenpass-tight.sh internally).` matching the round-2 convention.

Constraints:
- `evals/config-gate/test-changelog-coverage.sh` must still pass after the edit (it scans for substrings, all still present in the new wording).
- `bash evals/config-gate/run-eval.sh --self-check` → 57/57 PASS unchanged.
- Strict TDD: RED test asserts CHANGELOG does NOT contain `"57 to 61"` AND DOES contain the corrected wording.

**Approach**: Strict Red/Green TDD (Feature classification) | **Tech Stack**: bash + shell evals (no compile/build) | **Coverage**: SKIPPED (no coverage tool wired for shell tests in this project)

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1   | Feature | Add round-3 accuracy test + fix CHANGELOG.md:37 wording | `evals/config-gate/test-changelog-round3-accuracy.sh` (new) + `CHANGELOG.md` | — | [G] | 1 |
| S2   | Integration | Wire new test into `evals/config-gate/run-eval.sh` runner | `evals/config-gate/run-eval.sh` | S1 | [W] | 1 |

### Step S1 — Feature: RED test + IMPL CHANGELOG fix (single cycle)

- [x] **RED**: Added `evals/config-gate/test-changelog-round3-accuracy.sh` with two asserts. Initial run: 0/2 PASS (assertion mismatch — both fail for the right reason).
- [x] **IMPL**: Replaced wrong wording on `CHANGELOG.md:37` with the corrected wording.
- [x] **GREEN**: `bash evals/config-gate/test-changelog-round3-accuracy.sh` → 2/2 PASS; `bash evals/config-gate/test-changelog-coverage.sh` → 12/12 PASS unchanged.

### Step S2 — WIRE: add new test to runner

- [x] **WIRE**: Inserted `run_test "$EVAL_DIR/test-changelog-round3-accuracy.sh" "test-changelog-round3-accuracy.sh"` into `evals/config-gate/run-eval.sh` under the "Documentation coverage tests" section.

**Checkpoint**: `bash evals/config-gate/run-eval.sh --self-check` → 58/58 PASS (57 existing + 1 new file-level test). CONFIRMED.

## Final Verification
- [x] `bash evals/config-gate/run-eval.sh --self-check` → 58/58 PASS
- [x] `bash evals/config-gate/test-changelog-coverage.sh` → 12/12 PASS (existing substring-coverage holds)
- [x] `bash evals/config-gate/test-changelog-round3-accuracy.sh` → 2/2 PASS standalone
- [x] CHANGELOG.md line 37 contains the corrected wording, no `"57 to 61"` anywhere
- [x] mtime discipline: test file mtime (1779382877) ≤ CHANGELOG.md mtime (1779382902) — strict Red→Green honored
