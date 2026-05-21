# TDD Plan: Repo English-only Cleanup + Convention Memorialization

## Context

User identified German-language content in the recent `tests/e2e-plm/` harness work
(prompts, pattern alternations, ideal-capture stubs, violating-captures, README
caveat examples) and clarified: **this is an English-only repository**. Strip
all German from forward-facing code/docs, drop the explicit German pattern alts,
delete the `feature-id-guard-german-200525.txt` live-regression fixture, and
record the English-only convention permanently in both `~/.claude/CLAUDE.md`
(global) and a new repo-level `CLAUDE.md` (project).

Historical `.zensu/plans/*.md` + `.zensu/logs/*.log` stay as-is (TDD audit trail).
Forward-facing rounds (round-14 onward) must be English.

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash + grep regex test harness | **Coverage**: SKIPPED (bash test runner has no coverage tooling)

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Update `_LIVE_REGRESSION_EXPECTED_BASENAMES` to caveman-only + flip diagnostic test target. Delete German fixture file. | test-runner.sh | — | [G] | 1 |
| S2 | Feature | Strip German alternations from feature-id-guard.pattern + bootstrap.pattern; translate German strings in test-runner.sh ideal capture + shims + violating-captures; delete obsolete bootstrap-german test. | test-runner.sh + expected/*.pattern | S1 | [G] | 1 |
| S3 | Feature | Translate prompts/*.txt to English. | grep -E '[äöüÄÖÜß]' | S2 | [G] | 1 |
| S4 | Feature | Update tests/e2e-plm/README.md: remove cross-language bullet, add "Language convention" section. | grep -E 'English only' | S3 | [G] | 1 |
| S5 | W | Create repo-level CLAUDE.md at worktree root with English-only convention. | — | S4 | [W] | 1 |
| S6 | W | Append "Repo-specific conventions" section to ~/.claude/CLAUDE.md (global, outside repo, not committed). | — | S5 | [W] | 1 |

### Step S1 — Drop German live-regression fixture + retarget basename diagnostic

- [G] **RED**: Delete `tests/e2e-plm/fixtures/live-regressions/feature-id-guard-german-200525.txt`. With `_LIVE_REGRESSION_EXPECTED_BASENAMES` still listing the deleted file, `test_live_regression_captures_pass_pattern` MUST FAIL with `missing required live-regression fixture(s)`. ALSO `test_live_regression_enforces_expected_basenames_present` will FAIL because it copies the now-nonexistent German fixture as scaffold — this validates we need to retarget the diagnostic test too.
- [G] **IMPL**: Update `_LIVE_REGRESSION_EXPECTED_BASENAMES` to single entry `("feature-id-guard-caveman-200525.txt")`. Retarget `test_live_regression_enforces_expected_basenames_present` to scaffold an EMPTY live-regressions dir (no copies needed) and assert the helper names the caveman basename as missing.
- [G] **GREEN**: Both `test_live_regression_*` tests PASS.

### Step S2 — Strip German from patterns and test-runner.sh

- [G] **RED**: Edit `expected/feature-id-guard.pattern` to remove German alternations: drop `nicht gefunden.*(stop|warte|frage|frag|nicht aufrufen|bitte)|(warte|stop).*nicht gefunden`, drop `nicht existiert.*(stop|warte|frage|frag|nicht aufrufen|bitte)|(warte|stop).*nicht existiert`, drop `(kannst du|bitte|user.*).*bitte bestätige`, replace `welche.*\?.*(bitte|kannst du|bestätige|provide|paste|user|please)` with English-only equivalent (the `[Ww]hich.*product\?` line already covers Which-product; this alt can be removed), strip German tokens from `[Ww]hich.*product\?.*(bitte|kannst du|bestätige|provide|paste|user|please|tell me)` leaving `(provide|paste|user|please|tell me)`. Revert bootstrap.pattern line 6 to `(component|Components?)`. Multiple existing tests MUST FAIL: `test_bootstrap_pattern_accepts_german_komponente` (intended — bootstrap pattern no longer accepts Komponente), `test_shipped_patterns_pass_against_ideal_capture` (ideal capture says `please bestätige`), `test_end_to_end_with_shim_claude` (shim emits `please bestätige`), `test_feature_id_guard_rejects_silent_get_feature_call` (multiple German-bearing violating captures now lack any matching alt to detect violations — wait, no, they're DESIGNED to FAIL the pattern, but our concern is that some German captures contain anchor matches that we just removed, so they may now wrongly PASS through the per-line negative-assert-free pattern; actually pattern is positive-only — wait, let me re-check). [Test verification on RED is the validating step.]
- [G] **IMPL**: Translate German strings in test-runner.sh: lines 405, 496 (`please bestätige welche Feature-ID gemeint ist.` → `please confirm which feature-id you mean.`), lines 703-705 (bootstrap ideal capture German Komponente lines → English Component lines), lines 715/737 FAIL messages drop `/Komponente` and `German-only Komponente vocabulary`. Translate violating_captures German entries (lines 778-789) per spec. Delete `test_bootstrap_pattern_accepts_german_komponente` function + its registration. Test count drops to 34.
- [G] **GREEN**: All 34 remaining tests in test-runner.sh PASS.

### Step S3 — Translate prompts/*.txt to English

- [G] **RED**: Verify `grep -rE '[äöüÄÖÜß]' tests/e2e-plm/prompts/` currently returns matches (German chars present). No automated test currently asserts prompt content, but we use the grep itself as the failing assertion: BEFORE translation grep returns rc=0 (matches found), AFTER translation grep returns rc=1 (no matches).
- [G] **IMPL**: Translate 5 German prompts (bootstrap, ghost-scan, security-review, implement, pulse-session) to English per spec. Verify `feature-id-guard.txt` ("Bitte implementiere ZEN-999.") and `status-transition.txt` ("Bitte setze den Status von ZEN-001 auf 'released'. Wie machst du das genau?") — also German. Translate all 7.
- [G] **GREEN**: `grep -rE '[äöüÄÖÜß]' tests/e2e-plm/prompts/` returns rc=1 (no German chars in any prompt).

### Step S4 — Update README.md

- [G] **RED**: Verify `grep -F 'cross-language' tests/e2e-plm/README.md` matches (the cross-language bullet exists). Verify `grep -F 'English only' tests/e2e-plm/README.md` returns rc=1 (no English-only section yet).
- [G] **IMPL**: Remove line 221 cross-language bullet (`Ich werde list_features first aufrufen. Stattdessen get_feature ZEN-999.`), update the surrounding "Multi-line walk-back" bullet list to keep only English examples. Add "Language convention" section near top stating English-only.
- [G] **GREEN**: `grep -F 'cross-language' tests/e2e-plm/README.md` returns rc=1; `grep -F 'English only' tests/e2e-plm/README.md` returns rc=0. Also `test_known_caveats_documents_same_line_juxtaposition` STILL passes (substring assertions for that test must remain intact).

### Step S5 — Create repo-level CLAUDE.md  [W]

- [W] **WIRE**: Create `/Users/marcelkarras/IdeaProjects/dev.zensu/zensu-claude-code/.claude/worktrees/upbeat-lewin-ccebed/CLAUDE.md` with English-only convention. Verify `grep -q "English only" CLAUDE.md` returns rc=0.

### Step S6 — Update global ~/.claude/CLAUDE.md  [W]

- [W] **WIRE**: Append "Repo-specific conventions" section to `~/.claude/CLAUDE.md`. NOT committed (outside repo). Verify `grep -q "zensu-claude-code" ~/.claude/CLAUDE.md` returns rc=0.

**Checkpoint**: All of the following must hold:
- `bash tests/e2e-plm/test-runner.sh` → 34/34 PASS
- `bash tests/e2e-plm/run.sh --self-check` → exit 0
- `bash tests/e2e-plm/run.sh --offline` → 7/7 PASS (caveman fixture still loads via existing alts; live captures still PASS via remaining English alts)
- `bash tests/e2e/run.sh --self-check` → exit 0 (cross-suite untouched)
- `grep -rE '[äöüÄÖÜß]|\bwelche\b|\bbitte\b|\bkannst du\b|nicht gefunden|nicht existiert|Komponente|bestätige' tests/e2e-plm/expected/ tests/e2e-plm/prompts/ tests/e2e-plm/fixtures/live-regressions/ tests/e2e-plm/README.md tests/e2e-plm/run.sh tests/e2e-plm/test-runner.sh tests/e2e-plm/setup-fixtures.sh CLAUDE.md` → empty (rc=1)

## Final Verification
- [G] All test suites pass — `tests/e2e-plm/test-runner.sh` 34/34, `tests/e2e-plm/run.sh --self-check` exit 0, `tests/e2e-plm/run.sh --offline` 7/7 PASS, `tests/e2e/run.sh --self-check` exit 0.
- [G] All forward-facing German content removed — comprehensive grep `[äöüÄÖÜß]|\bwelche\b|\bbitte\b|\bkannst du\b|nicht gefunden|nicht existiert|Komponente|bestätige|WAS wird|WIE wird|WO steht` returns rc=1 across `tests/e2e-plm/expected/`, `tests/e2e-plm/prompts/`, `tests/e2e-plm/fixtures/live-regressions/`, `tests/e2e-plm/README.md`, `tests/e2e-plm/run.sh`, `tests/e2e-plm/test-runner.sh`, `tests/e2e-plm/setup-fixtures.sh`, `CLAUDE.md`, `README.md`.
- [W] CLAUDE.md (repo) created with English-only convention at worktree root.
- [W] ~/.claude/CLAUDE.md (global) appended with `Repo-specific conventions` section referencing zensu-claude-code path.

## Commit Hygiene Plan (post-implementation)

Round-14 sequences the staged working tree into focused, reviewable commits. The original 6-commit plan (C1–C6) is amended after the post-implementation code review which surfaced three residual issues (two in `tests/e2e-plm/README.md`, one in the project-root `README.md`). The two e2e-plm README fixes (stale German fixture references in the layout block and worked example) fold into the existing planned C4 because they belong to the same "translate e2e-plm prompts/README to English" diff. The root-README German parentheticals are outside the e2e-plm scope and become a new C7.

- C1 — `test(e2e-plm): retarget live-regression basename diagnostic to caveman-only`
- C2 — `test(e2e-plm): drop German fixture from live-regression corpus`
- C3 — `test(e2e-plm): strip German alternations from feature-id-guard and bootstrap patterns`
- C4 — `docs(e2e-plm): translate prompts to English, drop cross-language README bullet` (amended to also fix the live-regression layout block + worked-example fixture name)
- C5 — `chore: add repo-level CLAUDE.md English-only convention`
- C6 — `docs(e2e-plm): record round-14 plan and execution log`
- C7 — `docs: translate root README German parentheticals to English` (NEW — residual ASCII-only German that umlaut-grep audit missed)
