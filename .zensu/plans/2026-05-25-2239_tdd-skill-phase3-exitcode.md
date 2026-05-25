# TDD Plan: Phase 3 Verify recipe — exit 0 in both branches

## Context

Code review finding (Round 2/5):

> skills/reset-review-limit/SKILL.md:67-70 — Phase 3 recipe inverts the populated-dir exit code from 0 to 1. The new `find ...` + `[ -z "$(find ...)" ] && echo "(empty, expected)"` form leaves `[` as the last evaluated command when files are present; `[` exits 1, so the whole recipe exits 1 instead of 0. The pre-fix `ls -la ... || echo "(empty, expected)"` returned 0 when files were present (`ls` succeeded). The SKILL.md's own "(exits 0 with a clear message when nothing matches)" promise — and the implicit success contract for the populated branch — are violated. Confirmed across bash/zsh/dash. User-visible impact is limited (Phase 3 is informational, not in a `set -e` chain), but the regression is real and unmentioned in the CHANGELOG.

Fix: Replace the current two-line recipe with a single-find-with-branching form that exits 0 in both branches:

```sh
out="$(find "$STATE_DIR" -maxdepth 1 -name 'rounds-*.json' 2>/dev/null)"
if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "(empty, expected)"; fi
```

Single `find` invocation (cheaper, no double-fork), explicit if/else, exit 0 in both cases. R20 stays green (the `find ... -name 'rounds-*.json'` substring is still in the Phase 3 region). Add a new region-scoped R21 assert in `tests/structure/test-reset-review-limit-skill.sh` that pins the exit-0-in-both-branches contract. Update the existing CHANGELOG 0.3.25 Fixed bullet in place to mention the exit-code-preservation contract too. Do NOT bump version (still 0.3.25).

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash/zsh structure tests | **Coverage**: SKIPPED (shell scripts; tooling not configured)

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| bash | CLI | `command -v bash` | present | n/a |
| zsh | CLI | `command -v zsh` | present | n/a |
| grep | CLI | `command -v grep` | present | n/a |
| sed | CLI | `command -v sed` | present | n/a |
| find | CLI | `command -v find` | present | n/a |

All required tools present — no escalation needed.

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Add R21 region-scoped assert pinning exit-0-in-both-branches contract (if/else form, printf, else echo) | tests/structure/test-reset-review-limit-skill.sh | — | [G] | 1 |
| S2 | Feature | Rewrite Phase 3 recipe in SKILL.md to single-find with if/else | skills/reset-review-limit/SKILL.md | S1 | [G] | 1 |
| S3 | Wire | Extend CHANGELOG 0.3.25 Fixed bullet in place to mention exit-code-preservation contract | CHANGELOG.md | S2 | [W] | 1 |

### Step S1 — RED test pins exit-0 contract (region-scoped)
- [x] **RED**: R21 assert added in `tests/structure/test-reset-review-limit-skill.sh` — failed with `if=0 printf=0 else=0` (assertion mismatch, correct RED reason)
- [x] **GREEN**: After S2 rewrite landed, R21 PASS (28 PASS / 0 FAIL overall)

### Step S2 — Implement the SKILL.md Phase 3 rewrite
- [x] **IMPL**: SKILL.md Phase 3 recipe replaced with `out="$(find …)"; if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "(empty, expected)"; fi` form; prose preamble extended with exit-code-preservation rationale
- [x] **GREEN**: R21 PASS and R20 still PASS (find substring still present)

### Step S3 — Wire CHANGELOG bullet extension
- [x] **IMPL**: 0.3.25 Fixed bullet extended in place with exit-code-preservation contract narrative and R21 mention; no new version, no new bullet

**Checkpoint**: All 3 sibling structure tests GREEN; recipe extracted from SKILL.md exits 0 in BOTH branches under BOTH shells (bash+empty, bash+populated, zsh+empty, zsh+populated — all rc=0).

## Final Verification
- [x] All 3 sibling structure tests pass (28/20/17 PASS)
- [x] Recipe exits 0 in both branches under bash (verified)
- [x] Recipe exits 0 in both branches under zsh (verified)
- [x] Build: n/a (docs + structure test only — no compile step)
- [x] Coverage: SKIPPED (shell scripts; no coverage tool configured)
- [x] mtime discipline: OK (test mtime 1779741639 < impl mtime 1779741678 — test-first)
- [x] Precondition drift: none (all preconditions present, no install/skip decisions)
