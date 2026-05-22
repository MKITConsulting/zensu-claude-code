# TDD Plan: DRY_RUN Preflight Ordering Fix

## Context
Fix code review finding on `scripts/claude-promptfoo-wrapper.sh:19-24` — the DRY_RUN path bypasses the `jq` preflight, re-opening a silent-failure window. When `DRY_RUN=1` and `jq` is missing, the script reaches the DRY_RUN exit (line 23) BEFORE the preflight (lines 31-34), producing a misleading `cwd=.` preview and exit 0. The previous reviewer's recommendation was to move both preflights ahead of the first `jq` invocation.

**Fix**: Move BOTH preflights (`claude` and `jq`) immediately after `set -u` at line 3 — before `PROMPT`/`OPTIONS_JSON` assignment and before any `jq -r ...` substitution and before any DRY_RUN exit. Add regression test `P7-S9`: `DRY_RUN=1 env -i PATH="$STUB_CLAUDE_DIR:/bin" bash "$WRAPPER" 'p' '{}'` must exit 127, stderr must contain "jq not found", stdout must NOT contain "DRY_RUN: would execute".

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash | **Coverage**: SKIPPED — bash project (no coverage tool wired)

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| jq | CLI | `command -v jq` | present | install (already installed) |
| bash | CLI | `command -v bash` | present | install (already installed) |
| claude CLI | CLI | `command -v claude` | present | install (already installed) |
| promptfoo | CLI | `command -v promptfoo` | present | install (already installed) |

All preconditions from prior rounds remain satisfied. No new preconditions.

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Add P7-S9 RED test (DRY_RUN + jq missing → exit 127, no preview) + reorder preflights before DRY_RUN exit | `tests/structure/test-claude-promptfoo-wrapper.sh`, `scripts/claude-promptfoo-wrapper.sh` | — | [G] | 1 |

### Step S1 — DRY_RUN preflight ordering
- [x] **RED**: Added P7-S9 test in `tests/structure/test-claude-promptfoo-wrapper.sh` — `env -i DRY_RUN=1 PATH="$STUB_DIR:/bin" bash "$WRAPPER" 'p' '{}'` (note: DRY_RUN must precede env -i target args, not the env -i invocation, so the variable survives the environment scrub). Asserted: exit code 127; stderr contains `jq not found`; stdout does NOT contain `DRY_RUN: would execute`. FAILED with rc=0 + misleading "DRY_RUN: would execute (cwd=.)" preview on stdout, empty stderr — confirming the silent-failure window (jq's "command not found" was swallowed by `2>/dev/null`, the empty AGENT/WORKDIR variables were silently coerced, and exit 0 was reached at line 23 before the line-31 preflight).
- [x] **IMPL**: Reordered `scripts/claude-promptfoo-wrapper.sh` so the `claude` preflight (lines 4-7) and `jq` preflight (lines 9-12) immediately follow `set -u` at line 2. They now precede `PROMPT`/`OPTIONS_JSON` assignment (lines 14-15), the two `jq -r ...` invocations (lines 17-18), and the DRY_RUN exit (lines 29-34). Both real-run AND DRY_RUN paths now exit 127 with a clear diagnostic when either CLI is missing.
- [x] **GREEN**: P7-S9 PASSES (rc=127, stderr contains "jq not found", stdout empty, no misleading preview). All existing 10 wrapper tests still PASS (11/11 total); 21/21 patches tests unchanged.

**Checkpoint**: `bash tests/structure/test-claude-promptfoo-wrapper.sh` (11/11) + `bash tests/structure/test-tdd-manager-patches.sh` (21/21) both PASS.

## Final Verification
- [x] All test suites pass (11/11 wrapper +1, 21/21 patches unchanged)
- [x] Agent file unchanged in line count (305)
- [x] Coverage report — N/A (bash project, no coverage tool wired)
- [x] Build: – n/a (no build step wired, plugin is bash + markdown)
- [x] mtime discipline audit: 1/1 step OK (test mtime 22:54:50 < impl mtime 22:55:19)
- [x] Preflight ordering: `claude` (lines 4-7) + `jq` (lines 9-12) preflights both appear before the first `jq -r ...` substitution (line 17) AND before the DRY_RUN exit (line 29)
