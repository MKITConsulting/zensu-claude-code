# TDD Plan: resolve-session-id fixes (dot sanitization, self-init cutoff, log helper simplification)

## Context

Code-review findings on the prior `resolve-session-id.js` work (PR/round
`2026-05-25-1446_tdd-resolve-session-id.md`) surfaced three bugs:

1. `sanitizeProjectDir` regex `/[\/\\:]/g` does not include `.`, but Claude
   Code's real `~/.claude/projects/<sanitized>` convention replaces `.` too.
   Empirically verified for this very worktree
   (`/Users/marcelkarras/IdeaProjects/dev.zensu/zensu-claude-code/.claude/worktrees/thirsty-elbakyan-eaba92/`):
   real folder is
   `-Users-marcelkarras-IdeaProjects-dev-zensu-zensu-claude-code--claude-worktrees-thirsty-elbakyan-eaba92`.
   Helper currently produces `-Users-marcelkarras-IdeaProjects-dev.zensu-zensu-claude-code-.claude-worktrees-thirsty-elbakyan-eaba92`,
   so it never finds the projects subdir, returns empty, and the resolver
   silently falls through to the broken PPID cache. Fix is non-functional on
   the very repo it ships in.

2. `tests/structure/test-resolve-session-id.sh:156-168` (S7) sanitization
   test uses `/Users/foo/repo` (no dots), so it cannot catch the regression
   in finding #1.

3. `hooks/lib/zensu-log.sh:3` uses `date +%s%N` which is non-portable
   (GNU/BSD-14.1+ extension). On older systems `%N` is passed through
   literally, producing garbage like `1779715299N` that the helper's
   `parseCutoffMs` regex rejects, silently disabling Layer-1 race protection.

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash + Node.js 23 |
**Coverage**: SKIPPED (no coverage tool in repo)

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| node | CLI  | `command -v node` | present (v23.11.0) | use as-is |
| bash | CLI  | `command -v bash` | present | use as-is |
| ~/.claude/projects/<this-worktree> | fixture | `[ -d <path> ]` | present | use as-is |

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type     | Description                                                       | Test File                                  | Depends On | Status | Attempts |
|------|----------|-------------------------------------------------------------------|--------------------------------------------|------------|--------|----------|
| F1   | Bug-Fix  | sanitizeProjectDir must replace `.` (in addition to `/`,`\`,`:`)  | tests/structure/test-resolve-session-id.sh | -          | [G]    | 1        |
| F2   | Feature  | Helper self-initializes Layer-1 cutoff when argv[2] empty/invalid | tests/structure/test-resolve-session-id.sh | -          | [G]    | 1        |
| F3   | Refactor | Simplify `zensu-log.sh` line 3 — drop the `date +%s%N` reliance   | hooks/lib/zensu-log.sh                     | F2         | [RF]   | 1        |

### Step F1 — sanitizeProjectDir dot-handling
- [G] **RED**: Sub-test S7B in `test-resolve-session-id.sh` with fixture
  `S7B_PROJECT=/Users/foo/dev.zensu/.claude/worktrees/x` failed with
  `got '' expected 'eeeeeeee-...'` (subdir lookup found nothing because
  dots were preserved in sanitized name).
- [G] **GREEN**: Extended `sanitizeProjectDir` regex to `/[\/\\:.]/g`.
  Also aligned three fixture-mock `tr` calls in the test (mk_projects_dir,
  W2/W2B/W2C) to include `.` so the mocks match production helper behavior.
  S7B passes. Real-world smoke test returned UUID
  `a01473c3-c9cb-45ed-8d12-e00a548866ca` matching the existing
  `~/.claude/projects/-Users-marcelkarras-IdeaProjects-dev-zensu-zensu-claude-code--claude-worktrees-thirsty-elbakyan-eaba92/a01473c3-c9cb-45ed-8d12-e00a548866ca.jsonl`.

### Step F2 — Helper self-init for Layer-1 cutoff
- [G] **RED**: Added two sub-tests:
  - S8 (missing argv[2]): older + future-mtime siblings, no argv[2]. Failed
    with `got '88888888-ffff-...' expected '88888888-aaaa-...'` (future-mtime
    sibling returned because Layer-1 cutoff skipped).
  - S8B (non-numeric argv[2] like the literal string `1779715299N`): failed
    similarly. Models the broken `date +%s%N` output on pre-14.1 BSD/macOS.
- [G] **GREEN**: Helper now captures `Date.now()` at main() entry and uses
  it as the cutoff whenever `parseCutoffMs(argv[2])` returns null. The
  existing valid `argv[2]` override path remains for tests injecting specific
  timestamps. S8 and S8B pass.

### Step F3 — Simplify zensu-log.sh, remove `date +%s%N` dependency
- [G] **GREEN-BEFORE**: 15/0 PASS in
  `bash tests/structure/test-resolve-session-id.sh`.
- [G] **REFACTOR**: Replaced
  `: "${ZENSU_BASH_START:=$(date +%s%N 2>/dev/null)}"; export ZENSU_BASH_START`
  with `export ZENSU_BASH_START="${ZENSU_BASH_START:-}"`. The helper now
  self-initializes via `Date.now()` when the env var is empty/missing,
  removing the macOS-pre-14.1 `%N` portability bug.
- [G] **GREEN-AFTER**: 15/0 PASS unchanged. W2C
  (`zensu-log.sh self-initializes ZENSU_BASH_START when unset`) passes via
  helper self-init.

**Checkpoint**: `bash tests/structure/test-resolve-session-id.sh` reports
`15 PASS / 0 FAIL` (3 new tests: S7B, S8, S8B). Full structure-test suite:
15/15 files green, 221 PASS, 0 FAIL.

## Final Verification
- [G] All structure-test files pass (15/15 files, 221 PASS, 0 FAIL).
- [G] Smoke test against
      `~/.claude/projects/-Users-marcelkarras-IdeaProjects-dev-zensu-zensu-claude-code--claude-worktrees-thirsty-elbakyan-eaba92/*.jsonl`
      returns `a01473c3-c9cb-45ed-8d12-e00a548866ca` matching an existing
      `.jsonl`.
