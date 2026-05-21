# TDD Plan: e2e-plm review fixes round 5

## Context

Two deferred-suggestion follow-ups from the round-4 review, applied verbatim per user request:

1. `tests/e2e-plm/test-runner.sh:686-706` — `test_known_caveats_documents_same_line_juxtaposition` is only partially discriminative for example phrasings. The OR chain at lines 696-699 requires only ONE of the four documented adversarial phrasings to be present. A future maintainer trimming the README to keep just one example would still pass the test, even though the round-3 review specifically enumerated four phrasings worth preserving. Fix: tighten to AND across all four required substrings, with per-substring diagnostics so future maintainers know which example was dropped. Required substrings (case-sensitive `grep -F`):
   - `update_feature taking status=`
   - `update_feature accepting parameter status=`
   - `tool: update_feature` (YAML fragment)
   - `update_feature status=released` (bare juxtaposition)

2. `.zensu/plans/2026-05-21-0002_tdd-e2e-plm-review-fixes-round4.md:39, 50, 57` — Plan-doc accounting drift. The round-4 plan claims "6 reference plan+log files" still NOT IGNORED. Actual count post-round-4 is 8 (4 plans + 4 logs, including this round's own plan and log). Update the three "6" mentions to "8". Plan-doc is a historical record so no automated test is needed.

**Approach**: Strict Red/Green TDD for F1; doc fix-up with grep-c verification for W1 | **Tech Stack**: Bash 5+, POSIX shell | **Coverage**: SKIPPED — shell tests have no coverage tool wired (no project default for shell); harness exists as e2e instead.

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type    | Description                                                                                       | Test File                       | Depends On | Status | Attempts |
|------|---------|---------------------------------------------------------------------------------------------------|---------------------------------|------------|--------|----------|
| F1   | Refactor | Tighten `test_known_caveats_documents_same_line_juxtaposition` OR-chain to AND-chain + per-substring FAIL diagnostics | tests/e2e-plm/test-runner.sh    | -          | [G]    | 1        |
| W1   | Wired   | Fix accounting drift in round-4 plan (3x "6" -> "8")                                              | -                               | -          | [W]    | 1        |

### Step F1 — Tighten same-line-juxtaposition caveat test

- [x] **RED (characterization)**: Dropped `update_feature taking status=` line from README. With current OR-chain, test PASSED — confirming the bug (OR-chain is too permissive; one of four phrasings was sufficient to satisfy the OR fallthrough).
- [x] **CHANGE**: Converted the OR chain to AND chain with 4 independent `grep -qF` checks, each accumulating to `$missing` on its own miss. Substrings:
  - `update_feature taking status=` → diagnostic token `example-taking-status`
  - `update_feature accepting parameter status=` → diagnostic token `example-accepting-parameter-status`
  - `tool: update_feature` (YAML fragment) → diagnostic token `example-yaml-tool-line`
  - `update_feature status=released` (bare juxtaposition) → diagnostic token `example-bare-juxtaposition`
- [x] **RED (verification)**: With AND chain in place, dropped `update_feature taking status=` line. Test FAILED with diagnostic naming exactly `example-taking-status`. Multi-drop test confirmed: 3 missing phrasings yield 3 independent diagnostic tokens in the FAIL line.
- [x] **GREEN**: Restored README from backup. Full `test-runner.sh` 23/23 PASS (test count unchanged per spec; same test, tightened).

### Step W1 — Round-4 plan accounting drift

- [x] **PRE-CHECK**: `grep -c "6 reference\|all 6"` returned 3. Found at lines 39, 48, 57 (the spec's "line 50" is off-by-2 — actual line is 48; line 50 in the spec maps to the file's actual line 48).
- [x] **WIRE**: Replaced each of the three "6" mentions with "8". Also updated the adjacent "(3 plans, 3 logs)" → "(4 plans, 4 logs)" at line 39 to keep the parenthetical numerically consistent with the new total (post-round-4 reality: 4 plans + 4 logs = 8).
- [x] **POST-CHECK**: `grep -c "6 reference\|all 6"` returns 0; `grep -c "8 reference\|all 8"` returns 3. Spec-verified count of 8 represents the post-round-4 snapshot (round-1+2+3+4 plans+logs); current `git ls-files --others --exclude-standard | grep ^.zensu/ | wc -l` returns 10 because round-5's plan+log are not yet committed — this is expected drift and is itself a separate future-round concern not in scope.

**Checkpoint**: `bash tests/e2e-plm/test-runner.sh` shows 23 PASS / 0 FAIL.

## Final Verification

- [x] `bash tests/e2e-plm/test-runner.sh` exits 0 with 23/23 PASS
- [x] `bash tests/e2e-plm/run.sh --self-check` exits 0
- [x] `bash tests/e2e/run.sh --self-check` exits 0
- [x] `agents/zensu-plm.md` and `tests/e2e/` UNCHANGED (verified via `git diff main..HEAD` and working-tree `git diff`)
- [ ] Plan + log committed (project-artifact rule) — staged for follow-up commit
