# TDD Plan: Code Review Fixes — Precondition Round (4 findings)

## Context
Fix 4 findings from code review on the precondition-handling round:

1. `scripts/claude-promptfoo-wrapper.sh:7-8` — Silent failure when `jq` is missing from PATH. Add a parallel preflight for `jq` immediately after the existing `claude` preflight (exit 127 + diagnostic). Add a new test case using `env -i PATH="$STUB_DIR:/bin"` (NO jq, claude stub present) asserting exit 127 + stderr "jq not found".

2. `scripts/claude-promptfoo-wrapper.sh:8` — `jq -r '.config.working_dir // "."'` does not default empty strings — `//` in jq only fires on null/false. Add explicit empty-string default for `WORKDIR` only (NOT `AGENT`). Add a regression test: DRY_RUN=1 with `{"config":{"working_dir":""}}` asserts `cwd=.`.

3. `agents/tdd-manager.md:295` (Phase 6 step 6.b) — Replace `grep -E '\b(X|substitute)\b'` with fixed-string word matching `grep -F -w "$X"` plus an escaping directive against regex metacharacters. Update patches test if it references the old `grep -E '\b` substring.

4. `agents/tdd-manager.md:131-134` (Phase 1.5 step 3) — Option (a) "install/provide it now" is undefined. Insert a new step between current steps 4 and 5: wait for user install, re-run verification, loop back if still missing, do NOT proactively run install commands.

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash + markdown agent specs | **Coverage**: SKIPPED — bash project (no coverage tool wired)

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| jq | CLI | `command -v jq` | present | install (already installed) |
| bash | CLI | `command -v bash` | present | install (already installed) |
| claude CLI | CLI | `command -v claude` | present | install (already installed) |
| promptfoo | CLI | `command -v promptfoo` | present | install (already installed) |

All preconditions from the previous round are satisfied. No new preconditions introduced.

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Add `jq` preflight to wrapper | `tests/structure/test-claude-promptfoo-wrapper.sh` | — | [G] | 1 |
| S2 | Feature | Add `WORKDIR` empty-string default | `tests/structure/test-claude-promptfoo-wrapper.sh` | S1 | [G] | 1 |
| S3 | Feature | Replace Phase 6 grep with `grep -F -w` | `tests/structure/test-tdd-manager-patches.sh` | — | [G] | 1 |
| S4 | Feature | Insert Phase 1.5 option-(a) install follow-up | `tests/structure/test-tdd-manager-patches.sh` | S3 | [G] | 1 |

### Step S1 — Add jq preflight to claude-promptfoo-wrapper.sh
- [x] **RED**: Test `P7-S7 wrapper with jq missing from PATH: exit 127 + jq-not-found diagnostic` — runs wrapper with `env -i PATH="$STUB_DIR:/bin"` (NO jq, claude stub present). Asserted exit code 127 + stderr contains "jq not found". FAILED with rc=0, empty stderr (wrapper silently absorbed jq absence via `2>/dev/null` and macOS `cd ""` no-op).
- [x] **GREEN**: Added `command -v jq` preflight immediately after the `claude` preflight in `scripts/claude-promptfoo-wrapper.sh` (lines 31-34), emitting `claude-promptfoo-wrapper: jq not found on PATH — install jq.` to stderr and exiting 127.

### Step S2 — Add WORKDIR empty-string default
- [x] **RED**: Test `P7-S8 explicit empty working_dir defaults to . (DRY_RUN preamble)` — DRY_RUN=1 with options `{"config":{"working_dir":""}}` asserted `cwd=.`. FAILED with `cwd=` (jq `//` did not default empty strings).
- [x] **GREEN**: Added `[ -z "$WORKDIR" ] && WORKDIR="."` at line 9 of `scripts/claude-promptfoo-wrapper.sh` (only for `WORKDIR`, NOT `AGENT`).

### Step S3 — Replace Phase 6 step 6.b grep with `grep -F -w`
- [x] **RED**: Added 3 assertions in `tests/structure/test-tdd-manager-patches.sh` checking `grep -F -w` presence, regex-metacharacters warning, and absence of the old `grep -E '\b(X|substitute)\b'` interpolation. All 3 FAILED on the unmodified agent.
- [x] **GREEN**: Replaced the `grep -E '\b(X|substitute)\b' {log_file}` snippet at line 296 with `grep -F -w "$X" {log_file} || grep -F -w "$substitute" {log_file}` plus the regex-metacharacters warning paragraph (verbatim per recommendation).

### Step S4 — Insert Phase 1.5 option-(a) install follow-up
- [x] **RED**: Added 2 assertions in `tests/structure/test-tdd-manager-patches.sh` checking for `picks (a) install` and `does NOT proactively run install commands` substrings. Both FAILED on the unmodified agent.
- [x] **GREEN**: Inserted new step 5 in Phase 1.5 of `agents/tdd-manager.md` (line 133); renumbered original steps 5 → 6 and 6 → 7. Step describes: pause + wait for user, re-run verification from step 2, loop back to step 3 if still missing, agent does NOT proactively run install commands unless user explicitly authorizes the specific install command in the same exchange.

**Checkpoint**: `bash tests/structure/test-claude-promptfoo-wrapper.sh` (10/10) + `bash tests/structure/test-tdd-manager-patches.sh` (21/21) both PASS.

## Final Verification
- [x] All test suites pass (10/10 wrapper, 21/21 patches — was 8/8 + 16/16, gained 2 wrapper + 5 patches)
- [x] Agent file line count = 305 (≤ 320)
- [x] Coverage report — N/A (bash project, no coverage tool wired)
- [x] Build: – n/a (no build step wired, plugin is bash + markdown)
- [x] mtime discipline audit: 4/4 steps OK (test files modified before impl files)
- [x] Precondition drift audit: clean (all 4 preconditions present, no install/skip decisions)
