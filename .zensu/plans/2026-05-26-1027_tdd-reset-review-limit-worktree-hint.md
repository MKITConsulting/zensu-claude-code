# TDD Plan: Surface fresh-worktree context in /zensu:reset-review-limit (0.3.25 → 0.3.26)

## Context

When a Claude Code session is branched / forked mid-flight (e.g. via `mcp__ccd_session__spawn_task` or by the user manually creating a new worktree off the same project root), the new worktree starts with no `rounds-*.json` counter file under its own `.zensu/state/` directory. If the user then invokes `/zensu:reset-review-limit` to understand or reset the budget state, the current 0.3.25 recipe emits one of two generic no-op messages:

- `Nothing to reset: <STATE_DIR> does not exist`
- `No round counter files in <STATE_DIR>`

Both messages are technically correct but hide the relevant fact: the user is in a fresh worktree, and the counter is effectively at 0 — not because anyone reset it, but because this worktree never had one.

Intended outcome: the skill detects the fresh-worktree scenario via the POSIX-portable `.git`-is-a-file idiom and appends `Fresh git worktree detected — counter effectively at 0, no prior rounds recorded in this worktree.` to the no-op message. Detection is gated to only fire when `STATE_DIR` was resolved via the project-local default (not via `CLAUDE_PLUGIN_DATA_OVERRIDE`). No behavior change in the populated-deletion path. Hook untouched.

**Approach**: Strict Red/Green TDD | **Tech Stack**: Shell (bash/zsh/dash) + jq + POSIX find | **Coverage**: SKIPPED (no coverage tooling for shell scripts)

## Preconditions

| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| jq | CLI | `command -v jq` | present | n/a |
| bash | CLI | `command -v bash` | present | n/a |
| zsh | CLI | `command -v zsh` | present | n/a |
| find | CLI | `command -v find` | present | n/a |
| git | CLI | `command -v git` | present | n/a |

All preconditions present; no escalation needed.

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | R22 asserts SKILL.md Phase 2 contains fresh-worktree hint substring | tests/structure/test-reset-review-limit-skill.sh | — | [G] | 1 |
| S2 | Feature | R23 asserts SKILL.md Phase 2 contains detection idiom + override-gate | tests/structure/test-reset-review-limit-skill.sh | — | [G] | 1 |
| S3 | Feature | Bump EXPECTED_VERSION + CHANGELOG date in test-reset-review-limit-skill.sh | tests/structure/test-reset-review-limit-skill.sh | — | [G] | 1 |
| S4 | Feature | Bump EXPECTED_VERSION + CHANGELOG date in test-zensu-help-skill.sh | tests/structure/test-zensu-help-skill.sh | — | [G] | 1 |
| S5 | Feature | SKILL.md Phase 2 recipe gets worktree detection + appended hint | skills/reset-review-limit/SKILL.md (driven by R22/R23) | S1,S2 | [G] | 1 |
| S6 | Feature | SKILL.md Phase 1 narrative + Phase 2 preamble mention fresh-worktree hint | skills/reset-review-limit/SKILL.md (covered by R3 sections) | S5 | [G] | 1 |
| S7 | Integration | Bump plugin.json version 0.3.25 → 0.3.26 | n/a (R9 covers it) | S3 | [W] | 1 |
| S8 | Integration | Bump marketplace.json version 0.3.25 → 0.3.26 | n/a (R10 covers it) | S3 | [W] | 1 |
| S9 | Integration | Bump README.md version badge 0.3.25 → 0.3.26 | n/a (R12 covers it) | S3 | [W] | 1 |
| S10 | Integration | Append CHANGELOG.md `## [0.3.26] - 2026-05-26` section | n/a (R15 covers it) | S3 | [W] | 1 |

### Step S1 — RED test R22 in test-reset-review-limit-skill.sh

- [x] **RED**: Add R22 assertion to structure test pinning the literal substring `Fresh git worktree detected — counter effectively at 0` inside the Phase 2 region of SKILL.md. Run the test. It MUST FAIL because SKILL.md does not yet contain that substring.
- [x] **GREEN**: Comes via S5 (SKILL.md edit). Will re-verify after S5.

### Step S2 — RED test R23 in test-reset-review-limit-skill.sh

- [x] **RED**: Add R23 assertion to structure test pinning BOTH `[ -f "$WORKTREE_ROOT/.git" ]` (detection idiom) AND `if [ -z "${CLAUDE_PLUGIN_DATA_OVERRIDE:-}" ]` (override-gate) inside the Phase 2 region. Run the test. It MUST FAIL because SKILL.md does not yet contain those substrings.
- [x] **GREEN**: Comes via S5 (SKILL.md edit). Will re-verify after S5.

