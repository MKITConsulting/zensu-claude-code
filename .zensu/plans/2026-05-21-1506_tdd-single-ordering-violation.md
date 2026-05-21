# TDD Plan: Single ordering violation per step + symmetric comparison

## Context
Two deferred code-review suggestions both target `evals/tdd-review-chain/assert-tdd-log-compliance.sh`:

1. `assert-tdd-log-compliance.sh:177-188` — The three ordering checks (RED-after-GREEN, IMPL-before-RED, IMPL-after-GREEN) currently emit one stderr line each, so a single mis-ordered trio yields three VIOLATION lines. Downstream consumers that count violations by line over-count. Fix: collect tripped sub-rules into a list, emit **one** line of the form `VIOLATION: ordering violation in step {step_id} ({rules})`.
2. `assert-tdd-log-compliance.sh:185-187` — The IMPL-after-GREEN comparison uses `-ge` while IMPL-before-RED uses strict `-lt`. Asymmetric. Fix: use strict `<` consistently for all three sub-rules (RED < IMPL < GREEN).

Additional ask: new fixture-driven test T5.8 in `run-eval.sh` that re-runs `tdd-log-ordering.log` and asserts the stderr contains **exactly one** `ordering violation in step` line. Do not regress T5.1–T5.7. T5.5 may need the log-content assertion loosened to look for `ordering violation in step` instead of the old per-sub-rule names.

Verify via `./evals/tdd-review-chain/run-eval.sh --self-check`. Expect 28/29 PASS (29 = prior 28 + new T5.8; the 1 pre-existing FAIL on `assert-version.sh` remains).

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash + shell-script evals | **Coverage**: SKIPPED (no shell-coverage tool installed)

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1   | Feature | T5.8: assert exactly one `ordering violation in step` stderr line for the ordering fixture | `evals/tdd-review-chain/run-eval.sh` | —      | [G]    | 1 |
| S2   | Feature | Collapse three independent ordering VIOLATION prints into one composite message per step; use strict `-lt` consistently across all three sub-rules | `evals/tdd-review-chain/assert-tdd-log-compliance.sh` | S1 | [G]    | 1 |

### Step S1 — RED: add T5.8 fixture-driven test asserting single ordering violation line
- [x] **RED**: Added T5.8 block to `run-eval.sh`. Confirmed FAIL: count=3 (expected 1) before S2 lands.
- [x] **GREEN**: After S2 IMPL, T5.8 reports count=1 → PASS.

**Note on cycle interleaving**: S1 introduces the RED test that S2 must satisfy. S2 is the IMPL phase. Combined "GREEN" verification = `run-eval.sh --self-check` after S2 — at which point S1's check turns PASS *and* T5.5 still rejects with non-zero exit. This is a classic two-step TDD pair where Step 1 is the failing test and Step 2 is the production-code change.

### Step S2 — IMPL: single ordering violation per step + symmetric strict comparison
- [x] **IMPL**:
  - Replaced lines 173-189 of `assert-tdd-log-compliance.sh` with logic that collects which sub-rules tripped into a local `tripped` string, then emits **one** stderr line of form `VIOLATION: ordering violation in step {step_id} ({rules})`.
  - All three sub-rules use strict `-lt` consistently expressing "lines must strictly increase":
    - RED-after-GREEN: `green_line -lt red_line` (must be RED < GREEN).
    - IMPL-before-RED: `impl_line -lt red_line` (must be RED < IMPL).
    - IMPL-after-GREEN: `green_line -lt impl_line` (must be IMPL < GREEN).
  - `VIOLATIONS` increments once per step regardless of how many sub-rules tripped.
  - Still exits non-zero when any rule tripped.
- [x] **GREEN**:
  - T5.5 (existing) — ordering-fixture rejected with non-zero exit — PASS confirmed.
  - T5.8 (new) — `grep -c 'ordering violation in step' == 1` — PASS confirmed.
  - Full self-check: 28/29 PASS (1 pre-existing FAIL on `assert-version.sh`).

**Checkpoint**: `./evals/tdd-review-chain/run-eval.sh --self-check` → 28/29 PASS DONE

## Final Verification
- [x] All shell test cases pass via `run-eval.sh --self-check` — 28/29 PASS. The 1 FAIL is the pre-existing `assert-version.sh` issue (unrelated).
- [x] T5.5 still rejects the ordering fixture with non-zero exit (rejection semantics preserved).
- [x] T5.8 passes — exactly one `ordering violation in step` stderr line per mis-ordered trio (count=1 confirmed).
- [x] Coverage: SKIPPED (no shell-script coverage tool installed in repo).
- [ ] Commit message: `fix(tdd-review-chain): single ordering violation per step + symmetric comparison`. No co-author/watermark. Stage `.zensu/plans/` and `.zensu/logs/`. Do NOT push.
