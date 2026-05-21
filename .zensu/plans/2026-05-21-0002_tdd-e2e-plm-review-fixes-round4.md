# TDD Plan: e2e-plm review fixes round 4

## Context

Three deferred-suggestion follow-ups from the round-3 review, applied verbatim per user request:

1. `tests/e2e-plm/README.md` — "Known caveats" entry on cross-line splits is too narrow. Same-line bare-juxtaposition AND YAML-style serialization (4 concrete adversarial phrasings) also escape the 2-probe pattern. Probe-3 was rejected last round for FP risk; the right tradeoff is conservative harness + accurate docs. Add a test that greps the README for required substrings.

2. `.gitignore:42-44` — The 3-line block has 1 valid section header and 2 lines of explanatory prose. Global CLAUDE.md says "NEVER EVER ADD COMMENTS". Trim to the single section header; keep the 4 ignore/negation lines beneath untouched. Verify `git check-ignore -v` still reports the round-1/2/3 plans + logs as NOT IGNORED. No new test (this is a doc-style fix verified by an existing invariant).

3. `tests/e2e-plm/run.sh:61` — WARN diagnostic for empty/whitespace-only negative-assert needles reaches stderr only, not `$REPORT`. The `log()` helper on the same file uses `tee -a "$REPORT"`. Pipe the WARN through `tee -a "$REPORT" >&2` so postmortem analysis of the report file shows the typo. The existing `test_empty_negative_assert_warns_not_fails` / `test_whitespace_only_negative_assert_warns_not_fails` tests assert WARN appears in combined stdout+stderr (`2>&1`), which `tee >&2` still satisfies. Add a new test `test_warn_also_appears_in_report_file` that asserts the WARN line is present in the canonical report file.

**Approach**: Strict Red/Green TDD | **Tech Stack**: Bash 5+, POSIX shell | **Coverage**: SKIPPED — shell tests have no coverage tool wired (no project default for shell); harness exists as e2e instead.

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type    | Description                                                                       | Test File                       | Depends On | Status | Attempts |
|------|---------|-----------------------------------------------------------------------------------|---------------------------------|------------|--------|----------|
| F1   | Feature | README same-line/YAML caveat doc test + README expansion                          | tests/e2e-plm/test-runner.sh    | -          | [G]    | 1        |
| F2   | Feature | run.sh WARN-to-$REPORT test + tee -a "$REPORT" >&2 change                         | tests/e2e-plm/test-runner.sh    | -          | [G]    | 1        |
| W1   | Wired   | .gitignore trim of explanatory prose (lines 43-44); verify check-ignore unchanged | -                               | -          | [W]    | 1        |

### Step F1 — README same-line/YAML caveat documentation test

- [x] **RED**: Test `test_known_caveats_documents_same_line_juxtaposition` greps `tests/e2e-plm/README.md` for the strings `bare juxtaposition`, `same-line`, and `YAML`, plus at least one of the 4 example phrasings (e.g. `update_feature taking status=`). FAILED for the right reason: README missing `bare-juxtaposition`, `YAML`, and example-phrasing substrings.
- [x] **GREEN**: Replaced the cross-line caveat in `tests/e2e-plm/README.md` (lines 150-178) with a 3-shape enumeration (cross-line, same-line bare-juxtaposition, same-line YAML) plus the 4 concrete adversarial phrasings. Also touched the adjacent "Empty negative-assert needles" entry to reflect F2's tee-to-report change. Test passes.

### Step F2 — WARN diagnostic appears in $REPORT file

- [x] **RED**: Test `test_warn_also_appears_in_report_file` runs `run.sh --offline` with an empty `!` needle and asserts the freshly-created `report-*.txt` contains the WARN line. FAILED for the right reason: report file lacked the WARN (current `>&2`-only behavior).
- [x] **GREEN**: Changed `tests/e2e-plm/run.sh:61` from `printf ... >&2` to `printf ... | tee -a "$REPORT" >&2`. Existing two WARN-on-stderr tests still pass — `tee >&2` preserves stderr surface.

### Step W1 — .gitignore comment-prose trim

- [x] **PRE-CHECK**: Pre-change `git check-ignore -q` confirmed all 8 reference files (4 plans, 4 logs) NOT IGNORED.
- [x] **WIRE**: Deleted lines 43-44 (the 2 explanatory comment lines). Section header on line 42 kept; ignore/negation lines on (now) 43-46 kept untouched. Final block:
  ```
  # tdd-manager run artifacts (per-run plans + logs)
  .zensu/*
  !.zensu/plans/
  !.zensu/logs/
  !.zensu/logs/*.log
  ```
- [x] **POST-CHECK**: Re-ran `git check-ignore -q` for all 8 files — still NOT IGNORED. Verbose output shows the negation now matches at `.gitignore:46` (was :48), confirming the 2-line trim landed cleanly.

**Checkpoint**: `bash tests/e2e-plm/test-runner.sh` shows 23 PASS (21 existing + 2 new) / 0 FAIL.

## Final Verification

- [x] `bash tests/e2e-plm/test-runner.sh` exits 0 with 23/23 PASS
- [x] `bash tests/e2e-plm/run.sh --self-check` exits 0
- [x] `bash tests/e2e/run.sh --self-check` exits 0
- [x] `git check-ignore -q` returns non-zero (NOT IGNORED) for all 8 reference plan+log files
- [x] `agents/zensu-plm.md` and `tests/e2e/` UNCHANGED (verified via `git log/diff main..HEAD`)
- [x] Plan + log committed (project-artifact rule) — staged for follow-up commit