### Step S3 — RED bump EXPECTED_VERSION to 0.3.26 in test-reset-review-limit-skill.sh

- [x] **RED**: Change `EXPECTED_VERSION="0.3.25"` to `EXPECTED_VERSION="0.3.26"` AND change R15 date string from `2026-05-25` to `2026-05-26`. Run the test. R9/R10/R11/R12/R15 MUST FAIL because plugin.json/marketplace.json/README/CHANGELOG still report 0.3.25.
- [x] **GREEN**: Comes via S7+S8+S9+S10 (version-bump wiring). Will re-verify after the bump quartet lands.

### Step S4 — RED bump EXPECTED_VERSION to 0.3.26 in test-zensu-help-skill.sh

- [x] **RED**: Change `EXPECTED_VERSION="0.3.25"` to `EXPECTED_VERSION="0.3.26"` AND change S12 date string from `2026-05-25` to `2026-05-26`. Run the test. S6/S7/S8/S9/S12 MUST FAIL for the same reason as S3.
- [x] **GREEN**: Comes via S7+S8+S9+S10. Will re-verify after the bump quartet lands.

### Step S5 — IMPL SKILL.md Phase 2 recipe (drives S1+S2 GREEN)

- [x] **IMPL**: Replace Phase 2 recipe (lines 38-59) with the detection-augmented version: prepend `WORKTREE_HINT=""` derivation gated on `CLAUDE_PLUGIN_DATA_OVERRIDE` absence + `.git`-is-file probe; append `${WORKTREE_HINT}` to the two no-op echoes ("Nothing to reset" + "No round counter files in"); populated branch ("Reset complete") unchanged.
- [x] **GREEN**: Run test-reset-review-limit-skill.sh. R22 + R23 + R17/R18/R19/R20/R21 (preserved) MUST all PASS. R9/R10/R11/R12/R15 still FAIL (version bumps pending).

### Step S6 — IMPL SKILL.md Phase 1 narrative + Phase 2 preamble

- [x] **IMPL**: Extend Phase 1 narrative with a one-liner that the skill surfaces a worktree-fresh hint when applicable. Extend Phase 2 preamble paragraph with the pedagogical sentence: "When `STATE_DIR` resolves via the project-local default and the worktree root contains a `.git` *file* — not directory — the skill appends a fresh-worktree hint to the no-op message."
- [x] **GREEN**: Run test-reset-review-limit-skill.sh. R3 (section presence) + R19 (POSIX preamble) MUST still PASS — these edits only extend existing sections, no new sections introduced.

### Step S7 — WIRE plugin.json version 0.3.25 → 0.3.26

- [x] **WIRE**: Edit `.claude-plugin/plugin.json` `"version": "0.3.25"` → `"0.3.26"`. No new test; R9 already covers it (will GREEN after the bump quartet S7+S8+S9+S10 all land — R11 is cross-file invariant).

### Step S8 — WIRE marketplace.json version 0.3.25 → 0.3.26

- [x] **WIRE**: Edit `.claude-plugin/marketplace.json` `"version": "0.3.25"` → `"0.3.26"`. R10 already covers it.

### Step S9 — WIRE README.md version badge 0.3.25 → 0.3.26

- [x] **WIRE**: Edit `README.md` `version-0.3.25-green` → `version-0.3.26-green`. R12 already covers it.

### Step S10 — WIRE CHANGELOG.md new 0.3.26 section

- [x] **WIRE**: Insert `## [0.3.26] - 2026-05-26` section under `## [Unreleased]` with the `### Added` body documenting the worktree-hint detection. R15 already covers it (substring `## [0.3.26] - 2026-05-26`).

**Checkpoint after S10**: Run both `test-reset-review-limit-skill.sh` (30/30 PASS) AND `test-zensu-help-skill.sh` (12/12 PASS). Both green.

## Final Verification (Phase 6)

- [x] All structure tests pass (`for t in tests/structure/*.sh; do "$t"; done` → 0 FAIL)
- [x] Manual worktree smoke test: 4 scenarios under zsh and bash (no-state-dir, empty-dir, populated-dir, override-set)
- [x] Primary-repo smoke test: confirm hint does NOT appear when `.git` is a directory (not file)
- [x] Cross-file version invariant: plugin.json + marketplace.json + README + CHANGELOG all at 0.3.26
- [x] Build verification: shell scripts have no compile step — `Build: – n/a` per spec semantics
- [x] Coverage: SKIPPED (no coverage tool for shell scripts in this repo)
