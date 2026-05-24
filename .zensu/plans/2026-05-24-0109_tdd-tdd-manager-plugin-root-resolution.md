# TDD Plan: tdd-manager Plugin Root Resolution (Eliminate Helper Discovery Improvisation)

## Context

Each tdd-manager session shows several LLM-improvised bootstrap steps at the
start of the task list:

- `Find zensu-log.sh helper`
- `Pick latest zensu plugin version`
- `Test log timestamp helper`
- `Check log helper location`

These steps are nowhere prescribed in `agents/tdd-manager.md`. They appear as
the agent LLM's emergency response, because `$CLAUDE_PLUGIN_ROOT` is empty in
subagent Bash tool invocations.

**Mechanics:**

1. `agents/tdd-manager.md` invokes the helper as
   `bash $CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-log.sh ...` (10x in the document).
2. `hooks/lib/zensu-log.sh:3` contains self-resolve
   (`: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/../.." && pwd)}"`), but
   that line only runs AFTER bash loads the script.
3. When `$CLAUDE_PLUGIN_ROOT` is empty, the call site expands to
   `bash /hooks/lib/zensu-log.sh ...` -> exit 127 "No such file or directory"
   before line 3 is reached.
4. Subagents inherit the user shell env, not the plugin hook env. claude-code
   injects `CLAUDE_PLUGIN_ROOT` only for hook command strings (see
   `hooks/hooks.json`), not for free Bash calls in the subagent.
5. The LLM sees the 127 error -> improvises: searches
   `~/.claude/plugins/cache/*/zensu/...` via `find`/`ls` -> triggers
   permission prompts on the user plugin home -> user confused.

**Consequence:** noisy task list + confusing permission prompts on plugin
cache paths that the user does not connect to the repo.

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash + markdown structure tests | **Coverage**: SKIPPED (bash hooks + markdown prompts; no coverage tool installed for this repo layer — matches `2026-05-23-2043_tdd-test-run-witness.md` convention)

## Preconditions

| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| bash | CLI | `command -v bash` | present | install (already) |
| grep | CLI | `command -v grep` | present | install (already) |
| ~/.zensu | fixture | `[ -d "$HOME/.zensu" ]` | present | install (already) |

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | SessionStart hook persists plugin root to `~/.zensu/plugin-root` (idempotent) | tests/structure/test-session-start-plugin-root.sh | - | [G] | 1 |
| S2 | Feature | Phase 0 Step 0 + Hard Ban in tdd-manager.md for plugin-root resolution | tests/structure/test-tdd-manager-patches.sh | - | [G] | 1 |
| S3 | Feature | Replace all `$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-log.sh` with `{PLUGIN_ROOT}/hooks/lib/zensu-log.sh` | tests/structure/test-tdd-manager-patches.sh | S2 | [G] | 1 |

### Step S1 — SessionStart persists plugin root (Feature)

- [x] **RED**: Create `tests/structure/test-session-start-plugin-root.sh` with cases:
  - `bash -n` syntax check passes
  - Hook source contains `mkdir -p "$HOME/.zensu"` (or `HOME` env via stub)
  - Hook source contains write to `$HOME/.zensu/plugin-root`
  - Hook source contains idempotency guard (compare current vs new before write)
  - Functional: invoking the hook with `HOME=$TMP CLAUDE_PLUGIN_ROOT=/some/path` creates `$TMP/.zensu/plugin-root` with content `/some/path`
  - Idempotent functional: invoking twice with same value does not change mtime
  - FAIL initially because hooks/session-start-pulse.sh does not yet contain the persist block.
- [x] **GREEN**: Append idempotent persist block to `hooks/session-start-pulse.sh` before `exit 0` (note: current file ends after `echo`, no explicit `exit 0`; append after the echo).

### Step S2 — Phase 0 Step 0 + Hard Ban (Feature)

- [x] **RED**: Extend `tests/structure/test-tdd-manager-patches.sh` with cases:
  - Phase 0 contains a numbered "Resolve plugin root once" step that mentions `$HOME/.zensu/plugin-root` and `{PLUGIN_ROOT}`
  - Phase 0 contains the FATAL abort message string `FATAL: plugin root unresolvable`
  - Hard Bans section contains `NEVER search the filesystem to "discover" the zensu-log.sh helper`
  - FAIL initially because agents/tdd-manager.md does not contain those strings.
- [x] **GREEN**: Edit `agents/tdd-manager.md` Phase 0 to insert Step 0 (becoming the new step 1; existing 1 and 2 shift to 2 and 3). Append the new Hard Ban line.

### Step S3 — Replace helper invocation placeholder (Feature)

- [x] **RED**: Extend `tests/structure/test-tdd-manager-patches.sh` with cases:
  - Zero occurrences of literal `$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-log.sh` in agent file
  - At least 10 occurrences of literal `{PLUGIN_ROOT}/hooks/lib/zensu-log.sh` in agent file
  - FAIL initially because agent file still uses the `$CLAUDE_PLUGIN_ROOT/...` form throughout.
- [x] **GREEN**: Mechanical replace_all of `$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-log.sh` -> `{PLUGIN_ROOT}/hooks/lib/zensu-log.sh` in `agents/tdd-manager.md`.

**Checkpoint**: `bash tests/structure/test-tdd-manager-patches.sh` and `bash tests/structure/test-session-start-plugin-root.sh` both PASS, full structure suite PASS, agent file line count <= 320.

## Final Verification

- [x] All structure test files PASS (11 files, 156 PASS / 0 FAIL across the suite)
- [x] `bash -n hooks/session-start-pulse.sh` clean
- [x] Manual smoke deferred (`~/.zensu/plugin-root` is written on next SessionStart; covered by PR-F1 functional test against tmp HOME)
- [x] Coverage: SKIPPED (bash + markdown layer; no coverage tool installed)
- [x] Build: n/a (this repo has no build step)
