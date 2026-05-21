# TDD Plan: Tighten tdd-review-chain compliance script (ordering, grammar, test-resolution)

## Context
Fix three findings in `evals/tdd-review-chain/assert-tdd-log-compliance.sh`:

1. **Ordering not enforced** (L127-139): existence-only checks let GREEN precede RED. Fix: compute per-step LINE NUMBERS for RED/IMPL/GREEN, assert `red_line < impl_line < green_line`. Reject with named violations.
2. **Lowercase step-ids silently pass** (L78,118,124): uppercase-only `STEP_ID_RE` lets logs with `tdd COMPLETE` marker and lowercase steps yield empty step list → exit 0. Fix: if log contains `TDD COMPLETE`/`EXECUTION STARTED`/etc. but zero entries match the uppercase grammar → reject with "no step entries detected".
3. **Test-file heuristic collides with impl file** (L181-201): wildcard fallback can resolve "test" to the IMPL file → mtime self-compare → false-pass. Fix: after resolving, check whether test path appears in the step's IMPL list; if yes, WARN on stderr and skip mtime check.

Add fixture-driven tests T5.5, T5.6, T5.7 in `evals/tdd-review-chain/run-eval.sh`.

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash + shell-eval | **Coverage**: SKIPPED (no coverage tool; bash project)

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | T5.5 fixture + ordering enforcement | run-eval.sh + assert-tdd-log-compliance.sh | — | [G] | 1 |
| S2 | Feature | T5.6 fixture + grammar/empty-step-list rejection | run-eval.sh + assert-tdd-log-compliance.sh | S1 | [G] | 1 |
| S3 | Feature | T5.7 fixture + test-file/IMPL collision WARN | run-eval.sh + assert-tdd-log-compliance.sh | S2 | [G] | 1 |
| S4 | Refactor | Final self-check + audit pre-existing assertions still PASS/FAIL | run-eval.sh --self-check | S3 | [G] | 1 |

### Step S1 — Ordering enforcement (RED < IMPL < GREEN line numbers)
- [x] **RED**: Added fixture `fixtures/tdd-log-ordering.log` with `BE-1 GREEN` before `BE-1 RED`. Added T5.5 check in run-eval.sh asserting compliance script REJECTS this fixture. Initial run: T5.5 FAIL because the script returned exit 0 on this fixture (existence-only check).
- [x] **GREEN**: Added `step_marker_line` awk helper and ordering guard block in `assert-tdd-log-compliance.sh` that computes per-step line numbers for RED/IMPL/GREEN and rejects when `red_line >= green_line`, `impl_line < red_line`, or `impl_line >= green_line` (named violation messages: RED-after-GREEN, IMPL-before-RED, IMPL-after-GREEN). T5.5 PASS.

**Checkpoint**: T5.5 PASS, T5.1-T5.4 still PASS.

### Step S2 — Grammar enforcement (reject TDD-marker logs with no detected steps)
- [x] **RED**: Added fixture `fixtures/tdd-log-grammar.log` containing `TDD COMPLETE` + `EXECUTION STARTED` markers plus lowercase step entries (`be-1 RED ...` etc.). Added T5.6 check asserting script REJECTS this fixture with message "no step entries detected". Initial run: T5.6 FAIL (script exit 0, empty stderr — silent pass).
- [x] **GREEN**: Added grammar guard block: if log contains `TDD STARTED`/`EXECUTION STARTED`/`TDD COMPLETE`/`CHECKPOINT` markers AND all of RED_STEPS/IMPL_STEPS/GREEN_STEPS are empty → emit `VIOLATION: no step entries detected — log may use wrong prefix grammar (expected uppercase step-ids like BE-1, S1)` and exit 1. T5.6 PASS.

**Checkpoint**: T5.6 PASS, all earlier checks still PASS.

### Step S3 — Test-file/IMPL collision WARN
- [x] **RED**: Added fixture `fixtures/tdd-log-test-collision.log` with `BE-1 RED Foo` + `BE-1 IMPL completed — files: Foo.java`. The hardcoded extension list `Foo.java` resolves to the IMPL file itself, neutralizing mtime audit. Added T5.7 check: invoke compliance script with `--impl-dir`, assert stderr contains "cannot resolve test file" AND exit code = 0. Initial run: T5.7 FAIL (script exit 0 but stderr empty).
- [x] **GREEN**: Added collision guard in mtime block: after resolving `test_path`, iterate IMPL files and compare basenames; if any match the resolved test_path basename, emit `WARN: cannot resolve test file for step {step_id} — heuristic collided with impl file {path}; mtime audit skipped for this step` to stderr and `continue` (no exit-code change). T5.7 PASS.

**Checkpoint**: T5.7 PASS, all earlier checks still PASS.

### Step S4 — Final audit
- [x] **GREEN**: `./evals/tdd-review-chain/run-eval.sh --self-check` → 27/28 PASS. Pre-existing `assert-version.sh` FAIL preserved (plugin.json version mismatch — unrelated to this PR). T5.1-T5.7 all PASS. All other structural checks PASS.

## Final Verification
- [x] `./evals/tdd-review-chain/run-eval.sh --self-check` — T5.1-T5.7 all PASS
- [x] `assert-version.sh` pre-existing FAIL remains (do not touch)
- [x] All other structural checks remain at their prior status
