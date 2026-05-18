# TDD Plan: `run-eval.sh` Precondition + `set -u` Hardening (H10/H11)

## Context

Follow-up to `2026-05-18-1527_tdd-eval-hermetic.md` (H1-H9). Code review of PR #7 surfaced two remaining defects in `evals/tdd-manager/run-eval.sh`:

**Finding 1 (run-eval.sh:4, full-mode precondition).** When `evals/tdd-manager/test-project/` is missing (every worktree except root), invoking `bash run-eval.sh` (no flag) with full-mode:

- Reaches `mkdir -p "$RESULTS_DIR"` (line 216) and `claude -p` (line 34) despite the precondition being broken.
- `reset_project()` correctly returns rc=2 on missing PROJECT_DIR (H2 guard), but `run_agent()` (line 32) ignores the return code: `reset_project` is called as a statement, exit code discarded, then `cd "$PROJECT_DIR" && claude -p ...` short-circuits silently (line 34) — caught by `|| true`.
- Result: 119/127 FAIL, exit rc=0, masking the broken precondition. Confirmed live (15:56:27 in /tmp): `cd /tmp && bash <abs-path>/run-eval.sh` produces `Zeile 13: cd: ... No such file or directory` flood + cascading FAIL output.
- Spec target: `bash evals/tdd-manager/run-eval.sh` from worktree without `test-project/` exits rc=2 with one-line diagnostic, no `claude -p` spawn, no 119/127 FAIL noise.

**Finding 2 (run-eval.sh:1, missing `set -u`).** Sibling scripts use `set -u` (config-gate:2, tdd-review-chain:23). `run-eval.sh` does not. `${RESULTS_SUBDIR:-}` on line 5 is correctly defaulted, but other parameter expansions may not be — `set -u` enforces this discipline. **Not adding `set -e`** because body uses `|| true` patterns deliberately (e.g. line 34, line 124).

**Approach**: Strict Red/Green TDD via `test-hermetic.sh` register/run-all harness. Each finding gets a RED test that fails on current code, then minimal IMPL.

**Tech Stack**: Bash 5.3, assertion test scripts.

**Test commands**:
- Hermetic suite: `bash evals/tdd-manager/test-hermetic.sh`
- Self-check (no Claude): `bash evals/tdd-manager/run-eval.sh --self-check`
- Control evals: `bash evals/config-gate/run-eval.sh --self-check`, `bash evals/tdd-review-chain/run-eval.sh --self-check`
- E2E: `bash tests/e2e/test-runner.sh`, `bash tests/e2e/run.sh --offline`

**Coverage**: SKIPPED — shell scripts (matches H1-H9 plan).

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| H10 | Bug Fix | `main()` full-mode arm fails fast (rc=2) when `$PROJECT_DIR` is missing, with one-line diagnostic. Prevents 119/127 FAIL cascade and silent `claude -p` short-circuit. | `test-hermetic.sh::test_full_mode_aborts_when_project_dir_missing` | H9 | [G] | 1 |
| H11 | Feature | Add `set -u` at top of `run-eval.sh` (line 2) matching sibling evals. Verify all parameter expansions are correctly defaulted. | structural via `--self-check` + full hermetic suite re-run | H10 | [G] | 1 |
| H12 | W | Stage + commit `evals/tdd-manager/run-eval.sh`, `evals/tdd-manager/test-hermetic.sh`, plan, log with conventional message `fix(evals): fail-fast on missing test-project + add set -u` | — | H10, H11 | [W] | 1 |

### Step H10 — Full-mode precondition guard (DONE)

- [x] **RED**: Added `test_full_mode_aborts_when_project_dir_missing` to `test-hermetic.sh`. Initial run FAILed with rc=0 (expected 2), no diagnostic substring, and reached `claude -p` body — confirmed by `Eval Suite` marker in captured output. CORRECT RED.
- [x] **IMPL**: Added precondition check inside `main()` full-mode arm in `evals/tdd-manager/run-eval.sh` (lines 209-212) before `mkdir -p "$RESULTS_DIR"`. Emits diagnostic to stderr and returns 2 when `[ ! -d "$PROJECT_DIR" ]`.

**Checkpoint**: New test PASSes. All 9 hermetic tests PASS. Live verify: `cd $(mktemp -d) && bash <abs>/run-eval.sh` → rc=2 + diagnostic, no 119/127 FAIL noise.

### Step H11 — Add `set -u` (DONE)

- [x] **IMPL**: Inserted `set -u` at line 2 of `evals/tdd-manager/run-eval.sh`. Pre-checked parameter expansions — `RESULTS_SUBDIR` defaulted on line 6 (now); `issues` defaulted on line 147; all loop variables (`$f`, `$field`) come from `for`-loops which are safe. Did NOT add `set -e` (deliberate `|| true` patterns on lines 35, 125, 25).
- [x] **GREEN**: `bash evals/tdd-manager/test-hermetic.sh` 9/9 PASS. `bash evals/tdd-manager/run-eval.sh --self-check` 7/7 PASS. Live precondition verify still rc=2.

**Checkpoint**: All targets PASS. No unbound-variable surfaces.

### Step H12 — Commit (DONE)

- [x] **WIRED**: `git add` script + tests + plan + log; commit with conventional message.

## Final Verification

- [x] H10 GREEN (precondition guard test PASSes; current code fails it)
- [x] H11 GREEN (`set -u` does not break any existing test)
- [x] H12 WIRED (commit)
- [x] `bash evals/tdd-manager/test-hermetic.sh` 9/9 PASS
- [x] `bash evals/tdd-manager/run-eval.sh --self-check` 7/7 PASS
- [x] `cd $(mktemp -d) && bash <abs-path>/evals/tdd-manager/run-eval.sh` → rc=2 + diagnostic, no 119/127 FAIL noise
- [x] `bash tests/e2e/test-runner.sh` 13/13 PASS
- [x] `bash tests/e2e/run.sh --offline` 5/5 PASS
- [x] `bash evals/config-gate/run-eval.sh --self-check` 18/18 PASS (control)
- [x] `bash evals/tdd-review-chain/run-eval.sh --self-check` 21/21 PASS (control)
- [x] H9 row updated in companion plan `2026-05-18-1527_tdd-eval-hermetic.md` (doc drift fix)
