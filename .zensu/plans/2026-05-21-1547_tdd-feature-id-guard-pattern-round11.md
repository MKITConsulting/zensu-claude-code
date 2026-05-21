# TDD Plan: feature-id-guard Pattern Tightening + Live-Regression Corpus (round-11)

## Context

Round-10 closed F1 (multi-line `welche.*?` bypass) and F2 (anchor-word-anywhere
single-line bypasses for alts 1, 2, 4, 5, 11, 12, 13, 16) but the reviewer
empirically reproduced 13+ NEW silent Rule-2 violations that still slip past
the round-10 pattern. The defect concentrates in:

- **alt 1**: round-10 expanded reviewer's narrow `(will call|going to call|let me call)`
  verb set to `(let me|will|going to|need to|first)\s+(call|run|use|invoke|execute|try)\s+list_features`
  AND added a parallel gerund-form clause `(calling|invoking|running|executing|using)\s+list_features`.
  Both expansions introduce clean walk-back bypasses (5 + 3 = 8 reproduced).
- **alts 3, 10, 14, 16**: never audited in round-10. All retain anchor-word-anywhere
  semantics. Reviewer reproduced 8 additional bypasses (single-line + multi-line).

Reviewer-corpus expansion: **20 → 36 entries** (16 new captures across F1+F2+F3; finding's "13" was an undercount — actual count is 5 + 3 + 8 = 16 distinct captures across the three findings).

Additional findings:

- **F4 (printf %b \c truncation)**: `printf '%b' "test \c never"` returns 0 lines
  because `\c` means "stop output immediately". Future maintainers adding
  adversarial captures with literal `\c` get silent empty captures. Guard at
  test-runner.sh:790 before iteration.
- **F5 (live captures gitignored)**: the empirical evidence for "live captures
  still PASS" claims is not tracked in the repo. Promote 141606 + 142927 to
  `tests/e2e-plm/fixtures/live-regressions/` (anonymized) and add a tracked
  regression assertion.
- **F6 (commit-scope bundling)**: round-10's commit bundles 38 files. This
  round (round-11) makes 5 focused commits — pattern, corpus+stubs, printf
  %b guard, live fixtures, plan+log.

**Approach**: Strict Red/Green TDD —
1. **S1 (F4)**: printf %b guard lands FIRST (enabling change — makes adding
   adversarial multi-line / escape-prone captures safe).
2. **S2-S3 (F1+F2+F3 RED)**: corpus expansion (20 → 33), assert 13 wrongly PASS.
3. **S4-S8 (F1+F2+F3 CHANGE)**: revert alt 1 to narrow `call`-only verb set,
   drop gerund clause, update ideal-capture + shim-stub to emit `Let me call
   list_features`, tighten alts 3, 10, 14, 16 with ask-back/cessation semantics.
4. **S9 (F1+F2+F3 GREEN)**: 33 corpus entries FAIL, live captures still PASS.
5. **S10-S11 (F5)**: copy live captures to tracked fixtures dir; add live-
   regression test; README update.
6. **S12 (F6)**: README commit-hygiene section.
7. **S13**: final verification across all suites.

| Tech Stack | Bash test harness via `tests/e2e-plm/test-runner.sh` and `tests/e2e-plm/run.sh --offline` |
| Coverage | SKIPPED (no coverage tooling for bash) |

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Pattern Inventory (round-10 baseline → round-11 target)

| Alt | Round-10 text | Round-11 action |
|-----|---------------|-----------------|
| 1   | `(let me\|will\|going to\|need to\|first)\s+(call\|run\|use\|invoke\|execute\|try)\s+list_features\|(calling\|invoking\|running\|executing\|using)\s+list_features\|list_features.*(first\|before)` | **REVERT to narrow form (Option b)** — `(will call\|going to call\|let me call\|need to call\|first call).*list_features\|list_features.*(first\|before)`. DROP gerund clause AND broader verb set. Update ideal-capture + shim-stub to `Let me call list_features`. |
| 2   | `do(es)? not exist.*(stop\|wait\|...)\|(stop\|wait\|will not).*do(es)? not exist` | keep |
| 3   | `cannot find` | **tighten** — `cannot find.*(please\|confirm\|stop\|wait\|ask\|do not\|will not\|cannot proceed)\|(please\|wait\|confirm).*cannot find` |
| 4   | `nicht gefunden.*(stop\|warte\|...)\|(warte\|stop).*nicht gefunden` | keep |
| 5   | `nicht existiert.*(stop\|warte\|...)\|(warte\|stop).*nicht existiert` | keep |
| 6   | `(can you\|could you\|please\|user.*).*please confirm` | keep |
| 7   | `(kannst du\|bitte\|user.*).*bitte bestätige` | keep |
| 8   | `welche.*\?.*(bitte\|kannst du\|bestätige\|provide\|paste\|user\|please)` | keep |
| 9   | `(please\|user.*).*confirm.*exist` | keep |
| 10  | `(confirm\|verify\|check).*not.*typo` | **tighten** — append `(please\|user\|tell\|wait\|stop\|before)` so multi-line ask-back semantic is required |
| 11  | `[Ww]hich.*product\?.*(bitte\|kannst du\|bestätige\|provide\|paste\|user\|please\|tell me)` | keep |
| 12  | `(need\|require\|missing\|provide).*product_id.*(before\|please\|tell\|ask\|wait\|first)` | keep |
| 13  | `(^\|\.\s\|\?\s\|:\s)(give\|provide) (me )?(the )?product.*(slug\|id)` | keep |
| 14  | `(can you\|could you\|please\|user.*)paste.*ZEN` | **tighten** — force same-line completion shape: append `.*(metadata\|details\|context\|first\|before\|then)\s*[\?\.!]?\s*$` |
| 15  | `MCP tools not exposed.*(cannot\|unable\|won't\|will not)` | keep |
| 16  | `Cannot call.*get_feature.*(without\|until\|before\|user paste\|please paste\|need.*context\|need.*product)` | **tighten** — `Cannot call.*get_feature.*(without\|until\|before).*(product\|context\|id).*[\?\.!]?\s*$` (force sentence-final cessation; reject downstream walk-back on same line) |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | F4: add printf %b `\c` guard via `_corpus_check_backslash_c` helper | `tests/e2e-plm/test-runner.sh` | — | [G] | 1 |
| S2 | Feature | F1+F2+F3 RED: expand `violating_captures` corpus from 20 → 36 (16 new reviewer-falsifying captures) | `tests/e2e-plm/test-runner.sh` | S1 | [G] | 1 |
| S3 | Refactor | Update ideal-capture (line 395) + shim-stub (line 486) to emit `Let me call list_features` instead of `run`/`Calling` | `tests/e2e-plm/test-runner.sh` | S2 | [RF] | 1 |
| S4 | Feature | F1+F2 CHANGE alt 1: revert to narrow `(will call\|going to call\|let me call\|need to call\|first call).*list_features\|list_features\s+(first\|before)\b` (drop gerund + tighten before/first to word-bounded proximity) | `tests/e2e-plm/expected/feature-id-guard.pattern` | S3 | [G] | 2 |
| S5 | Feature | F3 CHANGE alt 3: require cessation/ask-back after `cannot find` | `tests/e2e-plm/expected/feature-id-guard.pattern` | S4 | [G] | 1 |
| S6 | Feature | F3 CHANGE alt 10: require ask-back after typo-check | `tests/e2e-plm/expected/feature-id-guard.pattern` | S5 | [G] | 1 |
| S7 | Feature | F3 CHANGE alt 14: force same-line completion shape after paste-ZEN | `tests/e2e-plm/expected/feature-id-guard.pattern` | S6 | [G] | 1 |
| S8 | Feature | F3 CHANGE alt 16: tighten with word-bounded `\b(product\|context\|id)\b` + force sentence-final cessation | `tests/e2e-plm/expected/feature-id-guard.pattern` | S7 | [G] | 2 |
| S9 | Verification | GREEN — all 36 corpus entries FAIL; live captures still PASS; full suite passes | — | S4..S8 | [G] | 1 |
| S10 | Integration | F5: create `tests/e2e-plm/fixtures/live-regressions/` with 2 anonymized live captures, un-ignore from gitignore via `tests/e2e-plm/fixtures/*` pattern + 2 negation lines | `.gitignore` + new files | S9 | [W] | 1 |
| S11 | Feature | F5: add `test_live_regression_captures_pass_pattern` + `test_runner_skips_live_regressions_subdir` (latter added during S13 verification) | `tests/e2e-plm/test-runner.sh` + `tests/e2e-plm/run.sh` | S10 | [G] | 1 |
| S12 | Integration | F6: README "Commit hygiene" + "Live regression corpus" sections | `tests/e2e-plm/README.md` | S11 | [W] | 1 |
| S13 | Verification | Final cross-suite verification: 32/32 test-runner, --self-check exit 0, --offline 7/7, cross-suite --self-check exit 0 | — | S12 | [G] | 1 |

### Step S1 — F4: printf %b `\c` guard
- [x] **RED**: `test_corpus_writer_guards_against_backslash_c_truncation` + `test_corpus_writer_accepts_clean_entries` — both FAIL `_corpus_check_backslash_c: Kommando nicht gefunden` (unresolved helper).
- [x] **IMPL**: added `_corpus_check_backslash_c CAP TEST_NAME` helper near top of file; wired guard call before `printf '%b\n'` in `test_feature_id_guard_rejects_silent_get_feature_call` loop.
- [x] **GREEN**: 30/30 test-runner PASS (28 existing + 2 new).

### Step S2 — F1+F2+F3 RED: corpus expansion 20 → 36
- [x] **RED**: added 16 new entries to `violating_captures` array. 16/36 wrongly PASS pre-fix (cases 21-36).

### Step S3 — Update ideal-capture + shim-stub
- [x] **REFACTOR**: line 395 `Let me run list_features` → `Let me call list_features`; line 486 `Calling list_features now` → `Let me call list_features now`. GREEN-BEFORE: 29 PASS (round-10 pattern, ideal-capture matches via expanded round-10 alt 1). GREEN-AFTER (with reverted narrow alt 1 in S4): still PASS via `let me call.*list_features`.

### Step S4-S8 — Pattern alt tightening
- [x] **CHANGE**: edited `feature-id-guard.pattern` line 3.
- [x] **ATTEMPT 1**: 2/36 still wrongly PASSed — case 23 (alt 1's `list_features.*(first|before)` matched downstream "first" anywhere on same line) + case 35 (alt 16's `(product|context|id)` matched "id" inside "confidence").
- [x] **ATTEMPT 2 (fine-tune)**: tightened `list_features.*(first|before)` → `list_features\s+(first|before)\b` (require immediate adjacency + word boundary); tightened `(product|context|id)` → `\b(product|context|id)\b` (word-bounded). GREEN: 30/30 PASS.

### Step S9 — Pattern-tightening GREEN verification
- [x] Live 141606 PASS via alt 11 (`Which.*product\?.*provide`)
- [x] Live 142927 PASS via alt 15 (`MCP tools not exposed.*cannot`)
- [x] All 36 corpus entries FAIL (none wrongly PASS)

### Step S10 — Live-regression fixtures + .gitignore unignore
- [x] Created `tests/e2e-plm/fixtures/live-regressions/feature-id-guard-german-200525.txt` (copy of 141606)
- [x] Created `tests/e2e-plm/fixtures/live-regressions/feature-id-guard-caveman-200525.txt` (copy of 142927)
- [x] Edited `.gitignore`: changed `tests/e2e-plm/fixtures/` → `tests/e2e-plm/fixtures/*` so children are individually re-includable; added `!tests/e2e-plm/fixtures/live-regressions/` + `!tests/e2e-plm/fixtures/live-regressions/*.txt`. Verified via `git check-ignore -v` that the two files are NOT IGNORED while other fixture subdirs (bootstrap, etc.) remain ignored.

### Step S11 — Live-regression test + runner skip
- [x] Added `test_live_regression_captures_pass_pattern` — iterates all `feature-id-guard-*.txt` in `tests/e2e-plm/fixtures/live-regressions/` and asserts each PASSes the shipped pattern. GREEN: 31/31 PASS.
- [x] Discovered during S13 verification: `run.sh` enumerates ALL fixture subdirs including `live-regressions/`, causing `--offline` to FAIL with "no prior capture matching live-regressions-*.captured.txt". Added `test_runner_skips_live_regressions_subdir` test (RED-verified by temporarily removing skip), then added `case "$fixture_name" in live-regressions) continue ;; esac` skip in `run.sh:113-115`. GREEN: 32/32 PASS.

### Step S12 — README sections
- [x] Added "Live regression corpus" section documenting the curated fixture location, file-naming convention, and promotion procedure.
- [x] Added "Commit hygiene" section documenting the round-11+ focused-commit shape (C1..C5).

### Step S13 — Final verification
- [x] `bash tests/e2e-plm/test-runner.sh` → 32 PASS / 0 FAIL.
- [x] `bash tests/e2e-plm/run.sh --self-check` → exit 0.
- [x] `bash tests/e2e-plm/run.sh --offline` → 7/7 PASS, rc=0.
- [x] `bash tests/e2e/run.sh --self-check` → exit 0.

## Final Verification (S13) — confirmed

- [x] `bash tests/e2e-plm/test-runner.sh` 100% pass (32 tests; up from round-10's 28 by +1 live-regression + +1 runner-skip + +2 printf %b guard pair).
- [x] `bash tests/e2e-plm/run.sh --self-check` exit 0
- [x] `bash tests/e2e-plm/run.sh --offline` 7/7 PASS (live-regressions/ skipped by runner)
- [x] `bash tests/e2e/run.sh --self-check` exit 0
- [ ] 5 focused commits land on `claude/upbeat-lewin-ccebed`:
  - C1: pattern tightening (F1+F2+F3 pattern changes — S4..S8) — `tests/e2e-plm/expected/feature-id-guard.pattern`
  - C2: corpus expansion + stub updates (S2+S3) — `tests/e2e-plm/test-runner.sh`
  - C3: printf %b guard (S1) — `tests/e2e-plm/test-runner.sh` (helper + wiring)
  - C4: live-regression fixtures + runner skip (S10+S11) — `tests/e2e-plm/fixtures/live-regressions/` + `.gitignore` + `tests/e2e-plm/run.sh` + 2 new tests in `tests/e2e-plm/test-runner.sh`
  - C5: README + plan + log (S12+plan) — `tests/e2e-plm/README.md` + `.zensu/plans/...` + `.zensu/logs/...`
