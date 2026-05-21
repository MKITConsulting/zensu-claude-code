# TDD Plan: Live-Run Pattern Brittleness Fixes

## Context

Live-run of `bash tests/e2e-plm/run.sh` produced 5/7 PASS with 2 FAILs, both
pattern-brittleness, not agent bugs. Both finding agents demonstrated correct
behavior — only the probes were too narrow.

**Finding 1** — `expected/bootstrap.pattern:4` probe `(component|Components?)`
is English-only. Live agent decomposed into "Komponente Time-Capture",
"Komponente Reporting", "Komponente Invoicing" — substantive workflow is
correct, but probe doesn't tolerate German vocabulary.
- Evidence: `results/bootstrap-20260521-141606.captured.txt` contains 3 `Komponente` / 0 `component`.
- Fix: widen to `(component|Components?|Komponente[n]?)`. Tolerate German
  singular `Komponente`, plural / dative `Komponenten`. Backward-compatible
  with English corpus.

**Finding 2** — `expected/feature-id-guard.pattern:3` alternation is too
narrow. Live agent flagged ZEN-999 + asked for product_id but its phrasing
("confirm exist, not typo", "Which product?", "Give product slug/id") slipped
through every alternative.
- Evidence: `results/feature-id-guard-20260521-141606.captured.txt` shows
  textbook Rule-2 compliance the probe doesn't recognise.
- Fix: extend alternation with `confirm.*exist`, `not.*typo`,
  `[Ww]hich.*product`, `product_id`, `product.*slug`, `Give.*product`.

**Approach**: Strict Red/Green TDD | **Tech Stack**: Bash test harness via `tests/e2e-plm/test-runner.sh` and `tests/e2e-plm/run.sh --offline` | **Coverage**: SKIPPED (no coverage tooling for bash)

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| 1 | Bug Fix | Bootstrap pattern accepts German `Komponente`/`Komponenten` | `tests/e2e-plm/test-runner.sh` | — | [G] | 1 |
| 2 | Bug Fix | Feature-id-guard pattern accepts realistic ask-back phrasings | `tests/e2e-plm/test-runner.sh` | — | [G] | 1 |
| 3 | Bug Fix | Feature-id-guard also accepts "paste ZEN-XXX details" / "MCP tools not exposed" / "Cannot call get_feature" (live-discovered third compliance signal) | `tests/e2e-plm/test-runner.sh` | 1, 2 | [G] | 1 |

### Step 1 — Bootstrap pattern accepts German vocabulary [G]

- [x] **RED-REPRO**: New test
  `test_bootstrap_pattern_accepts_german_komponente` fed a synthetic
  capture containing the four required tool names + `Komponente`
  vocabulary (no English `component`) and expected PASS against the
  shipped pattern. RED achieved — runner produced `FAIL bootstrap` because
  `Komponente` is not matched by `(component|Components?)`.
  Also added a negative discrimination test
  `test_bootstrap_pattern_rejects_capture_without_any_component_word`
  that feeds a capture with neither variant; it PASSed on the narrow probe
  (confirming current probe catches absent decomposition) and continues to
  PASS after widening — guards regression.
- [x] **FIX**: Updated `expected/bootstrap.pattern:4` from
  `(component|Components?)` to `(component|Components?|Komponente[n]?)`.
- [x] **GREEN**: `bash tests/e2e-plm/test-runner.sh` — both new tests
  PASS. `bash tests/e2e-plm/run.sh --offline` — bootstrap fixture PASSes
  against the live 141606 capture.

**Checkpoint**: `tests/e2e-plm/test-runner.sh` 100% pass; offline bootstrap PASS.

### Step 2 — Feature-id-guard pattern accepts realistic ask-back phrasings [G]

- [x] **RED-REPRO**: New test
  `test_feature_id_guard_accepts_which_product_phrasing` fed a synthetic
  capture containing only "Which product?" + "ZEN-999 confirm exist, not
  typo" + "Give product slug/id" (no `list_features`, no German). RED
  achieved — `FAIL feature-id-guard` on the narrow alternation.
  Also added a negative discrimination test
  `test_feature_id_guard_rejects_silent_get_feature_call` that feeds a
  capture where the agent silently does `get_feature(ZEN-999)` with no
  ask-back; it PASSed on the narrow probe (rejection-as-expected) and
  continues to PASS after widening — confirms the widened alternation
  still triggers Rule-2's negative case.
- [x] **FIX**: Updated `expected/feature-id-guard.pattern:3` adding six
  alternatives: `confirm.*exist`, `not.*typo`, `[Ww]hich.*product`,
  `product_id`, `product.*slug`, `Give.*product`.
- [x] **GREEN**: `bash tests/e2e-plm/test-runner.sh` 27/27 PASS incl.
  `test_shipped_patterns_reject_bad_captures` which still rejects the
  silent `get_feature(ZEN-999)` violation. `bash tests/e2e-plm/run.sh
  --offline` 7/7 PASS against the 141606 captures.

**Checkpoint**: `tests/e2e-plm/test-runner.sh` 100% pass; offline 7/7 PASS.

### Step 3 — Feature-id-guard accepts "paste"/"MCP tools not exposed" (live-discovered third signal) [G]

- [x] **DISCOVERY**: The single budgeted live `bash tests/e2e-plm/run.sh`
  run produced a NEW feature-id-guard capture with a third valid Rule-2
  compliance phrasing the originally-widened probe still missed: agent
  said "MCP tools not exposed this session. Cannot call get_feature
  ZEN-999 directly. Options: 1. User paste ZEN-999 feature details
  (status, security classification). 2. Run zensu CLI via Bash...". This
  is genuine Rule-2 compliance (agent refuses to invent feature data and
  asks the user to paste it) but slips through the widened probe.
- [x] **RED-REPRO**: New test
  `test_feature_id_guard_accepts_paste_details_phrasing` feeds a synthetic
  capture with exactly this phrasing and expects PASS. RED achieved —
  `FAIL feature-id-guard`.
- [x] **FIX**: Updated `expected/feature-id-guard.pattern:3` adding three
  more alternatives: `paste.*ZEN`, `MCP tools not exposed`,
  `Cannot call.*get_feature`. Final probe contains 16 alternatives total.
- [x] **GREEN**: `bash tests/e2e-plm/test-runner.sh` 28/28 PASS;
  `bash tests/e2e-plm/run.sh --offline` 7/7 PASS against the newest
  142927 captures (offline picks newest per fixture). The silent-violation
  negative case still FAILs because none of the three new alternatives
  appear in the bad-capture fixture.

**Checkpoint**: `tests/e2e-plm/test-runner.sh` 28/28 pass; offline 7/7 PASS against the freshly-captured live run.

## Final Verification
- [x] `bash tests/e2e-plm/test-runner.sh` 28/28 PASS (5 new discrimination tests added: 2 bootstrap, 3 feature-id-guard)
- [x] `bash tests/e2e-plm/run.sh --self-check` exit 0
- [x] `bash tests/e2e-plm/run.sh --offline` 7/7 PASS (against 142927 captures from the single live run)
- [x] `bash tests/e2e/run.sh --self-check` exit 0
- [x] One live `bash tests/e2e-plm/run.sh` was executed. It revealed a third
  Rule-2 compliance phrasing (live capture differed structurally from the
  original 141606 capture). Step 3 widened the probe to accept it; final
  offline 7/7 confirms the patterns now tolerate both live captures
  produced by the agent in this session.
