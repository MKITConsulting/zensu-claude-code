# TDD Plan: Lock /zensu:reset-review-limit to current worktree only (0.3.27)

## Context
A user invoked `/zensu:reset-review-limit` in worktree A. The recipe correctly cleared A's counter under `$STATE_DIR`, but the LLM driving the skill took unsolicited follow-up actions outside the recipe (inspecting + clearing sibling worktree `thirsty-elbakyan-eaba92`). Root cause: SKILL.md prose lacked an explicit prohibition against cross-worktree traversal. Fix: add `## Strict Scope` section with 4 bold-NEVER bullets + 1 positive directive (separate invocation per worktree), borrowing the `agents/tdd-manager.md` "Hard Bans" idiom. Two new region-scoped structure asserts (R24 heading, R25 primary prohibition substring) lock the contract. Release bumped 0.3.26 → 0.3.27.

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash structure tests (no test runner per se) | **Coverage**: SKIPPED (shell-asserts on markdown/json — no coverage tool applicable)

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| jq | CLI | `command -v jq` | present | n/a |
| grep | CLI | `command -v grep` | present | n/a |
| bash | CLI | `command -v bash` | present | n/a |

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Add R24 + R25 + bump EXPECTED_VERSION in test-reset-review-limit-skill.sh; add `## Strict Scope` section in SKILL.md | tests/structure/test-reset-review-limit-skill.sh | — | [G] | 1 |
| S2 | Integration | Bump version in plugin.json + marketplace.json + README badge | — | S1 | [W] | 1 |
| S3 | Integration | Add 0.3.27 CHANGELOG section | — | S1 | [W] | 1 |
| S4 | Integration | Bump EXPECTED_VERSION in test-zensu-help-skill.sh | tests/structure/test-zensu-help-skill.sh | S2, S3 | [W] | 1 |

### Step S1 — Strict Scope section + R24/R25 asserts
- [x] **RED**: Added R24 (heading `## Strict Scope` present) and R25 (literal substring `NEVER** run \`git worktree list\``) to test-reset-review-limit-skill.sh + bumped EXPECTED_VERSION to 0.3.27. Test FAILED 6/32 (R24+R25 + 4 version-precondition asserts).
- [x] **GREEN**: Inserted `## Strict Scope` section in SKILL.md between `## Do NOT Use For` and `## Prerequisites` with 4 NEVER bullets + positive directive. R24 + R25 turned green; other version-related fails resolved via S2/S3.

### Step S2 — Version bumps (plugin.json + marketplace.json + README badge)
- [x] Bumped `.claude-plugin/plugin.json` `"version"` 0.3.26 → 0.3.27. Bumped `.claude-plugin/marketplace.json` `plugins[0].version` 0.3.26 → 0.3.27. Bumped README `version-0.3.26-green` → `version-0.3.27-green`.

### Step S3 — CHANGELOG entry
- [x] Inserted `## [0.3.27] - 2026-05-26` section under `## [Unreleased]` with the spec-provided Fixed bullet documenting the scope leak + remediation.

### Step S4 — Help-skill structure-test EXPECTED_VERSION bump
- [x] Bumped test-zensu-help-skill.sh `EXPECTED_VERSION="0.3.26"` → `"0.3.27"`. CHANGELOG date heading test uses `${EXPECTED_VERSION}` substitution + the fixed `2026-05-26` literal, so no separate date bump needed.

**Checkpoint**: `tests/structure/test-reset-review-limit-skill.sh` (32 PASS, was 30) + `tests/structure/test-zensu-help-skill.sh` (17 PASS) + full structure suite zero FAIL. CONFIRMED.

## Final Verification
- [x] `tests/structure/test-reset-review-limit-skill.sh` passes 32/32
- [x] `tests/structure/test-zensu-help-skill.sh` passes 17/17
- [x] Full `tests/structure/*.sh` suite: 0 FAIL (267 PASS across 17 files)
- [x] `jq -r .version .claude-plugin/plugin.json` = `0.3.27`
- [x] `jq -r '.plugins[0].version' .claude-plugin/marketplace.json` = `0.3.27`
- [x] README badge contains `version-0.3.27-green`
- [x] CHANGELOG has `## [0.3.27] - 2026-05-26`
- [x] Manual prose sanity: `grep -A6 '## Strict Scope' SKILL.md` renders correctly (verified — bold-NEVER + inline code backticks render correctly)
