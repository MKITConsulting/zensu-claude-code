# TDD Plan: feature-id-guard Pattern Tightening (round-8 review fixes)

## Context

Round-7 widened `expected/feature-id-guard.pattern:3` from 7 → 16 alternatives
to accept three live-captured ask-back phrasings. Reviewer empirically
falsified the widened alternation by demonstrating four realistic silent
Rule-2-violating captures that all PASS:

- `"... call get_feature with ZEN-999. The product_id is taken from the workspace."` → matches `product_id`
- `"Calling get_feature(ZEN-999) immediately — this is not a typo, proceeding to implementation."` → matches `not.*typo`
- `"I will load and paste ZEN-999 metadata, then get_feature directly."` → matches `paste.*ZEN`
- `"Which product is this? Anyway, I will get_feature(ZEN-999) now."` → matches `[Ww]hich.*product`

Each loose alternative is a bare keyword without an ask-back semantic anchor.
`product_id` in particular is a normal MCP parameter name the agent could
incidentally mention.

Reviewer concrete spec for tightening:

| Was (bare keyword) | Becomes (phrase-level ask-back semantic) |
|--------------------|-------------------------------------------|
| `product_id` | `(need|require|missing|provide).*product_id` |
| `paste.*ZEN` | `(can you|could you|please|user.*)paste.*ZEN` |
| `not.*typo` | `(confirm|verify|check).*not.*typo` |
| `[Ww]hich.*product` | `[Ww]hich.*product\?` (force question shape) |
| `Give.*product` | `(give|provide).*product.*(slug|id)` |
| `confirm.*exist` | `(please|user.*).*confirm.*exist` or `confirm.*ZEN.*exist` |

The two live captures (141606 + 142927) MUST still PASS the tightened pattern.

Finding #2: the existing negative discrimination test in `test-runner.sh:758-778`
is too narrow — it feeds a single hand-crafted capture that avoids every
keyword. PASSing this proves nothing about the widened-then-tightened
discrimination contract. Replace with a loop over all four reviewer-provided
falsifying captures.

The two findings are inherently coupled: the strengthened test from #2 IS the
RED state for #1's tightening.

**Cost-accounting note (informational)**: round-7 task summary claimed a single
budgeted live invocation; the plan log actually records two live runs
(141606 + 142927), i.e. 14 billed `claude --print` invocations not 7. Noted
here so cost reconciliation across the round-chain is accurate. No fix needed
this round — no new live invocations will occur.

**Approach**: Strict Red/Green TDD | **Tech Stack**: Bash test harness via `tests/e2e-plm/test-runner.sh` and `tests/e2e-plm/run.sh --offline` | **Coverage**: SKIPPED (no coverage tooling for bash)

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| 1 | Bug Fix | Strengthen `test_feature_id_guard_rejects_silent_get_feature_call` from single-capture to corpus-of-five (reviewer's 4 falsifying captures + original narrow capture as 5th element per task spec) — produces RED-1 against widened pattern | `tests/e2e-plm/test-runner.sh` | — | [G] | 1 |
| 2 | Bug Fix | Tighten 6 loose alternatives in `expected/feature-id-guard.pattern:3` per reviewer spec; both live captures (141606 + 142927) and `test_feature_id_guard_accepts_*` tests still PASS | `tests/e2e-plm/expected/feature-id-guard.pattern` | 1 | [G] | 1 |

### Step 1 — Strengthen silent-violation discrimination test (RED-1) [G]

- [x] **RED-1**: Rewrote `test_feature_id_guard_rejects_silent_get_feature_call`
  to iterate over a bash array of five silent-violation captures (4 reviewer-
  falsifying + 1 original). Per-capture per-result subshell isolation so the
  loop accumulates failures with diagnostic context. With the unmodified
  widened pattern, 4/5 captures wrongly PASS (original narrow capture still
  FAILs correctly) → test correctly RED. RED reason: assertion mismatch on a
  discrimination contract, NOT a syntax/typo problem.
- [x] **CHANGE**: Implementation = the test rewrite itself.
- [x] **VERIFY-RED**: Ran `bash tests/e2e-plm/test-runner.sh` against
  pre-tightening pattern. Test correctly FAILed with diagnostic
  `4/5 silent-violation captures wrongly PASSed (pattern over-permissive)`.
  Pre-flight empirical check also confirmed each of the 4 reviewer captures
  individually matches the widened pattern.

**Checkpoint**: RED-1 captured cleanly.

### Step 2 — Tighten pattern alternation (GREEN) [G]

- [x] **GREEN-CHANGE**: Applied the 6 tightening replacements in
  `expected/feature-id-guard.pattern:3` per reviewer's exact spec:
  - `product_id` → `(need|require|missing|provide).*product_id`
  - `paste.*ZEN` → `(can you|could you|please|user.*)paste.*ZEN`
  - `not.*typo` → `(confirm|verify|check).*not.*typo`
  - `[Ww]hich.*product` → `[Ww]hich.*product\?`
  - `Give.*product` → `(give|provide).*product.*(slug|id)`
  - `confirm.*exist` → `(please|user.*).*confirm.*exist`
  - Note: `product.*slug` standalone alternative left in place (NOT in
    reviewer's replacement list; the new `(give|provide).*product.*(slug|id)`
    captures the live `Give product slug/id` phrasing; the bare alternative
    is now redundant but harmless — removing it would be out-of-scope and
    none of the 4 falsifying captures match it).
- [x] **VERIFY-GREEN**:
  - `bash tests/e2e-plm/test-runner.sh` — 28/28 PASS, including:
    - `test_feature_id_guard_rejects_silent_get_feature_call`: all 5
      silent-violation captures now correctly FAIL the tightened pattern.
    - `test_feature_id_guard_accepts_which_product_phrasing`: PASS.
    - `test_feature_id_guard_accepts_paste_details_phrasing`: PASS.
    - `test_shipped_patterns_pass_against_ideal_capture`: PASS.
    - `test_shipped_patterns_reject_bad_captures`: PASS.
  - `bash tests/e2e-plm/run.sh --offline` — 7/7 PASS (newest-per-scenario
    picks 142927 for feature-id-guard).
  - Direct per-file verification: both 141606 and 142927 captures
    individually PASS the tightened pattern (no live capture regression).
- [x] **TWEAK-LOOP**: Not needed — first-pass tightening produced GREEN
  on every contract gate.

**Checkpoint**: 28/28 tests PASS; offline 7/7 PASS; both live captures PASS.

## Final Verification
- [x] `bash tests/e2e-plm/test-runner.sh` — 28 PASS / 0 FAIL
- [x] `bash tests/e2e-plm/run.sh --self-check` exit 0
- [x] `bash tests/e2e-plm/run.sh --offline` — 7/7 PASS (against newest 142927 for feature-id-guard; both live captures individually verified)
- [x] `bash tests/e2e/run.sh --self-check` exit 0 (cross-suite)
- [x] No `claude --print` invocations occurred this round (offline only — zero billed tokens).
- [x] Build verification: n/a (plain bash-script plugin; test suites ARE the build).
