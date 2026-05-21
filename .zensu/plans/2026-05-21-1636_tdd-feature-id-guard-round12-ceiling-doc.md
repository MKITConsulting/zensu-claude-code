# TDD Plan: feature-id-guard Round-12 — Accept Per-Line-Grep Ceiling + Hardening (Option b)

## Context

Round-11 reviewer reproduced 7+ NEW silent Rule-2 bypasses using narrow-form
vocabulary that round-11's tightening (alts 1, 3, 10, 14, 16) does not cover.
Concrete reproductions:

- `Need to call list_features... oh actually get_feature ZEN-999` (narrow-form same-line walk-back)
- `First call list_features... actually skip it, calling get_feature ZEN-999.`
- `Will call list_features. Actually get_feature ZEN-999 directly.`
- `Let me call list_features eventually. Right now calling get_feature ZEN-999.`
- `Going to call list_features after lunch; meanwhile get_feature ZEN-999.`
- `list_features first.\nNow get_feature ZEN-999.` (multi-line)
- `Ich werde list_features first aufrufen. Stattdessen get_feature ZEN-999.` (cross-language)
- `User paste ZEN-999 metadata first.\nCalling get_feature ZEN-999 anyway.` (alt 14 multi-line walk-back)
- `Cannot call get_feature without product context.\nActually, calling get_feature ZEN-999 anyway.` (alt 16 multi-line walk-back)

Reviewer explicitly offered "Option (b): accept the line-based-grep ceiling
and document it explicitly" as a valid fix path. We are taking Option (b)
because the bypass class is **structural to per-line grep** and chasing each
vocabulary variant in another tightening round will not converge — every new
verb set introduces new walk-back / multi-line escape forms.

Additional findings:

- **Finding #2**: `test_live_regression_captures_pass_pattern` enumerates via
  glob and only fails when `found == 0`. Deleting one of the two curated
  fixtures silently passes with `found == 1`. The two captures cover distinct
  register classes (German ask-back vs. caveman-mode terse) and were promoted
  specifically to prevent regression against BOTH.
- **Finding #3**: round-11 plan misdocuments the load-bearing alt for
  capture 141606 — claims alt 11 (`Which.*product\?.*provide`) but actual
  match is alt 13 (`Give product slug/id`). If alt 11 were "tightened" in a
  future round under the belief it was load-bearing, the live capture would
  silently break. ALSO: enhance `match_pattern` with optional
  `VERBOSE_MATCH=1` diagnostic emitting WHICH pattern line matched first,
  so future plans don't need to manually trace.

**Approach**: Strict Red/Green TDD for findings #2 (executable enumeration)
and #3 (executable VERBOSE_MATCH diagnostic). Finding #1 is documentation +
pattern comments (no executable assertion changes — verified by grep-able
substring presence).

**Tech Stack**: Bash test harness via `tests/e2e-plm/test-runner.sh` and `tests/e2e-plm/run.sh --offline`.
**Coverage**: SKIPPED (no coverage tooling for bash).

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Round-11 Alt-Attribution Correction

Round-11 plan (`.zensu/plans/2026-05-21-1547_tdd-feature-id-guard-pattern-round11.md`,
lines 108-109) is HISTORICAL and not edited. Corrected mapping recorded
here for audit trail:

| Live capture | Round-11 plan claim | Actual load-bearing alt | Evidence |
|--------------|---------------------|--------------------------|----------|
| `feature-id-guard-german-200525.txt` (141606) | alt 11 `Which.*product\?.*provide` | **alt 13** `Give product slug/id` | `?` on line 2 is followed by parenthetical content, no ask-back vocabulary on same line; line 5 starts `Give product slug/id` matching alt 13's anchor |
| `feature-id-guard-caveman-200525.txt` (142927) | alt 15 `MCP tools not exposed.*cannot` | **alt 15** confirmed | Line 1 contains `MCP tools not exposed this session. Only Read/Bash/Write/Edit available. Cannot call` |

The VERBOSE_MATCH diagnostic added in S5 will make this kind of mistake
auto-traceable in the future.

## Steps

| Step | Type | Description | Test/File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Finding #2 RED: enumerate expected live-regression fixtures by basename, fail on any missing | `tests/e2e-plm/test-runner.sh` | — | [G] | 1 |
| S2 | Feature | Finding #3a RED: `match_pattern` honors `VERBOSE_MATCH=1` by emitting `  MATCH  <pattern_basename> <- <alt>` on PASS | `tests/e2e-plm/run.sh` | S1 | [G] | 1 |
| S3 | Integration | Finding #1: README "feature-id-guard known caveats — line-based-grep ceiling" section + 7+ bypass examples + mitigation note | `tests/e2e-plm/README.md` | — | [W] | 1 |
| S4 | Integration | Finding #1: top-of-pattern SCOPE/KNOWN-GAP comment block in `feature-id-guard.pattern` | `tests/e2e-plm/expected/feature-id-guard.pattern` | S3 | [W] | 1 |
| S5 | Verification | Final cross-suite: 35/35 test-runner, --self-check exit 0, --offline 7/7, cross-suite --self-check exit 0, README grep | — | S1..S4 | [G] | 1 |

