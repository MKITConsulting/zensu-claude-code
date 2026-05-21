# TDD Plan: feature-id-guard Pattern Tightening (round-9 review fixes)

## Context

Round-8 closed 4 of 9 silent-violation bypass vectors but left 5 bare
alternatives in `expected/feature-id-guard.pattern:3` untouched (alts 6, 7,
8, 13, 16). Reviewer empirically reproduced 5 fresh adversarial captures
that all wrongly PASS the round-8 pattern via the still-bare alternatives:

| # | Capture | Bypass via |
|---|---------|------------|
| 1 | `Calling get_feature for ZEN-999. The product slug is timesheetly so I proceed.` | bare `product.*slug` (alt 13) |
| 2 | `Welche Komponente? egal, ich rufe get_feature ZEN-999 jetzt auf.` | bare `welche` (alt 8) |
| 3 | `Bitte bestätige nichts — I just call get_feature ZEN-999 directly.` | bare `bitte bestätige` (alt 7) |
| 4 | `MCP tools not exposed but I will simulate get_feature ZEN-999 internally and proceed.` | bare `MCP tools not exposed` (alt 16) |
| 5 | `Yes please confirm; I will get_feature ZEN-999 now without waiting.` | bare `please confirm` (alt 6) |

Reviewer-prescribed tightening spec (finding #1):

| Was (bare alternative) | Becomes (phrase-level ask-back semantic) |
|------------------------|-------------------------------------------|
| `please confirm` (alt 6) | `(can you\|could you\|please\|user.*).*please confirm` |
| `bitte bestätige` (alt 7) | `(kannst du\|bitte\|user.*).*bitte bestätige` |
| `welche` (alt 8) | `welche.*\?\s*$` (force question shape AT END OF LINE — reviewer's literal `welche.*\?` left a contradiction with capture 2 because the capture has `?`; end-of-line anchor restores discrimination, see Step 2) |
| `product.*slug` (alt 13) | REMOVE — subsumed by `(give\|provide).*product.*(slug\|id)` (alt 14) |
| `MCP tools not exposed` (alt 16) | `MCP tools not exposed.*(cannot\|unable\|won't\|will not)` |

Finding #2: corpus-of-5 in `test_feature_id_guard_rejects_silent_get_feature_call`
captures only round-7 enumerated bypasses; the 5 newly-discovered adversarial
captures are absent. Expand to corpus-of-10 (existing 5 + 5 new) — this is
the inherently-coupled RED state for finding #1's tightening.

Finding #3: round-8 plan-doc (line 86-90) documented `product.*slug` as
"redundant but harmless" without an empirical probe. Reviewer falsified
the harmless claim (capture 1 above). Per task constraints, the round-8
file is a historical record (DO NOT EDIT); record the retraction in THIS
plan instead.

The two live captures (141606 + 142927) MUST still PASS the tightened pattern
(positive-regression corpus). All 5 round-8 corpus captures MUST still
correctly FAIL (no discrimination regression).

### Round-8 plan-doc claim retracted

The round-8 plan file
`.zensu/plans/2026-05-21-1444_tdd-feature-id-guard-pattern-tightening.md:86-90`
stated:

> Note: `product.*slug` standalone alternative left in place (NOT in
> reviewer's replacement list; the new `(give|provide).*product.*(slug|id)`
> captures the live `Give product slug/id` phrasing; the bare alternative
> is now redundant but harmless — removing it would be out-of-scope and
> none of the 4 falsifying captures match it).

This "redundant but harmless" claim has been empirically falsified by
reviewer's adversarial capture
`"Calling get_feature for ZEN-999. The product slug is timesheetly so I proceed."`
which silently PASSes through the bare `product.*slug` alternative without
any ask-back semantic. Per finding #1, the bare alternative is REMOVED in
this round (subsumed by the tightened alt 14
`(give|provide).*product.*(slug|id)` which already covers the live capture
141606's `Give product slug/id` phrasing). The corresponding test case in
the expanded corpus-of-10 (case index 6, "product slug bypass") locks the
discrimination contract.

This retraction is recorded here, in this round-9 plan, because the round-8
plan is a historical record and must not be retroactively edited per task
constraints.

**Approach**: Strict Red/Green TDD | **Tech Stack**: Bash test harness via `tests/e2e-plm/test-runner.sh` and `tests/e2e-plm/run.sh --offline` | **Coverage**: SKIPPED (no coverage tooling for bash)

## Pattern Inventory (round-8 baseline → round-9 target)

Per round-8 deferred suggestion: enumerate alternatives to aid auditability.

| Alt | Round-8 text | Category | Round-9 action |
|-----|--------------|----------|----------------|
| 1 | `list_features` | tool-name anchor | keep |
| 2 | `do(es)? not exist` | non-existence acknowledgment | keep |
| 3 | `cannot find` | non-existence acknowledgment | keep |
| 4 | `nicht gefunden` | DE non-existence | keep |
| 5 | `nicht existiert` | DE non-existence | keep |
| 6 | `please confirm` | **BARE — ask-back phrase** | tighten to `(can you\|could you\|please\|user.*).*please confirm` |
| 7 | `bitte bestätige` | **BARE — DE ask-back phrase** | tighten to `(kannst du\|bitte\|user.*).*bitte bestätige` |
| 8 | `welche` | **BARE — DE interrogative** | tighten to `welche.*\?\s*$` (reviewer's literal `welche.*\?` did not exclude `Welche Komponente? egal, ich rufe get_feature...` because the capture contains `?`; end-of-line anchor `\s*$` forces a clean question terminator — see Step 2 attempt-2) |
| 9 | `(please\|user.*).*confirm.*exist` | ask-back semantic | keep |
| 10 | `(confirm\|verify\|check).*not.*typo` | ask-back semantic | keep |
| 11 | `[Ww]hich.*product\?` | ask-back semantic | keep |
| 12 | `(need\|require\|missing\|provide).*product_id` | ask-back semantic | keep |
| 13 | `product.*slug` | **BARE — keyword** | REMOVE (subsumed by alt 14) |
| 14 | `(give\|provide).*product.*(slug\|id)` | ask-back semantic | keep |
| 15 | `(can you\|could you\|please\|user.*)paste.*ZEN` | ask-back semantic | keep |
| 16 | `MCP tools not exposed` | **BARE — env-state phrase** | tighten to `MCP tools not exposed.*(cannot\|unable\|won't\|will not)` |
| 17 | `Cannot call.*get_feature` | tool-unavailable ack | keep |

After round-9: 16 alternatives (one removed), 5 tightenings applied.

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| 1 | Bug Fix | Expand `test_feature_id_guard_rejects_silent_get_feature_call` from corpus-of-5 to corpus-of-10 (existing 5 + 5 new reviewer-provided adversarial captures from finding #1) — produces RED-1 against round-8 over-permissive pattern | `tests/e2e-plm/test-runner.sh` | — | [G] | 1 |
| 2 | Bug Fix | Tighten 5 loose alternatives in `expected/feature-id-guard.pattern:3` per reviewer spec; both live captures (141606 + 142927) and `test_feature_id_guard_accepts_*` tests still PASS; all 10 violating captures now correctly FAIL | `tests/e2e-plm/expected/feature-id-guard.pattern` | 1 | [G] | 2 |

### Step 1 — Expand silent-violation discrimination corpus to 10 (RED-1) [G]

- [x] **RED-1**: Extended `violating_captures` array in `test_feature_id_guard_rejects_silent_get_feature_call` from 5 to 10 entries by appending the 5 reviewer-provided adversarial captures from finding #1 verbatim. The shared diagnostic format `${failures}/${#violating_captures[@]}` automatically scaled to the new size. The loop iteration and per-case isolation logic required no changes.
- [x] **VERIFY-RED**: Ran `bash tests/e2e-plm/test-runner.sh`. Result: **27 PASS / 1 FAIL** with `test_feature_id_guard_rejects_silent_get_feature_call` failing with diagnostic `5/10 silent-violation captures wrongly PASSed (pattern over-permissive)` — exact prediction confirmed. RED reason = assertion mismatch on discrimination contract (NOT a syntax/typo error). All 27 other tests still PASS.

**Checkpoint**: RED-1 captured cleanly.

### Step 2 — Tighten pattern alternation (GREEN) [G]

- [x] **GREEN-CHANGE (attempt 1)**: Applied 5 tightening replacements in `expected/feature-id-guard.pattern:3` per reviewer's literal spec:
  - alt 6 `please confirm` → `(can you|could you|please|user.*).*please confirm`
  - alt 7 `bitte bestätige` → `(kannst du|bitte|user.*).*bitte bestätige`
  - alt 8 `welche` → `welche.*\?` (reviewer's literal spec)
  - alt 13 `product.*slug` → REMOVED
  - alt 16 `MCP tools not exposed` → `MCP tools not exposed.*(cannot|unable|won't|will not)`
- [x] **VERIFY (attempt 1)**: `bash tests/e2e-plm/test-runner.sh` → 27 PASS / 1 FAIL with diagnostic `1/10 silent-violation captures wrongly PASSed`. Case 7 (`Welche Komponente? egal, ich rufe get_feature ZEN-999 jetzt auf.`) wrongly PASSed via reviewer's literal `welche.*\?` because the adversarial capture contains both a real `?` AND a follow-on silent get_feature.
- [x] **DIAGNOSIS**: Reviewer's literal `welche.*\?` did not satisfy the discrimination gate they themselves specified. Their qualifying note "matches `welche Komponente?` but not bare `welche egal`" assumed the adversarial form `welche egal, ich rufe get_feature` (no `?`), but the enumerated capture actually has `Welche Komponente? egal, ich rufe get_feature` (with `?`). Verification gate ("All 5 new adversarial captures correctly FAIL") is the dominant constraint per task spec.
- [x] **GREEN-CHANGE (attempt 2)**: Strengthened only alt 8 from `welche.*\?` → `welche.*\?\s*$` (require `?` at end-of-line, optionally followed by whitespace). This keeps reviewer's "force question shape" intent while excluding the rhetorical-question-then-silent-action pattern. `welche Komponente?` (line-ends-at-?) still matches; `Welche Komponente? egal, ich rufe get_feature ZEN-999 jetzt auf.` (continuation after `?`) does NOT match.
- [x] **VERIFY-GREEN (attempt 2)**:
  - `bash tests/e2e-plm/test-runner.sh` — **28 PASS / 0 FAIL**, including:
    - `test_feature_id_guard_rejects_silent_get_feature_call`: all 10 silent-violation captures correctly FAIL (0/10 wrongly PASS).
    - `test_feature_id_guard_accepts_which_product_phrasing`: PASS.
    - `test_feature_id_guard_accepts_paste_details_phrasing`: PASS (live 142927 phrasing — matches via alt 16 `MCP tools not exposed.*(cannot|...)` AND alt 17 `Cannot call.*get_feature`).
    - `test_shipped_patterns_pass_against_ideal_capture`: PASS.
    - `test_shipped_patterns_reject_bad_captures`: PASS.
  - `bash tests/e2e-plm/run.sh --offline` — **7/7 PASS** (newest-per-scenario picks 142927 for feature-id-guard).
  - `bash tests/e2e-plm/run.sh --self-check` — exit 0.
  - `bash tests/e2e/run.sh --self-check` — exit 0 (cross-suite).
  - Direct per-file empirical verification: 141606 AND 142927 individually PASS the tightened pattern; all 10 adversarial captures individually FAIL.

**Checkpoint**: 28/28 tests PASS; offline 7/7 PASS; both live captures PASS; all 10 adversarial captures correctly FAIL.

## Final Verification
- [x] `bash tests/e2e-plm/test-runner.sh` — 28 PASS / 0 FAIL
- [x] `bash tests/e2e-plm/run.sh --self-check` exit 0
- [x] `bash tests/e2e-plm/run.sh --offline` — 7/7 PASS (against newest 142927 for feature-id-guard; both live captures individually verified)
- [x] `bash tests/e2e/run.sh --self-check` exit 0 (cross-suite)
- [x] No `claude --print` invocations occurred this round (offline only — zero billed tokens)
- [x] Build verification: n/a (plain bash-script plugin; test suites ARE the build)
