# TDD Plan: e2e-plm review fixes round 6

## Context

Round-5 review surfaced ONE actionable finding (suggestions deferred per spec):

**F1** — `tests/e2e-plm/test-runner.sh:699` — The `grep -qF "update_feature status=released"` probe for `example-bare-juxtaposition` is under-discriminative. The substring appears on TWO README lines:

- Line 158 — pedagogical text inside shape #2's explanation: `with no \`(\` and no \`with\`. Example: \`update_feature status=released\`.`
- Line 171 — the enumerated round-3 bullet under "Concrete adversarial phrasings": `` - `update_feature status=released` (bare juxtaposition)``

A maintainer who trims line 171 (the natural duplicate-deletion candidate, since the same code-fenced phrase already appears on line 158) leaves line 158 in place — so the round-5 AND-chain still PASSES, contradicting the round-5 intent that "dropping any of the four enumerated phrasings would FAIL the test naming that example".

Fix (spec's Option a, verbatim): tighten the probe to require the literal `(bare juxtaposition)` parenthetical on the same line as the code-fenced phrase. New probe:

```bash
grep -qF '`update_feature status=released` (bare juxtaposition)' "$readme"
```

This matches only line 171's wording (line 158 ends with `Example: \`update_feature status=released\`.` — period, no parenthetical). Line 158 is preserved per spec (Option b rejected).

**Evidence**: `grep -cF "update_feature status=released" tests/e2e-plm/README.md` → `2` (the bug). The other three probes return `1` each (already specific). Confirmed via direct grep.

**Approach**: Strict Red/Green TDD — RED reproduces the bug (drop line 171, current probe still PASSES), CHANGE tightens the probe, RED-verify (drop line 171 again with the new probe → FAIL naming `example-bare-juxtaposition`), GREEN restores README and full suite goes 23/23.

**Tech Stack**: Bash 5+, POSIX shell (no build step, no compile-time check) | **Coverage**: SKIPPED — no shell-coverage tool wired in this project; e2e harness substitutes.

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type        | Description                                                                                                  | Test File                       | Depends On | Status | Attempts |
|------|-------------|--------------------------------------------------------------------------------------------------------------|---------------------------------|------------|--------|----------|
| F1   | Bug Fix     | Tighten `example-bare-juxtaposition` probe to require literal `(bare juxtaposition)` parenthetical on same line | tests/e2e-plm/test-runner.sh    | -          | [G]    | 1        |

### Step F1 — Tighten `example-bare-juxtaposition` probe

- [x] **RED (bug reproduction)**: Backed up README; deleted line 171 (`  - \`update_feature status=released\` (bare juxtaposition)`) while leaving line 158 intact. Ran `test-runner.sh` → test STILL PASSED (23/23) because the old probe still matched line 158's "Example: \`update_feature status=released\`." text. Under-discrimination bug reproduced verbatim. README restored.
- [x] **CHANGE**: Edited `tests/e2e-plm/test-runner.sh:699` — replaced
  ```bash
  grep -qF "update_feature status=released" "$readme" || missing="$missing example-bare-juxtaposition"
  ```
  with
  ```bash
  grep -qF '`update_feature status=released` (bare juxtaposition)' "$readme" || missing="$missing example-bare-juxtaposition"
  ```
  Single-quoted so the backticks are literal (no command substitution). Only README line 171 matches this exact substring; line 158 (which ends with `Example: \`update_feature status=released\`.`) does not.
- [x] **RED (verification)**: With the tightened probe, repeated the drop-line-171 experiment → test FAILED with `README missing required substrings: example-bare-juxtaposition` (22 PASS / 1 FAIL). Sanity check: dropped line 158 alone (line 171 preserved) → test PASSED 23/23 (probe matches line 171 as intended). README restored.
- [x] **GREEN**: With README pristine, full `test-runner.sh` → **23/23 PASS** (1 attempt). Audit run: each of the 4 enumerated probes now has count=1 in the README, and dropping each bullet individually correctly trips ONLY its own diagnostic token (`example-taking-status`, `example-accepting-parameter-status`, `example-yaml-tool-line`, `example-bare-juxtaposition`). The round-5 promise — "drop each of the 4 README phrasings in turn → test would FAIL each time naming the dropped example" — is now fully achieved.

**Checkpoint**: `bash tests/e2e-plm/test-runner.sh` 23/23 PASS + `bash tests/e2e-plm/run.sh --self-check` exit 0 + `bash tests/e2e/run.sh --self-check` exit 0. All three green.

## Final Verification

- [x] `bash tests/e2e-plm/test-runner.sh` exits 0 with 23/23 PASS
- [x] `bash tests/e2e-plm/run.sh --self-check` exits 0 (TOTAL: 0/0 PASS)
- [x] `bash tests/e2e/run.sh --self-check` exits 0 (TOTAL: 0/0 PASS — cross-suite untouched)
- [x] `agents/zensu-plm.md` and `tests/e2e/` UNCHANGED (`git diff` empty on both paths, both vs. main and working tree)
- [ ] Plan + log committed (project-artifact rule) — staged for follow-up commit

## Audit notes

- **Drop-matrix verification** (Phase 6 audit): With pristine README, ran a 4-iteration drop experiment — dropped each of the four enumerated bullets one at a time and re-ran `test-runner.sh`. Each drop produced exactly 1 FAIL line naming exactly 1 diagnostic token:
  - drop `update_feature taking status=` → `example-taking-status`
  - drop `update_feature accepting parameter status=` → `example-accepting-parameter-status`
  - drop `    tool: update_feature` → `example-yaml-tool-line`
  - drop `` `update_feature status=released` (bare juxtaposition)`` → `example-bare-juxtaposition`
  All four bullets now have grep-F count=1 in the README, so each probe is fully discriminative.
- **Round-5 deferred suggestion** (plan-doc audit reproducibility on `.zensu/plans/2026-05-21-0019_tdd-e2e-plm-review-fixes-round5.md:36`): not part of the auto-fix list; left untouched for a future round per spec.