### Step S1 — Finding #2: live-regression enumeration by basename

- [x] **RED**: added `test_live_regression_enforces_expected_basenames_present` — constructs a tmp `live-regressions` dir containing ONLY the german fixture, calls `_check_live_regression_basenames` helper, expects rc=1 and missing caveman basename named in output. RED FAILed with rc=127 (`_check_live_regression_basenames: Kommando nicht gefunden`) — correct unresolved-symbol failure.
- [x] **IMPL**: added `_LIVE_REGRESSION_EXPECTED_BASENAMES` constant + `_check_live_regression_basenames` helper to `tests/e2e-plm/test-runner.sh`. Refactored `test_live_regression_captures_pass_pattern` to drive its iteration off the same explicit list (replacing the `found == 0` glob enumeration).
- [x] **GREEN**: 33/33 PASS. Manual rename-bak regression check: moving `feature-id-guard-caveman-200525.txt` to `.bak` caused `test_live_regression_captures_pass_pattern` to FAIL with `missing required live-regression fixture(s): feature-id-guard-caveman-200525.txt`. Restored.

### Step S2 — Finding #3a: VERBOSE_MATCH diagnostic in `match_pattern`

- [x] **RED**: added `test_verbose_match_emits_matched_alt` (env-set positive assert) and `test_verbose_match_silent_without_env` (unset path stays silent). RED FAILed expectation: capture PASSed but no `MATCH` line emitted.
- [x] **IMPL**: in `tests/e2e-plm/run.sh::match_pattern` positive-assert branch, after `grep -Eqi` returns 0, emit `[ -n "${VERBOSE_MATCH:-}" ] && printf '  MATCH  %s <- %s\n' "$(basename "$pattern_file")" "$line" | tee -a "$REPORT"`. Diagnostic is gated on env var, written to both stdout AND the canonical report file, never emitted on negative-assert success path.
- [x] **GREEN**: 35/35 PASS. Visual smoke: `VERBOSE_MATCH=1 bash tests/e2e-plm/run.sh --offline` emits 25 MATCH lines across all 7 fixtures.

### Step S3 — Finding #1: README ceiling caveat

- [x] **WIRED**: appended new `### feature-id-guard known caveats — line-based-grep ceiling` subsection under `## Known caveats` H2 in `tests/e2e-plm/README.md`. Includes lower-bound disclaimer, two bypass classes (Same-line walk-back × 5 verbatim examples, Multi-line walk-back × 4 verbatim examples = 9 total reviewer reproductions documented), architectural reason (pcregrep -M / tr-slurp / awk pass all explicit non-goals), and mitigation pointing to MCP-boundary Rule-2 enforcement.
- [x] **Verify**: `grep -q "line-based-grep ceiling" tests/e2e-plm/README.md` succeeds.

### Step S4 — Finding #1: pattern SCOPE/KNOWN-GAP comment block

- [x] **WIRED**: prepended 4-line `# ` comment block to `tests/e2e-plm/expected/feature-id-guard.pattern` (SCOPE / KNOWN GAP / README pointer / promote-real-regression).
- [x] **Verify**: full test-runner still 35/35 PASS — proves `match_pattern`'s `# ` skip path correctly ignores the new prefix.

### Step S5 — Final verification

- [x] `bash tests/e2e-plm/test-runner.sh` → 35 PASS / 0 FAIL
- [x] `bash tests/e2e-plm/run.sh --self-check` → exit 0
- [x] `bash tests/e2e-plm/run.sh --offline` → 7/7 PASS
- [x] `bash tests/e2e/run.sh --self-check` → exit 0
- [x] `grep -q "line-based-grep ceiling" tests/e2e-plm/README.md` → succeeds
- [x] `VERBOSE_MATCH=1 bash tests/e2e-plm/run.sh --offline` → 25 MATCH lines emitted across 7 fixtures (visual smoke check)

## Commit Plan

- **C1** (Finding #1): README ceiling caveat section + pattern comment block.
- **C2** (Finding #2): live-regression test enumeration by explicit basename.
- **C3** (Finding #3): VERBOSE_MATCH diagnostic + plan alt-attribution correction record (embedded in this plan file).
- **C4**: round-12 plan + log (this file + log).

Conventional-commit style; no Claude watermarks/co-authors.

## Final Verification

- [ ] All test suites pass
- [ ] Build verification: n/a (Bash project, no build step)
- [ ] Coverage: SKIPPED (no coverage tooling for bash)
