# TDD Plan: Tighten T5.8 Content Assertions, Joiner Spacing, Strip Narrative Comments

## Context

User requested "fixe alles bis keine suggestions mehr" — fix three code-review Suggestion-level findings on the tdd-review-chain eval harness:

1. **`evals/tdd-review-chain/run-eval.sh:191-198` — T5.8 only asserts line count (`== 1`), not content of the composite message.** A regression that emits one line but drops the sub-rule list (e.g., `VIOLATION: ordering violation in step BE-1 ().`) would still pass. Tighten T5.8 to additionally assert: parens-payload is non-empty AND contains all three sub-rule tokens (`RED-after-GREEN`, `IMPL-before-RED`, `IMPL-after-GREEN`).

2. **`evals/tdd-review-chain/assert-tdd-log-compliance.sh:188` — Composite message uses comma-separated sub-rule names without spaces.** Readability cost on stderr. Change joining separator from `,` to `, ` (comma + space). Existing greppability is preserved (T5.8 uses `grep -F` literal tokens for the sub-rule names themselves).

3. **User global CLAUDE.md rule "NEVER EVER ADD COMMENTS!" violated.** The T5.x blocks (and T6/T7/T8) contain multi-line descriptive narrative comments. Strip ALL descriptive prose comments from T5.1 through T5.8 (and T6/T7/T8 for consistency). Keep one-line section banners (`# ─── T... ───`) and `echo "▸ ..."` REPORT lines — those are output markers, not code comments.

**Approach**: Strict Red/Green TDD. The eval harness IS the test suite (`run-eval.sh --self-check`). Fixtures pinned. Baseline: 28/29 PASS (1 FAIL is pre-existing `assert-version.sh`).

**Tech Stack**: Bash 5.x, POSIX shell scripting | grep, awk, sed
**Test Command**: `./evals/tdd-review-chain/run-eval.sh --self-check`
**Single-script test**: `./evals/tdd-review-chain/assert-tdd-log-compliance.sh --log <fixture>`
**Coverage**: SKIPPED (pure shell, no coverage tool installed)

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1   | Feature | Tighten T5.8 — assert sub-rule content tokens (RED-after-GREEN, IMPL-before-RED, IMPL-after-GREEN) | `evals/tdd-review-chain/run-eval.sh` | — | [ ] | 0 |
| S2   | Feature | Change joiner from `,` to `, ` in composite ordering-violation message | `evals/tdd-review-chain/assert-tdd-log-compliance.sh` | S1 | [ ] | 0 |
| S3   | Refactoring | Strip narrative comments from T5.1–T5.8 and T6/T7/T8 blocks in run-eval.sh | `evals/tdd-review-chain/run-eval.sh` | S2 | [ ] | 0 |

### Step S1 — Tighten T5.8 content assertions
- [ ] **RED**: Add new sub-check T5.8b (non-empty parens via `grep -E 'ordering violation in step BE-1 \([A-Za-z,-]+\)'`) — fails because we have not yet rewritten T5.8 (or because tools missing). Actually since the test harness assertion does not yet exist in run-eval.sh, the first run will lack that check entirely. The test is: split T5.8 into T5.8a + T5.8b + T5.8c. After the IMPL all three must PASS.
- [ ] **IMPL**: Replace the T5.8 block in `run-eval.sh` lines 191-205 with three sub-checks:
  - T5.8a: line-count `== 1` (existing)
  - T5.8b: parens non-empty via `grep -E 'ordering violation in step BE-1 \([A-Za-z,-]+\)'`
  - T5.8c: all three sub-rule tokens via three `grep -F` checks (`RED-after-GREEN`, `IMPL-before-RED`, `IMPL-after-GREEN`)
- [ ] **GREEN**: Run `./evals/tdd-review-chain/run-eval.sh --self-check`. The three new sub-checks must PASS (after S2 fixes the joiner spacing, but in step S1 we keep the current `,` separator working — the tokens themselves are still substrings).

### Step S2 — Joiner spacing
- [ ] **RED**: Add a one-shot assertion (inline) that runs the script against the ordering fixture and greps stderr for `RED-after-GREEN, IMPL-before-RED, IMPL-after-GREEN` (with spaces). Currently the script emits `RED-after-GREEN,IMPL-before-RED,IMPL-after-GREEN` (no spaces) — test must FAIL.
- [ ] **IMPL**: Change `assert-tdd-log-compliance.sh:182,185` accumulator to use `, ` instead of `,`.
- [ ] **GREEN**: Re-run the inline assertion; it now succeeds. Also re-run T5.8 sub-checks from S1 — they must still pass because they use `grep -F` for the individual tokens (not the joiner).

### Step S3 — Strip narrative comments
- [ ] **GREEN-BEFORE**: Run `./evals/tdd-review-chain/run-eval.sh --self-check` → must still be 28/29 PASS (the 1 FAIL is `assert-version.sh`; T5.8 split into 4 sub-checks → adjust expectation: 31/32 PASS).
- [ ] **CHANGE**: Delete inner narrative comments from blocks T5.1–T5.8 and T6/T7/T8 in `run-eval.sh`. Keep:
  - Section banners (`# ─── T5 ... ───`)
  - `echo "▸ T5 ..."` REPORT lines
- [ ] **GREEN-AFTER**: Re-run `./evals/tdd-review-chain/run-eval.sh --self-check` → SAME count (31/32 PASS) — behavior unchanged.

**Checkpoint**: `./evals/tdd-review-chain/run-eval.sh --self-check` returns expected PASS count.

## Final Verification
- [ ] All assertions in run-eval.sh --self-check pass (31/32, the 1 FAIL is pre-existing `assert-version.sh`)
- [ ] Manual sanity: invoke `assert-tdd-log-compliance.sh --log fixtures/tdd-log-ordering.log` and verify stderr contains `RED-after-GREEN, IMPL-before-RED, IMPL-after-GREEN` (with spaces)
- [ ] No descriptive narrative comments remain inside any T-block (T5.1–T5.8, T6/T7/T8); only banners and echo REPORT lines persist
- [ ] Single commit: `fix(tdd-review-chain): tighten T5.8 content assertions, joiner spacing, strip narrative comments`
- [ ] `.zensu/plans/` and `.zensu/logs/` staged via `git add -f`
