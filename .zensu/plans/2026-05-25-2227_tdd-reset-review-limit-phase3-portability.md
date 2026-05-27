# TDD Plan: Reset-Review-Limit Skill — Phase 3 zsh Portability Fix

## Context
Code-review finding (round 1/5):

> skills/reset-review-limit/SKILL.md:68 — Phase 3 verify command has the same zsh strict-glob bug the Phase 2 fix was supposed to eliminate. Under zsh, `ls -la "$STATE_DIR"/rounds-*.json 2>/dev/null || echo "(empty, expected)"` emits `zsh:1: no matches found: ...` to stderr because zsh's `nomatch` fires at glob-expansion time BEFORE `ls` is invoked — the `2>/dev/null` only redirects `ls`'s stderr, not the shell's. Final exit is 0 via the OR fallthrough, but the user sees a noisy zsh error contradicting the skill's "(exits 0 with a clear message when nothing matches)" promise. Same root cause as the Phase 2 bug.
>
> Fix: Apply the same `find` rewrite to Phase 3. Use `find "$STATE_DIR" -maxdepth 1 -name 'rounds-*.json' 2>/dev/null` and emit `(empty, expected)` only when the find output is empty. Mirror the Phase 2 approach so the skill is uniformly portable across bash/zsh/dash. Add an R20 assert in `tests/structure/test-reset-review-limit-skill.sh` pinning the Phase 3 `find` invocation, mirroring R18.

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash structure tests | **Coverage**: – n/a (no coverage tool wired in this repo's structure tests) | **Constraint**: Do NOT bump version (already 0.3.25). Update existing 0.3.25 CHANGELOG entry — do NOT add new version section.

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| bash test runner | CLI | `command -v bash` | present | n/a |
| grep | CLI | `command -v grep` | present | n/a |
| jq | CLI | `command -v jq` (used by test) | present | n/a |

No external CLIs/secrets/endpoints/fixtures required.

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1   | Bug Fix | Add R20 assert pinning Phase 3 `find ... rounds-*.json` invocation; rewrite Phase 3 recipe in SKILL.md to use `find` | tests/structure/test-reset-review-limit-skill.sh | — | [G] | 1 |
| S2   | Integration | Append "Phase 3 also fixed" note to existing 0.3.25 CHANGELOG `Fixed` bullet | (none — wiring) | S1 | [W] | — |

### Step S1 — Phase 3 portability fix with R20 assert
- [G] **RED**: New R20 in `tests/structure/test-reset-review-limit-skill.sh` greps for the Phase 3 `find "$STATE_DIR" -maxdepth 1 -name 'rounds-*.json'` invocation. Region-scoped via `sed -n '/^## Phase 3: Verify/,/^## Response Style/p'` so R18 (whole-file grep for Phase 2) cannot trivially satisfy R20. Confirmed FAIL with: `R20 ... did not match — Phase 3 region still contains bare $STATE_DIR/rounds-*.json ls glob`.
- [G] **GREEN**: Rewrote SKILL.md Phase 3 verify block. New recipe:
  ```sh
  find "$STATE_DIR" -maxdepth 1 -name 'rounds-*.json' 2>/dev/null
  [ -z "$(find "$STATE_DIR" -maxdepth 1 -name 'rounds-*.json' 2>/dev/null)" ] && echo "(empty, expected)"
  ```
  Updated narrative now explicitly references zsh `nomatch` semantics + the "stderr before ls runs" mechanism.

**Checkpoint**: `bash tests/structure/test-reset-review-limit-skill.sh` → 27 PASS / 0 FAIL.

### Step S2 — CHANGELOG.md amendment
- [W] **WIRED**: Existing `## [0.3.25]` Fixed bullet extended (single bullet, not new version section). Added: Phase 3 root cause description, the `ls` failure mechanism, the `find` rewrite, and noted R20 as the fourth new structure assert (was R17/R18/R19; now R17/R18/R19/R20).

**Checkpoint**: Final `bash tests/structure/test-reset-review-limit-skill.sh` → 27 PASS / 0 FAIL.

## Final Verification
- [G] R20 pins the Phase 3 `find` invocation specifically (region-scoped via sed, not satisfied by Phase 2 R18)
- [G] Full target suite passes (27 PASS / 0 FAIL)
- [G] Sibling structure tests unaffected: `test-promptfoo-reset-review-limit.sh` 20/0, `test-zensu-help-skill.sh` 17/0
- [W] CHANGELOG 0.3.25 Fixed bullet mentions Phase 3 inline
- [G] No live executable bare `"$STATE_DIR"/rounds-*.json` glob in SKILL.md (the one remaining inline-code occurrence is inside backticks within explanatory prose, not a recipe)
- [G] mtime discipline: test (1779740920) written BEFORE impl (1779740953); 0/1 test-after
