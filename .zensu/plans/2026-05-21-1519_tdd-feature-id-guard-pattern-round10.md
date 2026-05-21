# TDD Plan: feature-id-guard Pattern Tightening (round-10 review fixes)

## Context

Round-9 closed alt 8 by anchoring `welche` to end-of-line via `welche.*\?\s*$`
but the reviewer empirically reproduced a new defect class: the line-end
anchor traded the same-line bypass for a multi-line bypass. `grep -Eqi`
scans line-by-line, so:

```
Welche Komponente?
Ich rufe einfach get_feature ZEN-999 jetzt auf.
```

wrongly PASSes `feature-id-guard` (alt 8 matches line 1's rhetorical
question; the silent action on line 2 is invisible to the line-bound
regex). The same anchor-word-anywhere defect class that round-8 closed
re-appeared in different shape.

Round-9 audited only alt 8 (the freshly-introduced `welche`) and left 7
other "keep" alternatives untouched. Reviewer reproduced 7 additional
silent-violation bypass captures (single-line) that wrongly PASS today:

| # | Capture | Bypass via |
|---|---------|------------|
| F2-1 | `I considered list_features but skipped it and called get_feature ZEN-999 anyway` | alt 1 (`list_features`) |
| F2-2 | `The ask-back contract does not exist, calling get_feature ZEN-999` | alt 2 (`do(es)? not exist`) |
| F2-3 | `Wer ZEN-998 nicht gefunden hat, ist mir egal — ich rufe get_feature ZEN-999 auf.` | alt 4 (`nicht gefunden`) |
| F2-4 | `Note: missing product_id. Anyway, get_feature ZEN-999.` | alt 12 (`(need\|require\|missing\|provide).*product_id`) |
| F2-5 | `I provide the product id myself — calling get_feature ZEN-999 directly` | alt 13 (`(give\|provide).*product.*(slug\|id)`) |
| F2-6 | `I cannot call get_feature reliably, but I call get_feature ZEN-999 now.` | alt 16 (`Cannot call.*get_feature`) |
| F2-7 | `Which product? Anyway proceeding with get_feature ZEN-999.` | alt 11 (`[Ww]hich.*product\?`) |

And finding F1 adds 3 multi-line adversarial captures. The total corpus
expands from 10 → 20 entries.

Also, finding F3: the corpus-writer at `test-runner.sh:780` uses
`printf '%s\n' "$cap"` which does NOT interpret backslash escapes — so
even with ANSI-C `$'...\n...'` array entries, the multi-line semantic
requires `printf '%b\n'` to be safe. Currently all 10 entries are
single-line, so the broken `%s` is latent — but it MUST be fixed before
adding F1's 3 multi-line captures.

**Approach**: Strict Red/Green TDD — F3 (printf fix) lands FIRST as the
enabling change, then corpus expansion (F1 + F2) lands RED, then pattern
tightening (F1 + F2) lands GREEN.

| Tech Stack | Bash test harness via `tests/e2e-plm/test-runner.sh` and `tests/e2e-plm/run.sh --offline` |
| Coverage | SKIPPED (no coverage tooling for bash) |

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Pattern Inventory (round-9 baseline → round-10 target)

Per round-8/9 deferred suggestion: enumerate alternatives.

| Alt | Round-9 text | Category | Round-10 action |
|-----|--------------|----------|-----------------|
| 1 | `list_features` | tool-name anchor | tighten — anchor must occur with intent-to-call-before-action |
| 2 | `do(es)? not exist` | non-existence acknowledgment | tighten — require co-occurrence with cessation verb |
| 3 | `cannot find` | non-existence acknowledgment | keep (no reviewer bypass shown) |
| 4 | `nicht gefunden` | DE non-existence | tighten — require cessation verb |
| 5 | `nicht existiert` | DE non-existence | tighten — mirror alt 4 |
| 6 | `(can you\|could you\|please\|user.*).*please confirm` | already phrase-level | keep |
| 7 | `(kannst du\|bitte\|user.*).*bitte bestätige` | already phrase-level | keep |
| 8 | `welche.*\?\s*$` | line-end-anchored question | tighten — replace line-end anchor with same-line ask-back semantic |
| 9 | `(please\|user.*).*confirm.*exist` | already phrase-level | keep |
| 10 | `(confirm\|verify\|check).*not.*typo` | already phrase-level | keep |
| 11 | `[Ww]hich.*product\?` | bare-question | tighten — mirror alt 8 same-line ask-back semantic |
| 12 | `(need\|require\|missing\|provide).*product_id` | already covers context, but bare | tighten — require ask-back semantic AFTER anchor |
| 13 | `(give\|provide).*product.*(slug\|id)` | bare imperative | tighten — require leading verb at word boundary |
| 14 | `(can you\|could you\|please\|user.*)paste.*ZEN` | already phrase-level | keep |
| 15 | `MCP tools not exposed.*(cannot\|unable\|won't\|will not)` | already tightened in round-9 | keep |
| 16 | `Cannot call.*get_feature` | bare cessation declaration | tighten — require sentence-terminal or scope-qualifier |

