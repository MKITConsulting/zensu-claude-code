# TDD Plan: Anchor TDD narrative log path to ${CLAUDE_PROJECT_DIR}

## Context
Bug: the `/zensu:tdd` narrative log path is the only zensu artifact that is relative + unanchored. `mkdir -p .zensu/logs` runs once (Phase 0, skills/tdd/SKILL.md:187); per-phase appends (SKILL.md:67/:210) emit bare `>> .zensu/logs/...` assuming the dir exists relative to the current cwd. In a multi-dir project (worktree root vs. src-tauri) an append run from the wrong cwd fails: `no such file or directory: .zensu/logs/..._tdd-....log`. Witness log + FSM state already anchor with `${CLAUDE_PROJECT_DIR:-.}` (SKILL.md:270/:277, hooks/lib/zensu-log.sh:54). Fix: anchor the narrative log to `${CLAUDE_PROJECT_DIR:-.}` — strict improvement (degrades to relative when unset).

**Approach**: Strict Red/Green TDD | **Tech Stack**: Bash (Claude Code plugin), self-contained structure tests in tests/structure/*.sh | **Coverage**: SKIPPED — shell scripts, no per-file coverage tooling wired (repo precedent waives) @ n/a (default-90%-WAIVED)

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| bash | CLI | `command -v bash` | present | — |
| grep | CLI | `command -v grep` | present | — |

No missing preconditions — no escalation needed.

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Bug Fix | Anchor narrative log path in skills/tdd/SKILL.md | tests/structure/test-tdd-log-path-anchor.sh | — | [G] | 1 |
| S2 | Integration | Docs consistency (tdd-manager-workflow.md, implement/SKILL.md) | — | S1 | [W] | — |
| S3 | Integration | Version bump 0.4.1 -> 0.4.2 (plugin.json, marketplace.json, CHANGELOG.md) | — | S1 | [W] | — |

### Step S1 — Anchor narrative log path
- [x] **RED**: new test `tests/structure/test-tdd-log-path-anchor.sh` greps skills/tdd/SKILL.md and asserts (a) anchored {log_file} definition `${CLAUDE_PROJECT_DIR:-.}/.zensu/logs/{SESSION_TS}_tdd-{slug}.log`, (b) Phase-0 mkdir anchored `mkdir -p "${CLAUDE_PROJECT_DIR:-.}/.zensu/logs"`, (c) negative: no `>`/`>>` redirect to a bare relative `.zensu/logs/`. FAILS now (anchored definition absent, relative create present).
- [x] **GREEN**: edit SKILL.md — add anchored {log_file} definition, anchor Phase-0 mkdir+create (187), tail hint (188); ensure Principle 3 (67) / Phase 4 (210) / audit grep (320) reference {log_file}.

**Checkpoint**: `bash tests/structure/test-tdd-log-path-anchor.sh` + `bash tests/structure/test-gitignore-zensu.sh` pass

### Step S2 — Docs consistency [W]
- [x] **WIRE**: anchor example redirect docs/tdd-manager-workflow.md:277; update prose path mentions (:31, skills/implement/SKILL.md:129) to anchored form.

### Step S3 — Version bump [W]
- [x] **WIRE**: .claude-plugin/plugin.json -> 0.4.2; .claude-plugin/marketplace.json -> 0.4.2; CHANGELOG.md new `## [0.4.2] - 2026-05-31` section.

## Final Verification
- [x] tests/structure/test-tdd-log-path-anchor.sh passes
- [x] tests/structure/test-gitignore-zensu.sh still passes (no regression)
- [x] plugin.json & marketplace.json both 0.4.2
- [x] Coverage: SKIPPED (shell scripts)
