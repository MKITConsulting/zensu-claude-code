# TDD Plan: Hermetic `evals/tdd-manager/run-eval.sh`

## Context

`evals/tdd-manager/run-eval.sh` is destructive against the active worktree. Phase 1 discovery confirmed the root cause (and during H2 RED, the bug was reproduced LIVE — sourcing the script wiped this very plan + log file, recovered manually):

1. **`PROJECT_DIR="$EVAL_DIR/test-project"` points to an un-tracked, locally-created directory** that exists only in the root repo at `/Users/marcelkarras/IdeaProjects/dev.zensu/zensu-claude-code/evals/tdd-manager/test-project/`. The entire `test-project/` tree is NOT tracked — confirmed via `git ls-files --error-unmatch evals/tdd-manager/test-project` (fails: "no Git bekannten Dateien").
2. In any worktree other than root, `test-project/` is missing.
3. `reset_project()` does `cd "$PROJECT_DIR"` without checking exit status. When the directory is missing, `cd` fails, leaves `$PWD` unchanged, and the subsequent `rm -rf .zensu/logs/ .zensu/plans/` and `git checkout -- .` execute against the **invocation CWD** — the worktree root.
4. `git checkout -- .` reverts ALL uncommitted modifications under CWD: `agents/code-reviewer.md`, `agents/tdd-manager.md`, and anything else in-progress. The `rm -rf .zensu/logs/ .zensu/plans/` wipes plans + logs.
5. The spec references `bash evals/tdd-manager/run-eval.sh --self-check` — but no such mode exists. Bash silently accepts the unused arg and runs the full destructive eval (~$30+ Claude spawn cost + the destructive reset).
6. The script has no `if [ "${BASH_SOURCE[0]}" = "$0" ]` gate — sourcing for unit testing executes the destructive body. (Verified during H2 RED: a `source` from `bash -c` ran 8 eval rounds against `/tmp/test-project` until killed.)

Other eval scripts (`evals/config-gate/`, `evals/tdd-review-chain/`) operate on `$EVAL_DIR/fixtures/` or only on `$PLUGIN_DIR` (read-only `cd`); they have no equivalent hazard. `evals/tdd-review-chain/run-eval.sh` does `rm -f "$EVAL_DIR/fixtures/sample.test."*` but `$EVAL_DIR` resolves correctly via `cd "$(dirname "$0")" && pwd`, so it stays in the eval subdir.

**Fix design (defensive + sourceable):**