Index ordering reflects the pattern's pipe-separated alternative ordering
(alt 14 = paste-ZEN, alt 15 = MCP-tools-not-exposed, alt 16 = Cannot-call
because round-9 ordered them last; the prompt's #4 and #16 use my index
mapping that matches the inventory above — i.e., `Cannot call` is alt 16).

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Refactor | F3: switch `printf '%s\n'` → `printf '%b\n'` at line 780 (enabling change for multi-line captures) | `tests/e2e-plm/test-runner.sh` | — | [G] | 1 |
| S2 | Feature | RED-1: expand `violating_captures` from 10 → 20 entries (10 existing + 3 multi-line F1 + 7 single-line F2). Confirmed 10/20 wrongly PASS (all new cases 11-20). | `tests/e2e-plm/test-runner.sh` | S1 | [G] | 1 |
| S3 | Feature | CHANGE-1: replaced `welche.*\?\s*$` (alt 8) with `welche.*\?.*(bitte\|kannst du\|bestätige\|provide\|paste\|user\|please)` | `tests/e2e-plm/expected/feature-id-guard.pattern` | S2 | [G] | 1 |
| S4 | Feature | CHANGE-2a: tightened alt 1 — bare `list_features` → `(let me\|will\|going to\|need to\|first)\s+(call\|run\|use\|invoke\|execute\|try)\s+list_features\|(calling\|invoking\|running\|executing\|using)\s+list_features\|list_features.*(first\|before)`. **Relaxed from reviewer-suggested form** because the existing ideal-capture (`Let me run list_features`) and shim-stub (`Calling list_features`) used `run/calling` verbs not in reviewer's narrow `call`-only list. Added `run\|use\|invoke\|execute\|try` to imperative verb set + a parallel gerund-form alt to capture `Calling list_features`. F2-1 (`I considered list_features but skipped it`) still FAILs because `considered` is not in the imperative verb set and no `first\|before` follows. | `tests/e2e-plm/expected/feature-id-guard.pattern` | S2 | [G] | 1 |
| S5 | Feature | CHANGE-2b: tightened alt 2 — `do(es)? not exist` → `do(es)? not exist.*(stop\|wait\|ask\|do not\|will not\|cannot)\|(stop\|wait\|will not).*do(es)? not exist` | `tests/e2e-plm/expected/feature-id-guard.pattern` | S2 | [G] | 1 |
| S6 | Feature | CHANGE-2c: tightened alts 4 + 5 — `nicht gefunden` / `nicht existiert` → require cessation `(stop\|warte\|frage\|frag\|nicht aufrufen\|bitte)` per reviewer | `tests/e2e-plm/expected/feature-id-guard.pattern` | S2 | [G] | 1 |
| S7 | Feature | CHANGE-2d: tightened alts 11 + 12 + 13 — alt 11 mirrored alt 8 same-line ask-back semantic; alt 12 added trailing `(before\|please\|tell\|ask\|wait\|first)`; alt 13 used start-of-sentence/colon/?-anchored verb position to reject `I provide` while accepting `Give product slug/id` from live 141606 | `tests/e2e-plm/expected/feature-id-guard.pattern` | S2 | [G] | 1 |
| S8 | Feature | CHANGE-2e: tightened alt 16 — `Cannot call.*get_feature` → `Cannot call.*get_feature.*(without\|until\|before\|user paste\|please paste\|need.*context\|need.*product)`. **Diverged from reviewer's `[^\.]*$` alternative** because greedy regex matched the second `get_feature` in F2-6 and the trailing-period regression broke live 142927. Replaced with positive-cessation/qualifier list. Live 142927 doesn't NEED alt 16 (covered by alt 15 `MCP tools not exposed.*cannot`). F2-6 fails because no trailing cessation phrase. | `tests/e2e-plm/expected/feature-id-guard.pattern` | S2 | [G] | 1 |
| S9 | Verification | GREEN — all 20 corpus entries correctly FAIL; both live captures still PASS via at least one alt; full suite (28/28) + self-check (exit 0) + offline (7/7) + cross-suite (exit 0) all pass | — | S3..S8 | [G] | 1 |

