# TDD Plan: CHANGELOG `[Unreleased]` regex end-anchor tightening

## Context

Code review finding: `tests/structure/test-changelog-unreleased-resolver-entries.sh`
lines 22 (grep) and 28 (awk) match `^## \[Unreleased\]` without a `$` end-anchor.
A release-commit transformation that rewrites the heading in-place to
`## [Unreleased] - 2026-05-25` (loose suffix on the same line) would silently
keep the test reporting 8 PASS — the section now describes the new release but
the suffix-matched extractor still treats it as `[Unreleased]`, so the round-3
keyword tracking goes stale without notice.

Fix: anchor both regex sites with `$` so they match exactly `^## \[Unreleased\]$`.
Mutation-verify with a new sub-test that rewrites the heading in a tmpdir copy
of `CHANGELOG.md` and asserts the section-presence check now returns failure.

**Approach**: Strict Red/Green TDD (test-tightening) | **Tech Stack**: bash +
awk + grep structure tests | **Coverage**: SKIPPED (no coverage tool wired for
bash structure tests)

## Preconditions

| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| bash | CLI | `command -v bash` | present | n/a |
| awk | CLI | `command -v awk` | present | n/a |
| grep | CLI | `command -v grep` | present | n/a |
| mktemp | CLI | `command -v mktemp` | present | n/a |
| sed | CLI | `command -v sed` | present | n/a |
| cp | CLI | `command -v cp` | present | n/a |
| `CHANGELOG.md` `## [Unreleased]` heading | fixture | `grep -qE '^## \[Unreleased\]$' CHANGELOG.md` | present | n/a |

No missing preconditions; no AskUserQuestion escalation required.

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Add helper function `has_unreleased_heading()` (single source of truth for the heading regex). Migrate line-22 grep and line-28 awk to use the helper. Add mutation sub-test M1 that copies `CHANGELOG.md` to a tmpdir, rewrites `## [Unreleased]` to `## [Unreleased] - 2026-05-25` in place, calls the helper against the copy, and asserts NON-match. Add helper-defined guard M0 so an undefined-function bug surfaces as FAIL rather than silently routing to PASS via bash's falsy-condition semantics. Helper regex is `^## \[Unreleased\]$` (end-anchored, the fix). Steps are merged because the helper extraction + anchor tightening are technically inseparable for mutation-coupling between M1 and production code | `tests/structure/test-changelog-unreleased-resolver-entries.sh` | – | [G] | 1 |

### Step S1 — RED + IMPL: helper extraction + end-anchor tightening + M1 mutation sub-test

- [x] **RED**: Appended M0 (`type has_unreleased_heading >/dev/null 2>&1` guard) + M1 (mutation sub-test) to the script. M0 + M1 both FAILED because the helper was not yet defined (unresolved-symbol — CORRECT-RED shape). Result: 8 PASS / 2 FAIL, exit 1.
- [x] **IMPL**: Added `has_unreleased_heading() { grep -qE '^## \[Unreleased\]$' "$1"; }` at lines 14-16. Migrated line 26 (formerly line 22) grep to call `has_unreleased_heading "$CHANGELOG"`. Tightened line 33 (formerly line 28) awk regex from `/^## \[Unreleased\]/` to `/^## \[Unreleased\]$/` (end-anchored).
- [x] **GREEN**: Re-ran against unmodified `CHANGELOG.md`. 10 PASS / 0 FAIL, exit 0. Original 8 asserts unaffected; M0 + M1 now PASS.
- [x] **Mutation-verification**: Temporarily reverted the helper regex from `^## \[Unreleased\]$` to `^## \[Unreleased\]` (no `$`). Re-ran: M1 reported FAIL with 9 PASS / 1 FAIL, exit 1 — confirms M1 genuinely couples to the production regex and would catch a regression of the anchor. Restored the end-anchored helper; final 10 PASS / 0 FAIL.

**Checkpoint**: `bash tests/structure/test-changelog-unreleased-resolver-entries.sh` exits 0 with 10 PASS / 0 FAIL. Full 16-file structure suite still 100% green (238 asserts: 236 prior + M0 helper-defined + M1 anchor-rejects-suffix; note this is 238 total, not the 237 named in the spec — the spec undercounted by 1 because mutation-verifiability requires both the helper-existence guard M0 AND the inverted-assertion M1).

## Final Verification

- [x] Helper `has_unreleased_heading()` at lines 14-16 uses `^## \[Unreleased\]$` (end-anchored). Line-26 grep migrated to helper. Line-33 awk regex tightened to `/^## \[Unreleased\]$/`.
- [x] M0 sub-test (helper-defined guard) and M1 sub-test (anchor-rejects-suffix mutation) exist and are mutation-verified: with end-anchored helper, 10 PASS / 0 FAIL exit 0; with helper reverted to loose anchor, M1 FAILS (9 PASS / 1 FAIL exit 1) — coupling proven.
- [x] Original 8 asserts (S0, S1, S2, K×5) still PASS against the unmodified `CHANGELOG.md`.
- [x] Full structure-test suite (16 files) 100% green: 238 PASS / 0 FAIL.
- [x] `.zensu/plans/2026-05-25-1616_tdd-changelog-unreleased-anchor-tightening.md` and `.zensu/logs/2026-05-25-1616_tdd-changelog-unreleased-anchor-tightening.log` saved and ready to stage.
- [x] No version bump in `.claude-plugin/plugin.json` or `.claude-plugin/marketplace.json` (none performed — test-only change).