1. **`--self-check` mode** (matches existing pattern from `evals/tdd-review-chain` and `evals/config-gate`): runs only structural checks against the script itself and the fixture-template availability, never calls `cd "$PROJECT_DIR"` or `claude -p`. Always safe to run from any worktree, never destructive.
2. **Source-gate**: wrap the destructive body so `source run-eval.sh` does NOT run it. Function definitions remain available for unit tests; main body only runs when the script is executed directly.
3. **Defensive `reset_project()`**: `cd "$PROJECT_DIR" || { echo error >&2; return 2; }` — fail-fast. Plus a guard that `git rev-parse --show-toplevel` from inside `$PROJECT_DIR` resolves to `$PROJECT_DIR` itself, so we never `git checkout` in the wrong repo (the worktree's enclosing repo).
4. **Unknown-flag rejection**: any arg other than `--self-check` or empty (full mode) → exit 2 with "unknown mode" message. Prevents silent fall-through.
5. **Hermetic eval mode** (full sandbox copy of test-project) is out of scope for THIS task — left as a follow-up because building a portable test-project template requires invoking the agent at least once to verify the harness. The defensive guards from steps 2-3 + `--self-check` from step 1 already cover the reported hazard.

**Approach**: Strict Red/Green TDD for bash logic via assertion scripts that source/exec `run-eval.sh` in subshells with controlled environments.
**Tech Stack**: Bash 5.3 (`/opt/homebrew/bin/bash`), assertion-style test scripts following existing `evals/config-gate/test-*.sh` and `evals/tdd-review-chain/assert-*.sh` patterns.
**Test commands**:
- Full hermetic suite: `bash evals/tdd-manager/test-hermetic.sh`
- Self-check (no Claude): `bash evals/tdd-manager/run-eval.sh --self-check`
- Other evals self-check (regression): `bash evals/config-gate/run-eval.sh --self-check`, `bash evals/tdd-review-chain/run-eval.sh --self-check`
- Lint: shellcheck not installed (advisory only, matches existing discipline)
**Coverage**: SKIPPED — shell scripts, no project-grade coverage tooling. Threshold source: default-90%-WAIVED (matches existing pattern documented in `2026-05-18-0014_tdd-reviewer-tdd-manager-anti-loop-guardrails.md`).

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| H1 | Feature | `test-hermetic.sh` skeleton: discovers/runs `test_*` functions, reports PASS/FAIL, exits non-zero on FAIL | `evals/tdd-manager/test-hermetic.sh::test_skeleton_self_test` | — | [G] | 1 |
| H2 | Bug Fix | Source-gate run-eval.sh AND `reset_project()` aborts when `$PROJECT_DIR` is missing (exit 2). Also honors env-set PROJECT_DIR/RESULTS_DIR for testability. | `test-hermetic.sh::test_reset_project_aborts_when_project_dir_missing` | H1 | [G] | 1 |
| H3 | Bug Fix | `reset_project()` aborts when `$PROJECT_DIR` exists but is NOT its own git toplevel — refuse to `git checkout` in an enclosing repo (worktree-agnostic guard) | `test-hermetic.sh::test_reset_project_aborts_when_not_own_toplevel` | H2 | [G] | 1 |
| H4 | Feature | `--self-check` mode: structural checks only (script syntax + 5 function defs + PROJECT_DIR scoping), no Claude spawn, no `reset_project` call, exits 0 when checks pass | `test-hermetic.sh::test_self_check_runs_without_destruction` | H1, H2 | [G] | 1 |
| H5 | Feature | Unknown-flag rejection: `bash run-eval.sh --bogus` exits 2 with "unknown mode" message | `test-hermetic.sh::test_unknown_flag_rejected` | H4 | [G] | 1 |
| H6 | Bug Fix | Sentinel-line preservation: appending `# TEST_SENTINEL_<rand>` to `agents/code-reviewer.md`, running `run-eval.sh --self-check`, sentinel still present | `test-hermetic.sh::test_self_check_preserves_agents_modifications` | H4 | [G] | 1 |
| H7 | Bug Fix | `.zensu/` preservation: creating `.zensu/test-marker-$$.txt`, running `run-eval.sh --self-check`, marker still present | `test-hermetic.sh::test_self_check_preserves_zensu` | H4 | [G] | 1 |
| H8 | Feature | Worktree-agnostic: `--self-check` runs successfully from at least 2 working directories (PLUGIN_DIR + `/tmp`) | `test-hermetic.sh::test_self_check_works_from_multiple_cwds` | H6, H7 | [G] | 1 |
| H9 | W | Stage + commit `evals/tdd-manager/run-eval.sh`, `evals/tdd-manager/test-hermetic.sh`, plan, log with conventional message `fix(evals): make tdd-manager run-eval.sh hermetic (self-check + project-dir guards)` | — | H1-H8 | [W] | 1 |

### Step H1 — `test-hermetic.sh` skeleton (DONE)

- [x] **RED**: `bash evals/tdd-manager/test-hermetic.sh --list` returned exit 127 (file missing).
- [x] **GREEN**: Created skeleton with `register`/`run_all`/`list_tests`/`check`. `test_skeleton_self_test` passes.

### Step H2 — Source-gate + fail-fast on missing PROJECT_DIR (DONE)

- [x] **RED**: `test_reset_project_aborts_when_project_dir_missing` — sources `run-eval.sh` with PROJECT_DIR pointing to a non-existent path, invokes `reset_project`, expects non-zero exit with "missing/not found/unreadable" message. Initially the test ITSELF demonstrated the bug live: sourcing the script ran the full destructive eval body, wiping this plan + log file (recovered manually).
- [x] **GREEN**: Wrapped destructive body in `main()` function + added `[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"` gate (lines 538-540). Replaced `cd "$PROJECT_DIR"` in `reset_project()` with fail-fast guard (lines 13-16). Also changed `EVAL_DIR` to use `${BASH_SOURCE[0]}` (line 3) and made `PROJECT_DIR`/`RESULTS_DIR` env-overridable (lines 4-5) for testability.

**Checkpoint**: Test passes. Manual: `(cd /tmp && PROJECT_DIR=/nonexistent bash -c 'source <path>/run-eval.sh; reset_project')` → exit 2. Sourcing alone (without calling `main`) produces NO output and exits 0.

### Step H3 — `reset_project()` toplevel guard (DONE)

- [x] **RED**: `test_reset_project_aborts_when_not_own_toplevel` — created a tmpdir nested inside `$PLUGIN_DIR` (worktree). Without guard, `reset_project` returned 0 — vulnerable to `git checkout` against enclosing worktree.
- [x] **GREEN**: Added toplevel guard (lines 17-22 of run-eval.sh). Returns 3 with "refusing — not its own git toplevel" message. Non-empty `$toplevel` check allows tmpdirs outside any git repo (e.g. `/tmp/sandbox` works as expected).

**Checkpoint**: Test passes.

### Step H4 — `--self-check` mode (DONE)

- [x] **RED**: `test_self_check_runs_without_destruction` — full SHA-256 + directory-listing snapshots. Failed on existing code (`results/` listing changed because main body ran).
- [x] **GREEN**: Added `self_check()` function (lines 173-200) that asserts: (1) script syntax via `bash -n`, (2) 5 helper functions defined, (3) PROJECT_DIR scoped under EVAL_DIR. `main()` branches on mode (lines 202-215). Self-check runs in ≤1s, no Claude spawn, no `reset_project` call. Output: 7/7 PASS.

**Checkpoint**: `bash evals/tdd-manager/run-eval.sh --self-check` exits 0 in ≤1s. Worktree unchanged.

### Step H5 — Unknown-flag rejection (DONE)

- [x] **RED**: After temporarily reverting the case-default arm (to honor RED discipline), `--bogus` ran full eval body. Test FAILed with rc=0.
- [x] **GREEN**: Re-added case-default arm in `main()` (lines 211-214). `--bogus` now exits 2 with "unknown mode '--bogus' — accepted: --self-check, (no arg / full)".

**Checkpoint**: `bash evals/tdd-manager/run-eval.sh --bogus` → exit 2.

### Step H6 — Sentinel-line preservation (agents/) (DONE)

- [x] **RED+GREEN**: Acceptance test confirmed property holds after H2+H4. The test appends `# TEST_SENTINEL_<hex>` to `agents/code-reviewer.md`, runs `--self-check`, asserts sentinel still present, restores file. The destructive vector against `agents/` was `git checkout -- .` in `reset_project()` — H2's fail-fast on missing PROJECT_DIR blocks it; H4's `--self-check` branch bypasses `reset_project` entirely.

### Step H7 — `.zensu/` preservation (DONE)

- [x] **RED+GREEN**: Acceptance test. Creates `.zensu/test-marker-$$-<hex>.txt`, runs `--self-check`, asserts marker still present. Destructive vector against `.zensu/` was `rm -rf .zensu/logs/ .zensu/plans/` in `reset_project()` — H4 prevents `reset_project` from running in self-check mode.

### Step H8 — Worktree-agnostic CWD (DONE)

- [x] **RED+GREEN**: Runs `bash <abs-path>/run-eval.sh --self-check` from `$PLUGIN_DIR` AND `/tmp/<mktemp>`. Both exit 0 with self-check marker in output. Path resolution uses `${BASH_SOURCE[0]}` (line 3) so EVAL_DIR is correct regardless of CWD.

### Step H9 — Commit (DONE)

- [x] **WIRED**: `git add` the script + tests + plan + log; commit with conventional message. Landed as `60763c2 fix(evals): make tdd-manager run-eval.sh hermetic` plus follow-up `af6f1d4 docs(plan): record H9 commit in hermetic-eval log`.

## Final Verification

- [x] All H1-H8 GREEN
- [x] H9 WIRED (commit 60763c2)
- [x] `bash evals/tdd-manager/run-eval.sh --self-check` exits 0 from worktree root (verified manually)
- [x] `bash evals/tdd-manager/run-eval.sh --self-check` exits 0 from `/tmp` (verified manually)
- [x] Edit `agents/code-reviewer.md` (append `# TEST_SENTINEL_acceptance_check`), run `--self-check`, marker still present (verified manually + test_self_check_preserves_agents_modifications)
- [x] `.zensu/plans/2026-05-18-1527_tdd-eval-hermetic.md` and `.zensu/logs/2026-05-18-1527_tdd-eval-hermetic.log` present after `--self-check` (verified manually + test_self_check_preserves_zensu)
- [x] `bash evals/config-gate/run-eval.sh --self-check` 18/18 PASS (control)
- [x] `bash evals/tdd-review-chain/run-eval.sh --self-check` 21/21 PASS (control)
- [x] `bash evals/tdd-manager/test-hermetic.sh` 8/8 PASS