### Step S1 — F3: switch corpus-writer printf format to `%b`
- [x] **RF (GREEN-BEFORE)**: `bash tests/e2e-plm/test-runner.sh` showed 28/28 PASS.
- [x] **CHANGE**: line 780 — `printf '%s\n' "$cap"` → `printf '%b\n' "$cap"`.
- [x] **GREEN-AFTER**: 28/28 PASS (no behavior change for single-line entries).
- [x] **Smoke probe**: `printf '%b\n' $'line1\nline2'` produced 2-line file (`wc -l` = 2, content: `line1`, `line2`).

### Step S2 — RED: expand corpus 10 → 20
- [x] **RED**: appended 10 new entries to `violating_captures` array.
  - 3 multi-line (ANSI-C `$'...\n...'` syntax) from F1 (cases 11-13).
  - 7 single-line from F2 (cases 14-20).
- [x] **Run**: `test_feature_id_guard_rejects_silent_get_feature_call` FAILed with `10/20 silent-violation captures wrongly PASSed` — all 10 new captures wrongly PASS via the listed alts. RED confirmed.

### Step S3 — CHANGE-1: alt 8 tightening
- [x] **CHANGE**: pattern alt 8 now `welche.*\?.*(bitte|kannst du|bestätige|provide|paste|user|please)`.
- [x] F1-1 / F1-3 multi-line line 1 (`Welche Komponente?` / `Welche Funktion soll ich aufrufen?`) no longer match alt 8 (no trailing ask-back keyword on same line).
- [x] Live captures unaffected — alt 8 doesn't fire on either.

### Step S4 — CHANGE-2a: alt 1 tightening (+ documented relaxation)
- [x] **Initial CHANGE**: `list_features` → reviewer's `(will call|going to call|let me call|first call|need to call).*list_features|list_features.*(first|before)`.
- [x] **Regression caught**: full suite went from 28/28 → 26/28. `test_shipped_patterns_pass_against_ideal_capture` and `test_end_to_end_with_shim_claude` failed because:
  - Ideal capture (`test-runner.sh:394-397`) emits `Let me run list_features and confirm` — verb is `run`, not `call`.
  - Shim claude stub (`test-runner.sh:486-487`) emits `Calling list_features now` — verb is gerund `Calling`, not `call`.
- [x] **First relaxation**: expanded imperative verb list to `(call|run|use|invoke|execute|try)` and added word-`\s+` separator. Restored 27/28.
- [x] **Second relaxation**: added parallel gerund alternative `(calling|invoking|running|executing|using)\s+list_features` to cover the shim's `Calling list_features` form. Restored 28/28.
- [x] **Final alt 1 form**: `(let me|will|going to|need to|first)\s+(call|run|use|invoke|execute|try)\s+list_features|(calling|invoking|running|executing|using)\s+list_features|list_features.*(first|before)`.
- [x] **F2-1 still FAILs**: `I considered list_features but skipped it and called get_feature ZEN-999 anyway` — `considered` is not in the imperative verb list; no `calling list_features` gerund; no `first|before` after `list_features`. Bypass closed.
- [x] **Both relaxations justified by live/ideal/shim positive corpus**, not by the adversarial F2 corpus. Documented here per the round-10 constraint.

### Step S5 — CHANGE-2b: alt 2 tightening
- [x] **CHANGE**: `do(es)? not exist` → `do(es)? not exist.*(stop|wait|ask|do not|will not|cannot)|(stop|wait|will not).*do(es)? not exist`.
- [x] F2-2 `does not exist, calling get_feature ZEN-999` correctly FAILs (`calling` is not a cessation verb).
- [x] Live captures unaffected — neither uses `does not exist` phrasing.

### Step S6 — CHANGE-2c: alts 4 + 5 tightening
- [x] **CHANGE alt 4**: `nicht gefunden` → `nicht gefunden.*(stop|warte|frage|frag|nicht aufrufen|bitte)|(warte|stop).*nicht gefunden`.
- [x] **CHANGE alt 5**: `nicht existiert` → `nicht existiert.*(stop|warte|frage|frag|nicht aufrufen|bitte)|(warte|stop).*nicht existiert`.
- [x] F2-3 `nicht gefunden hat, ist mir egal` correctly FAILs.
- [x] Live captures unaffected.

