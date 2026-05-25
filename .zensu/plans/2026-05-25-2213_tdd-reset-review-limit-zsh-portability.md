# TDD Plan: Fix shell-portability bug in /zensu:reset-review-limit (0.3.24 → 0.3.25)

## Context

PR #45 shipped `/zensu:reset-review-limit` in 0.3.24. The Phase 2 recipe in `skills/reset-review-limit/SKILL.md:38-60` uses two bash-only constructs:

1. `shopt -s nullglob` (line 46) — bash builtin, not present in zsh
2. `for f in "$STATE_DIR"/rounds-*.json; do` (line 48) — relies on nullglob to avoid iterating when the glob has zero matches

When a macOS user invoked the skill, claude's Bash tool ran the recipe through zsh:

```
Exit code 1
(eval):9: command not found: shopt
(eval):11: no matches found: /Users/.../zensu/state/rounds-*.json
```

Approach: rewrite the recipe in POSIX-portable shell using `find` (works in bash/zsh/dash/sh). Bump to 0.3.25 (patch). User explicitly declined adding a regression test for the recipe itself — existing promptfoo eval and structure tests continue to cover output schema.

**Approach**: Strict Red/Green TDD | **Tech Stack**: Bash structure tests, JSON manifests, Markdown | **Coverage**: SKIPPED (no coverage tool wired for shell project)

## Preconditions

| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| jq | CLI | `command -v jq` | present | n/a |
| zsh | CLI | `command -v zsh` | present | n/a |
| find | CLI | `command -v find` | present | n/a |
| grep | CLI | `command -v grep` | present | n/a |

## Status Legend

| Marker | Meaning |
|--------|---------|
| [ ] | Not started |
| [R] | RED test written |
| [I] | Implementation done |
| [G] | GREEN — test passing |
| [RF] | Refactored — pre/post tests green |
| [!] | Blocked |
| [W] | Wired (integration, no test cycle) |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature (bug-fix) | Replace bash recipe in SKILL.md with POSIX-portable find-based recipe | tests/structure/test-reset-review-limit-skill.sh (extended) | — | [G] | 1 |
| S2 | Feature (test-bump-driven) | Bump version 0.3.24 → 0.3.25 across plugin.json, marketplace.json, README, structure tests | tests/structure/test-reset-review-limit-skill.sh + test-zensu-help-skill.sh | S1 | [G] | 1 |
| S3 | Feature (test-driven via S2 setup) | Add CHANGELOG.md entry for 0.3.25 | tests/structure/test-reset-review-limit-skill.sh (R15) + test-zensu-help-skill.sh (S12) | S2 | [G] | 1 |
| S4 | Integration | Manual zsh smoke test (empty + populated state dir) | n/a | S1, S2, S3 | [W] | 1 |

### Step S1 — Replace bash recipe in SKILL.md with POSIX-portable find-based recipe

- [G] **RED**: Extend `tests/structure/test-reset-review-limit-skill.sh` with new asserts pinning:
  - `R17` SKILL.md does NOT contain `shopt -s nullglob` (the bash-only builtin that broke zsh)
  - `R18` SKILL.md contains `find "$STATE_DIR" -maxdepth 1 -name 'rounds-*.json'` (the POSIX-portable replacement)
  - `R19` SKILL.md preamble line for Phase 2 mentions "POSIX shell" or "bash/zsh/dash" (so the doc declares its portability commitment)
  - Run the test → R17/R18/R19 FAIL because the recipe still uses `shopt` and the glob-in-for-loop form.
- [G] **GREEN**: Edit `skills/reset-review-limit/SKILL.md`:
  - Replace bash recipe (lines 38-60) with the POSIX-portable `find`-based form
  - Update preamble paragraph (line 36) to mention POSIX shell portability
  - Run the test → all 19 asserts PASS, including the 16 pre-existing ones.

**Checkpoint**: `tests/structure/test-reset-review-limit-skill.sh` runs 0 FAIL with extended asserts.

### Step S2 — Version bump 0.3.24 → 0.3.25

- [G] **RED**: Bump `EXPECTED_VERSION="0.3.24"` → `"0.3.25"` in BOTH:
  - `tests/structure/test-reset-review-limit-skill.sh:12`
  - `tests/structure/test-zensu-help-skill.sh:11`
  - Run both → multiple version asserts FAIL (R9, R10, R11, R12, S6, S7, S8, S9) because plugin.json/marketplace.json/README still report 0.3.24.
- [G] **GREEN**: Bump:
  - `.claude-plugin/plugin.json`: `"version": "0.3.24"` → `"0.3.25"`
  - `.claude-plugin/marketplace.json`: `"plugins[0].version": "0.3.24"` → `"0.3.25"`
  - `README.md` line 4: `version-0.3.24-green` → `version-0.3.25-green`
  - Run both tests → all asserts PASS (except R15/S12 which assert CHANGELOG section for 0.3.25; deferred to S3).

**Checkpoint**: Both structure tests at 0 FAIL except CHANGELOG-section asserts (deferred to S3).

### Step S3 — CHANGELOG.md entry for 0.3.25

- [G] **RED**: After S2, `R15` (`CHANGELOG.md has '## [0.3.25] - 2026-05-25' section`) and `S12` (same heading from zensu-help test) FAIL because CHANGELOG has no 0.3.25 section yet.
- [G] **GREEN**: Add `## [0.3.25] - 2026-05-25` section under `## [Unreleased]` in `CHANGELOG.md` with the "Fixed" block from the spec.
  - Run both structure tests → 0 FAIL.

**Checkpoint**: `tests/structure/test-reset-review-limit-skill.sh` 0 FAIL; `tests/structure/test-zensu-help-skill.sh` 0 FAIL.

### Step S4 — Manual zsh smoke test

Integration step (`[W]`). No automated test; spec-mandated manual verification that the new recipe actually works under zsh (the failure shell).

- Pre-seed an empty temp `.zensu/state/` directory, run the new recipe verbatim through `zsh -c`, assert it prints `No round counter files in <path>` and exits 0.
- Pre-seed a temp directory with `rounds-test-001.json`, run the new recipe through `zsh -c`, assert `Removed:`, `Reset complete: 1 counter file(s) deleted`, exit 0, file gone.

## Final Verification

- [G] All structure tests pass: `for t in tests/structure/*.sh; do "$t"; done` reports 0 FAIL across all suites
- [G] Cross-file version invariant: `jq -r '.version' .claude-plugin/plugin.json` and `jq -r '.plugins[0].version' .claude-plugin/marketplace.json` both report `0.3.25`
- [G] README badge contains `version-0.3.25-green`
- [G] CHANGELOG has `## [0.3.25] - 2026-05-25` heading
- [W] Manual zsh smoke test (S4) passes both scenarios
