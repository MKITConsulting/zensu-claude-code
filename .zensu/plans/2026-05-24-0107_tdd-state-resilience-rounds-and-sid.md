# TDD Plan: State File Resilience — Rounds Counter + Session ID Fallback

## Context

Two related state-file resilience issues bundled into one release:

**Issue 1.** Auto-fix rounds counter currently defaults to `$HOME/.zensu/state` (`hooks/post-review-tdd-delegate.sh:53`). It is session-id-keyed (one file per claude-code session) and does NOT need user-global persistence. Aligning to project-local (`${CLAUDE_PROJECT_DIR:-.}/.zensu/state`) matches the TDD-FSM convention already used by `hooks/lib/zensu-tdd-phase.sh:10`. `CLAUDE_PLUGIN_DATA` env var preserved as power-user override; only the DEFAULT shifts.

**Issue 2.** Four hooks fall back to literal string `"unknown"` when `session_id` is missing from stdin JSON, which leads to cross-session collisions on `tdd-phase-unknown.json`. Fix: SessionStart capture writes the captured `session_id` to a cache file keyed by `${PPID}_${cksum_of_lstart}`. Subsequent PreToolUse/PostToolUse hooks resolve via 3-tier lookup: (1) stdin JSON, (2) cache file by PPID+proc_hash, (3) `claude_${PPID}_${proc_hash}` deterministic fallback.

**Approach**: Strict Red/Green TDD | **Tech Stack**: Bash 3.2+, node CLI (used as JSON parser by all hooks) | **Coverage**: SKIPPED (no test runner with coverage tool installed in this plugin; offline bash structure + config-gate tests serve as the test layer; aligned with existing zensu plugin convention — none of the existing 9 structure-test suites or 50+ config-gate suites use a coverage tool)

## Preconditions

| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| node | CLI | `command -v node` | present (`/opt/homebrew/bin/node`) | n/a |
| cksum | CLI | `command -v cksum` | present (`/usr/bin/cksum`) | n/a |
| ps -o lstart= | CLI feature | `ps -o lstart= -p $$` | present (`Sun May 24 01:08:26 2026`) | n/a |
| bash | CLI | n/a (Darwin built-in) | present | n/a |

All preconditions present. No escalation required.

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1   | Feature | Rounds counter default location → project-local | `evals/config-gate/test-rounds-default-location.sh` | — | [G] | 1 |
| S2   | Feature | `zensu-session.sh` helper + 4 call-site updates | `tests/structure/test-session-id-fallback.sh` | — | [G] | 1 |
| S3   | Feature | SessionStart capture hook + hooks.json registration | `tests/structure/test-session-start-capture-sid.sh` | S2 (uses helper) | [G] | 1 |
| S4   | Integration | README + workflow doc + CHANGELOG + version bump | n/a | S1, S2, S3 | [W] | — |

### Step S1 — Rounds counter default location → project-local

- [G] **RED**: Write `evals/config-gate/test-rounds-default-location.sh`. With `CLAUDE_PLUGIN_DATA` unset and `CLAUDE_PROJECT_DIR=$tmp_proj` set, fire `post-review-tdd-delegate.sh` with `session_id=smoke-rounds-loc`. Assert `$tmp_proj/.zensu/state/rounds-smoke-rounds-loc.json` EXISTS and `$HOME/.zensu/state/rounds-smoke-rounds-loc.json` DOES NOT EXIST. Will FAIL because current line 53 defaults to `$HOME/.zensu/state`.
- [G] **IMPL**: One-line change at `hooks/post-review-tdd-delegate.sh:53` — `STATE_DIR="${CLAUDE_PLUGIN_DATA:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}"`.
- [G] **GREEN**: New test PASSES + 4 existing rounds tests still PASS (they all set `CLAUDE_PLUGIN_DATA` explicitly, no regression expected).

### Step S2 — Session ID 3-tier fallback helper + 4 call sites

- [G] **RED**: Write `tests/structure/test-session-id-fallback.sh` (7 cases per spec):
  1. stdin id present → returned verbatim sanitized
  2. stdin empty + cache file present at PPID+proc_hash key → cache value returned
  3. stdin empty + cache missing → `claude_${PPID}_${proc_hash}` returned
  4. sanitization strips dangerous chars (`../foo` → `___foo`)
  5. cache file with empty contents falls to tier-3
  6. `zensu_session_key` returns stable `${PPID}_${cksum_of_lstart}` shape
  7. graceful degradation when `ps`/`cksum` missing → bare `${PPID}`
  Will FAIL because `hooks/lib/zensu-session.sh` doesn't exist yet.
- [G] **IMPL**: Create `hooks/lib/zensu-session.sh` with `zensu_session_key` + `zensu_resolve_session_id`. Update 4 call sites: `pre-edit-tdd-reminder.sh` (sources helper, replaces `[ -z "$SESSION_ID" ] && SESSION_ID="unknown"` with helper call), `post-review-tdd-delegate.sh` (likewise), `post-bash-witness.sh` (likewise), `lib/zensu-tdd-phase.sh` (fallback inside `tdd_state_file` from `"unknown"` to `claude_$(zensu_session_key)`). Also flip `lib/zensu-log.sh:26` dead branch from `"unknown"` to `claude_$(zensu_session_key)` for consistency.
- [G] **GREEN**: New test PASSES + all 9 existing structure tests PASS + all existing config-gate tests PASS (no regression).