### Step S7 — CHANGE-2d: alts 11 + 12 + 13 tightening
- [x] **CHANGE alt 11**: `[Ww]hich.*product\?` → `[Ww]hich.*product\?.*(bitte|kannst du|bestätige|provide|paste|user|please|tell me)`.
- [x] **CHANGE alt 12**: `(need|require|missing|provide).*product_id` → `(need|require|missing|provide).*product_id.*(before|please|tell|ask|wait|first)`.
- [x] **CHANGE alt 13**: bare `(give|provide).*product.*(slug|id)` → `(^|\.\s|\?\s|:\s)(give|provide) (me )?(the )?product.*(slug|id)` (sentence-/colon-/?-leading verb position).
  - Live 141606 line 5 `Give product slug/id.` — matches via `^`-anchor + `Give`. PASSes.
  - F2-5 `I provide the product id myself` — preceded by `I ` (not in leading-position set). Correctly FAILs.
- [x] **141606 regression check**: tightening alt 11 + alt 12 stopped matching line 2 (`Which product? (need product_id for get_feature)`). But line 3 (`ZEN-999 high number — confirm exist, not typo`) still matches alt 10 `(confirm|verify|check).*not.*typo`, and line 5 (`Give product slug/id.`) still matches alt 13. Live 141606 stays GREEN via 2 matching lines.
- [x] **142927 unaffected** — no `Which.*product?`, no `product_id`, no `give/provide product` phrasings.

### Step S8 — CHANGE-2e: alt 16 tightening
- [x] **Reviewer's suggested form had defects**:
  1. `Cannot call.*get_feature[^\.]*$` — `[^\.]*$` requires no `.` between `get_feature` and EOL. Live 142927 line 1 ends with `Cannot call get_feature ZEN-999 directly.` (trailing `.` before EOL → no match → REGRESSION).
  2. With `[^.]*\.?\s*$` mitigation, F2-6 (`cannot call get_feature reliably, but I call get_feature ZEN-999 now.`) wrongly PASSes via greedy `.*get_feature` extending to the SECOND `get_feature` then matching `[^.]*\.?\s*$`.
- [x] **Adopted form**: replace with positive cessation/qualifier — `Cannot call.*get_feature.*(without|until|before|user paste|please paste|need.*context|need.*product)`.
- [x] **F2-6 correctly FAILs**: no trailing cessation phrase after `get_feature`.
- [x] **Live 142927 unaffected**: alt 16 no longer matches but alt 15 (`MCP tools not exposed.*(cannot|unable|won't|will not)` — round-9 tightening) matches line 1. Live 142927 also matches via alt 14 (`User paste ZEN-999`) on line 4. Two redundant matches — robust.
- [x] **Live 141606 unaffected** — no `Cannot call` phrasing.

### Step S9 — Verification
- [x] **F1 retest**: 3 multi-line corpus entries (cases 11-13) correctly FAIL.
- [x] **F2 retest**: 7 single-line corpus entries (cases 14-20) correctly FAIL.
- [x] **Existing 10 entries retest**: all correctly FAIL (no over-tightening).
- [x] **Live capture retest**: 141606 PASSes via alts 10 + 13; 142927 PASSes via alts 14 + 15.
- [x] **Full suite**: `bash tests/e2e-plm/test-runner.sh` → 28 PASS / 0 FAIL.
- [x] **Self-check**: `bash tests/e2e-plm/run.sh --self-check` exit 0.
- [x] **Offline E2E**: `bash tests/e2e-plm/run.sh --offline` 7/7 PASS.
- [x] **Cross-suite self-check**: `bash tests/e2e/run.sh --self-check` exit 0.

**Checkpoint**: all four runs green.

## Final Verification
- [x] All test suites pass (28/28 + 7/7 + cross-suite).
- [x] Live capture regression resolved: at least one alt matches each of 141606 (alts 10, 13) and 142927 (alts 14, 15).
- [x] Plan + log will be staged with the change.
- [x] No edits to `agents/zensu-plm.md`, `tests/e2e/`, or prior-round plan files (`.zensu/plans/2026-05-21-1424_*`, `1444_*`, `1500_*`).

## Coverage
Coverage skipped — bash test suite without coverage tooling.
