# TDD Plan: Move `plan-review` skill into the zensu plugin (rewritten, generic)

> **Version note:** This plan was written targeting **0.6.3**. PR #62 shipped 0.6.3
> concurrently, so the work was rebased onto the latest `main` and ships as **0.6.4**.
> Every "0.6.3" below should read "0.6.4"; the cross-file version sync was applied at 0.6.4.

## Context
Move the user-space `plan-review` skill (`~/.claude/skills/plan-review/`) into the
published zensu plugin as `/zensu:plan-review`. Rewrite the SKILL.md from scratch,
generic for ALL codebases (no leaked stack names from the user's other project),
English-only, single self-contained file (lead injects each persona's focus + JSON
schema into sub-agent spawn prompts; no `rules/` files). Register in `plugin.json`,
sync version to 0.6.3 across `plugin.json` + `marketplace.json` + README badge, add a
CHANGELOG section + README skills row, lock with a structure test, then remove the
user-space copy.

**Approach**: Strict Red/Green TDD | **Tech Stack**: Claude Code plugin (bash scripts,
markdown skills, JSON manifests; no package.json) | **Test runner**: standalone bash
structure tests `bash tests/structure/<name>.sh` (exit 0 = all PASS) | **Coverage**:
SKIPPED (no coverage tooling in the bash structure suite — matches all sibling tests) |
**Build**: – n/a (no build step wired)

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| jq | CLI | `command -v jq` | present | used by structure test (sibling tests rely on it) |

(TeamCreate/Agent are runtime tools the skill invokes when *run* — not needed to build
the markdown artifact, so not a build precondition.)

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Create + register the generic `/zensu:plan-review` skill (SKILL.md + plugin.json entry + version sync + README + CHANGELOG) | tests/structure/test-plan-review-skill.sh | — | [G] | 1 |
| S2 | Integration | Remove the user-space `~/.claude/skills/plan-review` copy | — | S1 | [W] | — |

> **Audit follow-up (folded into S1):** the README skill count went 9→10, which is
> pinned by three sibling tests — bumped `### Skills (9)`→`(10)` in
> `test-self-review-skill.sh` (V19), `test-zensu-help-skill.sh` (S10),
> `test-reset-review-limit-skill.sh` (R13). Also fixed a latent brittleness in
> `test-self-review-skill.sh` V21 (it derived the version dynamically but hard-coded
> the release date `2026-06-01`; now date-agnostic, mirroring zensu-help S12).

### Step S1 — Create + register the generic plan-review skill
- [ ] **RED**: Test `test-plan-review-skill.sh` — asserts P1 SKILL.md exists, P2 first
  line `# /zensu:plan-review`, P3 orchestration essentials (TeamCreate, read-only,
  default 6, 4 core persona ids, JSON verdict enums), P4 English-only + generic guard
  (no German tokens, no leaked stack names), P5 plugin.json skills[] entry, P6 version
  sync (plugin.json == marketplace.json == README badge). FAILS first because
  `skills/plan-review/SKILL.md` does not exist and plugin.json lacks the entry.
- [ ] **GREEN**: Author `skills/plan-review/SKILL.md` (generic, English, single-file);
  add `"./skills/plan-review"` to plugin.json skills[] + bump version 0.6.2→0.6.3;
  bump marketplace.json 0.6.2→0.6.3; bump README badge + `### Skills (9)`→`(10)` + add
  row; add CHANGELOG `## [0.6.3]` Added section.

**Checkpoint**: `bash tests/structure/test-plan-review-skill.sh` PASS; sibling
version-sync tests (`test-zensu-help-skill.sh`, `test-reset-review-limit-skill.sh`)
still PASS.

### Step S2 — Remove user-space copy
- [ ] **WIRED**: `rm -rf ~/.claude/skills/plan-review` after S1 is GREEN (the explicit
  "raus aus dem User-Space"). No test cycle — verified by absence check.

## Final Verification
- [x] `bash tests/structure/test-plan-review-skill.sh` → 16/16 PASS
- [x] `test-zensu-help-skill.sh` 17/17 · `test-self-review-skill.sh` 37/37 · `test-reset-review-limit-skill.sh` 32/32 → all PASS
- [x] `jq '.skills'` shows `./skills/plan-review`; `jq '.version'` on plugin.json + marketplace.json = 0.6.3; both JSON valid
- [x] `~/.claude/skills/plan-review` no longer exists
- [x] mtime discipline: test-first PASS · precondition drift: none · Coverage: SKIPPED (no tool) · Build: – n/a · witness cross-check: all 4 test cmds VERIFIED