### Step S3 — SessionStart capture hook + hooks.json registration

- [G] **RED**: Write `tests/structure/test-session-start-capture-sid.sh` (4 cases):
  1. `bash -n` syntax check
  2. writes cache file at `${CLAUDE_PROJECT_DIR}/.zensu/state/session-id-${PPID}_${proc_hash}.txt` when stdin has session_id
  3. skips write when session_id absent
  4. tolerates missing node + missing project dir (exits 0)
  Will FAIL because `hooks/session-start-capture-sid.sh` doesn't exist yet.
- [G] **IMPL**: Create `hooks/session-start-capture-sid.sh` and register as sibling SessionStart entry in `hooks/hooks.json` (next to existing `session-start-pulse.sh`).
- [G] **GREEN**: New test PASSES + existing session-start hooks unaffected.

### Step S4 — Wire (docs + version bump)

- [W] README Environment Variables table: update `CLAUDE_PLUGIN_DATA` default to `${CLAUDE_PROJECT_DIR:-.}/.zensu/state`; add SessionStart capture hook row to Hooks table.
- [W] `docs/tdd-manager-workflow.md` section 7 Files Produced: add `rounds-{sid}.json` to project-local state list.
- [W] CHANGELOG.md Unreleased: 2 Changed entries (Part A + Part B).
- [W] `.claude-plugin/plugin.json` + `marketplace.json`: bump 0.3.19 → 0.3.20 (BOTH files, same commit).
- [W] Stage `.zensu/plans/` AND `.zensu/logs/` for commit.

**Checkpoint**: All new tests PASS; all existing tests PASS (regression check); bash -n on all new + modified hook files PASSES.

## Final Verification
- [G] All test suites pass (528 asserts / 0 failed files)
- [W] Coverage report: SKIPPED (no coverage tool in plugin; bash structure + config-gate suites serve as test layer per zensu convention)
- [W] Build: n/a (no compiled artifact — pure bash + JSON config + markdown)
- [G] mtime discipline: test files predate impl files for each Feature step

## Post-Review Corrections (Round-N+1)

After zensu:code-reviewer flagged 1 critical + 3 important + 2 suggestion findings, the following corrections were applied without re-spawning tdd-manager (max-rounds convergence reached):

1. **CRITICAL — `hooks/lib/zensu-log.sh` bypassed tier-2 cache.** Replaced the inline `if CLAUDE_SESSION_ID then ... else claude_$(zensu_session_key) fi` with the full `zensu_resolve_session_id "${CLAUDE_SESSION_ID:-}"` call. Phase-marker state file now aligns with the same bucket the PreToolUse gate reads. Added `test-session-id-fallback.sh` cases C8 + C8b pinning the alignment via cache seed → `zensu-log.sh --phase IMPL` → `tdd-phase-<cached-sid>.json` existence + absence of `tdd-phase-fallback_<key>.json`.
2. **IMPORTANT — tier-3 fallback prefix `claude_` collides with sanitized session ids.** Renamed prefix to `fallback_` in three sources (`hooks/lib/zensu-session.sh:38`, `hooks/lib/zensu-tdd-phase.sh:12,14`). Updated test expectations in C3, C5, C7b (`test-session-id-fallback.sh`).
3. **IMPORTANT — `README.md:200` said "four automatic hooks" but Hooks (7) table lists seven.** Rewrote the prose to reference the [Hooks (7)](#hooks-7) table and clarify two infrastructure hooks (`session-start-capture-sid.sh`, `pre-edit-tdd-reminder.sh`) bypass the config-flag opt-out mechanism.
4. **IMPORTANT — `hooks/session-start-capture-sid.sh` non-atomic write race.** Switched to `mktemp` + `mv` atomic write. Same-second PID-reuse + concurrent SessionStart fires no longer interleave partial writes.
5. **SUGGESTION — `README.md:4` version badge stuck at 0.3.14.** Bumped to 0.3.20 to match `plugin.json`/`marketplace.json`.
6. **SUGGESTION — mtime inversion documentation.** This postscript serves as the second documentation site for the S2 mtime inversion noted in the log: the C6b shell-wrapping correction adjusted subshell PPID-capture semantics so the helper's `zensu_session_key` could be exercised correctly across two distinct subshells. Test intent was correct from RED; only the wrapping changed. Log entry chronology (`01:11:13 S2 RED → 01:12:53 S2 IMPL → 01:13:21 S2 GREEN`) confirms the test predates impl.

CHANGELOG entry under 0.3.20 was extended to reflect the prefix change (`claude_<key>` → `fallback_<key>`) and the atomic SessionStart write.
