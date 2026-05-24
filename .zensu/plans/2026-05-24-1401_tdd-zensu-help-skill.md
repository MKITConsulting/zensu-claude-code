# TDD Plan: Add `/zensu:zensu-help` Q&A Skill

## Context

The Zensu plugin currently ships five action-oriented skills (`bootstrap`, `ghost-scan`, `implement`, `pulse`, `security-review`). A sixth skill `/zensu:zensu-help` is needed as an in-conversation Q&A surface for both Zensu (the SaaS PLM) concepts and the plugin itself. The skill embeds the stable glossary and architecture overview and routes volatile topics through `Read` of canonical docs.

Version bump: `0.3.20 → 0.3.22` (parallel session reserved `0.3.21`; skipped intentionally).

**Approach**: Strict Red/Green TDD via bash structure test
**Tech Stack**: Markdown skill file + JSON manifest entries + bash structure test
**Coverage**: SKIPPED (markdown + JSON only, no executable code; coverage is N/A)

## Preconditions

| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| jq | CLI | `command -v jq` | present | n/a |
| bash | CLI | `command -v bash` | present | n/a |

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Structure test for the new skill (RED while artifacts missing) | `tests/structure/test-zensu-help-skill.sh` | - | [G] | 1 |
| S2 | Feature | Create `skills/zensu-help/SKILL.md` + register in `plugin.json` + bump `marketplace.json` | `tests/structure/test-zensu-help-skill.sh` | S1 | [G] | 1 |
| S3 | Integration | Update `CHANGELOG.md` and `README.md` (badge, heading count, skills table row) | `tests/structure/test-zensu-help-skill.sh` | S2 | [W] | 1 |

### Step S1 — Structure test pinning the skill registration

- [G] **RED**: Test `tests/structure/test-zensu-help-skill.sh` — asserts `skills/zensu-help/SKILL.md` exists, has correct H1 and section headings, is registered in `plugin.json` skills[], and that `plugin.json` `.version` == `marketplace.json` `.plugins[0].version` == `"0.3.22"`. Fails initially because none of these exist yet.
- [G] **GREEN**: After S2 + S3, all assertions pass.

### Step S2 — Create SKILL.md, register in plugin.json, bump marketplace.json

- [G] **RED**: Inherits S1's RED — failing on SKILL.md missing + plugin.json missing entry + versions still `0.3.20`.
- [G] **GREEN**: Write `skills/zensu-help/SKILL.md` with the exact body in the spec; add `"./skills/zensu-help"` to `plugin.json` skills[]; bump both manifest versions to `"0.3.22"`. Re-run test → GREEN.

### Step S3 — Docs (CHANGELOG.md + README.md)

- [W] **WIRED**: Insert `## [0.3.22] - 2026-05-24` CHANGELOG section. README updates: badge `0.3.20 → 0.3.22`, heading `### Skills (5) → ### Skills (6)`, append `/zensu:zensu-help` row to the skills table. Verified by re-running the structure test plus visual diff inspection.

**Checkpoint**: `bash tests/structure/test-zensu-help-skill.sh` passes with all assertions GREEN. Run the full structure-test suite to confirm no regressions in adjacent tests.

## Final Verification

- [x] `tests/structure/test-zensu-help-skill.sh` passes (17/17)
- [x] All other tests under `tests/structure/` still pass (13/13 suites GREEN)
- [x] `jq '.skills | length' .claude-plugin/plugin.json` → 6
- [x] `jq -r '.version' .claude-plugin/plugin.json` → 0.3.22
- [x] `jq -r '.plugins[0].version' .claude-plugin/marketplace.json` → 0.3.22
- [x] `head -1 skills/zensu-help/SKILL.md` → `# /zensu:zensu-help`
- [x] `grep -c '0.3.22' README.md` ≥ 1
- [x] `grep -c '## \[0.3.22\] - 2026-05-24' CHANGELOG.md` → 1
- [x] Coverage report — SKIPPED (no executable code)
