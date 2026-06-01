# TDD Plan: De-stale release-sync structure tests

## Context
Two structure tests hardcode `EXPECTED_VERSION="0.4.0"` and assert plugin.json/marketplace.json version, README badge `version-${EXPECTED_VERSION}-green`, and CHANGELOG heading `## [${EXPECTED_VERSION}] - 2026-05-30` (date ALSO hardcoded). They go red on every release after 0.4.0 (already red at 0.4.1; red at 0.4.2 on this branch). Files: tests/structure/test-reset-review-limit-skill.sh, tests/structure/test-zensu-help-skill.sh. Bundled onto the 0.4.2 log-anchor branch. Make them self-tracking + green at 0.4.2.

**Approach**: Strict Red/Green TDD (Bug Fix — the two structure suites ARE the test: red now, green after) | **Tech Stack**: Bash, self-contained structure tests | **Coverage**: SKIPPED — shell scripts, no per-file tool (default-90%-WAIVED)

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| jq | CLI | `command -v jq` | present (1.7.1) | — |

No missing preconditions.

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| T1 | Bug Fix | Derive EXPECTED_VERSION from plugin.json + version-aware CHANGELOG-date check in both tests; bump README badge to 0.4.2 | tests/structure/test-reset-review-limit-skill.sh, tests/structure/test-zensu-help-skill.sh | — | [G] | 1 |
| T2 | Integration | CLAUDE.md "Version Bumps" checklist: add README badge step | — | T1 | [W] | — |

### Step T1 — De-stale the pins (Bug Fix)
- [x] **RED**: run both structure tests at current state -> FAIL (EXPECTED_VERSION=0.4.0 != plugin 0.4.2; reproduces the drift bug)
- [x] **GREEN**: in BOTH test files, set `EXPECTED_VERSION="$(jq -r '.version' "$PLUGIN_JSON")"`; change CHANGELOG-date assertion to version-aware regex `^## \[<ver>\] - [0-9]{4}-[0-9]{2}-[0-9]{2}` (escape dots in ver); bump README badge to `version-0.4.2-green`. Re-run both -> PASS.

**Checkpoint**: both target tests pass; full structure suite shows only the 2 pre-existing ambient hook fails.

### Step T2 — CLAUDE.md checklist [W]
- [x] **WIRE**: add "README.md version badge" as an explicit step in the "Version Bumps" / Release commit checklist.

## Final Verification
- [x] test-reset-review-limit-skill.sh GREEN
- [x] test-zensu-help-skill.sh GREEN
- [x] log-anchor test + gitignore test still GREEN (bundle undisturbed)
- [x] full suite: only test-post-bash-witness + test-pre-edit-hook-mirror remain (pre-existing ambient)
- [x] Coverage: SKIPPED (shell)
