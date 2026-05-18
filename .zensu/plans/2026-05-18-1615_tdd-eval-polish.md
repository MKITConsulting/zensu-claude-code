# TDD Plan: `run-eval.sh` Polish (H13/H14/H15/H16)

## Context

Follow-up to `2026-05-18-1555_tdd-eval-preconditions-and-set-u.md` (H10-H12). Code review on PR #7 surfaced four additional defects:

**Finding 1 (H13, run-eval.sh:211 — weak precondition shape check).** Current guard `[ ! -d "$PROJECT_DIR" ]` only checks directory existence. When `PROJECT_DIR` resolves to a path that exists but lacks `src/` and `package.json` (env override or stale partial copy), the guard passes, the eval body enters, `claude -p` spawns (verified live: rc=124 at 30s timeout). Wastes credits and produces 119/127 FAIL. Toplevel guard in `reset_project` does not catch it because `/tmp` has no enclosing git repo. Fix: validate `src/` + `package.json` markers (the actual layout the eval body depends on — `cd $PROJECT_DIR && npm test`, `$PROJECT_DIR/src/...`).

**Finding 2 (H14, test-hermetic.sh:243-265 — test exercises override path, not default path).** Existing `test_full_mode_aborts_when_project_dir_missing` overrides `PROJECT_DIR`. The default path (`$EVAL_DIR/test-project`) — the one that bit production in the 119/127 FAIL incident — is not codified as a regression test. Fix: add `test_full_mode_aborts_when_default_test_project_missing` that copies `run-eval.sh` to a fresh tmpdir (no sibling `test-project/`) and runs it WITHOUT overriding `PROJECT_DIR`.

**Finding 3 (H16, log hygiene).** `.zensu/logs/2026-05-18-1555_...log` has 2 trailing post-commit lines (H12 hash + TDD COMPLETE marker) added after the H12 commit but never staged. CLAUDE.md rule: always stage AND commit `.zensu/logs/` for current task. Fix: roll the trailing lines + the new H13/H14/H15 log lines into the H16 fix commit.

**Finding 4 (H15, run-eval.sh:5-6 — cosmetic double-slash).** When `RESULTS_SUBDIR` is unset and `RESULTS_DIR` is unset, `RESULTS_DIR="${RESULTS_DIR:-$EVAL_DIR/results/${RESULTS_SUBDIR:-}}"` produces `$EVAL_DIR/results/` (trailing slash) → report path becomes `$EVAL_DIR/results//report-...`. Harmless but unclean. Fix: `RESULTS_DIR="${RESULTS_DIR:-$EVAL_DIR/results${RESULTS_SUBDIR:+/$RESULTS_SUBDIR}}"` — `${VAR:+/$VAR}` only prepends `/` when `VAR` is set+non-empty.

**Approach**: Strict Red/Green TDD via `test-hermetic.sh` harness. Each finding gets a RED test that fails on current code, then minimal IMPL. Finding 3 is wiring.

**Tech Stack**: Bash 5.3, assertion test scripts.

**Test commands**:
- Hermetic suite: `bash evals/tdd-manager/test-hermetic.sh`
- Self-check (no Claude): `bash evals/tdd-manager/run-eval.sh --self-check`
- Control evals: `bash evals/config-gate/run-eval.sh --self-check`, `bash evals/tdd-review-chain/run-eval.sh --self-check`
- E2E: `bash tests/e2e/test-runner.sh`, `bash tests/e2e/run.sh --offline`

**Coverage**: SKIPPED — shell scripts (matches H1-H12 plans).

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| H13 | Bug Fix | Strengthen full-mode precondition: validate `src/` + `package.json` in addition to dir existence. Guard against malformed-PROJECT_DIR cases that waste claude credits. | `test-hermetic.sh::test_full_mode_aborts_when_project_dir_malformed` | H12 (prior plan) | [G] | 1 |
| H14 | Bug Fix | Add regression test exercising the DEFAULT `$EVAL_DIR/test-project` path (the path that bit production), without `PROJECT_DIR` override. | `test-hermetic.sh::test_full_mode_aborts_when_default_test_project_missing` | H13 | [G] | 1 |
| H15 | Bug Fix | Fix cosmetic double-slash in `RESULTS_DIR` when `RESULTS_SUBDIR` is unset. Use `${RESULTS_SUBDIR:+/$RESULTS_SUBDIR}` for conditional path joining. | `test-hermetic.sh::test_results_dir_no_double_slash` | — | [G] | 1 |
| H16 | W | Stage + commit script, hermetic tests, plan, log including the 2 trailing lines from prior plan's log. Conventional message `fix(evals): tighten test-project precondition + clean up results path`. | — | H13, H14, H15 | [W] | 1 |

### Step H13 — Strict shape check for PROJECT_DIR (DONE)

- [x] **RED**: Added `test_full_mode_aborts_when_project_dir_malformed`. Initial run on current code: rc=124 (timeout, claude actually spawned), `Eval Suite` + `Running run1` markers present in output — CORRECT RED (shallow `-d` check passes empty dir, eval body enters).
- [x] **IMPL**: Replaced `[ ! -d "$PROJECT_DIR" ]` on line 211 with `[ ! -d "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR/src" ] || [ ! -f "$PROJECT_DIR/package.json" ]`. Updated diagnostic to mention expected layout.

**Checkpoint**: New test PASSes. All 10 hermetic tests PASS. Live: `PROJECT_DIR=$(mktemp -d) bash run-eval.sh` → rc=2 + "malformed" diagnostic, no claude spawn.

### Step H14 — Regression test for default test-project path (DONE)

- [x] **RED**: Added `test_full_mode_aborts_when_default_test_project_missing`. Verified RED via guard-removal experiment: temporarily replaced line 211 guard with `:` no-op, ran existing `test_full_mode_aborts_when_project_dir_missing` test → FAIL rc=0 + reached-claude-or-eval-body. Confirms guard absence breaks both override AND default paths. H14 acts as regression lock for the default-path resolution that bit production.
- [x] **IMPL**: Test itself IS the regression lock. H13 guard covers both code paths; H14 codifies it.

**Checkpoint**: Both override-path and default-path tests PASS. 11/11 hermetic.

### Step H15 — Fix RESULTS_DIR double-slash (DONE)

- [x] **RED**: Added `test_results_dir_no_double_slash`. Sources `run-eval.sh` with `RESULTS_DIR` and `RESULTS_SUBDIR` unset, captures resolved `RESULTS_DIR` AND `REPORT`. Initial run: FAIL — `RESULTS_DIR-has-trailing-slash:[.../results/]` + `REPORT-has-double-slash:[.../results//report-...txt]`. CORRECT RED (assertion mismatch on path shape).
- [x] **IMPL**: Changed line 6 to `RESULTS_DIR="${RESULTS_DIR:-$EVAL_DIR/results${RESULTS_SUBDIR:+/$RESULTS_SUBDIR}}"`. The `${VAR:+/$VAR}` form only prepends `/` when VAR is set+non-empty — safe under `set -u`.

**Checkpoint**: New test PASSes. 12/12 hermetic. Self-check 7/7. `set -u` tolerance verified.

### Step H16 — Commit (DONE)

- [x] **WIRED**: `git add -f` script + tests + plan + both log files (current polish log + 2 trailing lines from prior `2026-05-18-1555` log per Finding 3); commit with conventional message.

## Final Verification

- [x] H13 GREEN (strict shape check; rc=2 on empty dir, no claude spawn)
- [x] H14 GREEN (default-path regression lock; rc=2 from foreign cwd)
- [x] H15 GREEN (no `//` in resolved `REPORT`)
- [x] H16 WIRED (commit with hash recorded below)
- [x] `bash evals/tdd-manager/test-hermetic.sh` 12/12 PASS (9 prior + 3 new)
- [x] `bash evals/tdd-manager/run-eval.sh --self-check` 7/7 PASS
- [x] `PROJECT_DIR=$(mktemp -d) bash evals/tdd-manager/run-eval.sh` → rc=2 + "malformed" diagnostic, no claude spawn (< 1s)
- [x] `cd $(mktemp -d) && bash <abs-path>/evals/tdd-manager/run-eval.sh` → rc=2 + diagnostic
- [x] `bash tests/e2e/test-runner.sh` 13/13 PASS
- [x] `bash tests/e2e/run.sh --offline` 5/5 PASS
- [x] Control: `bash evals/config-gate/run-eval.sh --self-check` 18/18 PASS
- [x] Control: `bash evals/tdd-review-chain/run-eval.sh --self-check` 21/21 PASS
- [x] `git status -s` empty (no untracked or modified `.zensu/` files after commit)
- [x] Final commit hash recorded in summary for PR inclusion
