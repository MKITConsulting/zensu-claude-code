# TDD Plan: Reviewer/tdd-manager Anti-Loop Guardrails

## Context

User reported a 14-round review cycle (should be 4-5). Root cause analysis identified three systemic gaps in the plugin's reviewer + tdd-manager loop:

1. **Stale-branch blindness** — reviewer/tdd-manager work file-locally, never branch-vs-trunk. Work proceeded on a stale HEAD without main's fix until round 11.
2. **No build verification** — neither agent built artifacts and booted them until round 7. Helm-secret refactor rounds were NO-OPs because Astro `import.meta.env.SITE` is frozen at build-time.
3. **Reviewer trusts tdd claims blindly** — A round's "166/166 PASS" claim was false (165/166). The reviewer read only the diff, never reproduced.

This plan implements three concept-level guardrails in the two agent definition files (LLM-prompt level, not stack-specific) plus an e2e test harness that fires the reviewer against fixture repos and asserts the guardrails surface the right findings.

**Approach**: Strict Red/Green TDD where applicable; `[W]` integration where not (LLM-prompt edits, fixture git-setup scripts).
**Tech Stack**: Bash + `expect` + Node (for JSON parsing) — matches existing `evals/` patterns.
**Test commands**:
- Full suite: `bash tests/e2e/run.sh` (once created)
- Unit subset for harness logic: `bash tests/e2e/run.sh --self-check`
- Lint: shellcheck (advisory only — not strict-gated, matching existing `evals/` discipline)
**Coverage**: SKIPPED — shell scripts, no project-grade coverage tooling configured (no `.nycrc`, no `vitest.config.*`, no `pyproject.toml [coverage]`). Threshold source: default-90%-WAIVED.

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| 1 | Feature | `run.sh` skeleton: iterates fixtures, reports PASS/FAIL counts | `tests/e2e/test-runner.sh` | — | [G] | 2 |
| 2 | Feature | `run.sh` pattern matcher: reads `expected/<name>.pattern`, greps captured output | `tests/e2e/test-runner.sh` | 1 | [G] | 1 |
| 3 | Feature | `run.sh` `--self-check` mode: skips fixtures, runs only static checks | `tests/e2e/test-runner.sh` | 1 | [G] | 1 |
| 4 | Feature | `run.sh` claude-cli invocation per fixture: spawns `claude --print` with reviewer prompt, captures stdout | `tests/e2e/test-runner.sh` | 2 | [G] | 2 |
| 5 | W | Fixture: `clean-pr` — green-path baseline, 1 trivial typescript change, no findings expected | direct git ops | — | [W] | 1 |
| 6 | W | Fixture: `stale-branch` — branch is N commits behind main (N>=2), no other content changes | direct git ops | — | [W] | 1 |
| 7 | W | Fixture: `build-fails` — feature branch has TS syntax error so `tsc` exits non-zero | direct git ops | — | [W] | 1 |
| 8 | W | Fixture: `false-test-claim` — `tdd-claim.txt` says "100/100 PASS" but no test files exist | direct git ops | — | [W] | 1 |
| 9 | W | Fixture: `docs-only` — only `.md` changes, no buildable code touched | direct git ops | — | [W] | 1 |
| 10 | W | `expected/*.pattern` files: robust grep-substrings for each fixture's expected reviewer-output signal | direct write | 5,6,7,8,9 | [W] | 1 |
| 11 | W | Edit `agents/code-reviewer.md`: insert Phase 1 Step 0 "Branch Drift Check" before existing Step 1 | direct edit | — | [W] | 1 |
| 12 | W | Edit `agents/code-reviewer.md`: insert new Phase 3 "Build Verification" between old Phase 2 and old Phase 3; renumber subsequent phases | direct edit | 11 | [W] | 1 |
| 13 | W | Edit `agents/code-reviewer.md`: insert new Phase 4 "Test Reproduce on Critical" (conditional); renumber | direct edit | 12 | [W] | 1 |
| 14 | W | Edit `agents/code-reviewer.md`: Phase 5 (renamed Synthesize & Report) — add drift-warning header + Build-Verify + Test-Reproduce sections | direct edit | 13 | [W] | 1 |
| 15 | W | Edit `agents/code-reviewer.md`: extend "Bash ONLY for:" allowlist to include `git fetch origin`, `git rev-list`, `git symbolic-ref`, and build/test commands | direct edit | 11,12 | [W] | 1 |
| 16 | W | Edit `agents/tdd-manager.md`: insert Phase 6 Step 2 "Build Verification" between full-suite and coverage; renumber | direct edit | — | [W] | 1 |
| 17 | W | `tests/e2e/README.md`: setup doc + how to add new fixtures + pattern-writing rules | direct write | 1-15 | [W] | 1 |
| F1 | Feature | `run.sh`: invoke via `claude --print --agent code-reviewer` (not `@zensu:code-reviewer` literal in prompt) | `test-runner.sh::test_invokes_named_agent` | — | [G] | 1 |
| F2 | RF | Pattern files (clean-pr, build-fails, docs-only, stale-branch): collapse Build Verification status to a single line; tighten stale-branch regex | inline grep validation | F1, F3 | [G] | 1 |
| F3 | W | `agents/code-reviewer.md` Phase 5 report template: change `## Build Verification\n{build_status}` to single-line `## Build Verification: {build_status}` (also `## Test Reproduce:` same fix) | manual diff inspection | — | [W] | 1 |
| F4 | W | `agents/tdd-manager.md` line 205: change "return to Phase 3" wording — Phase 3 is "Create ALL Tasks", plan-step authorship belongs in Phase 2 | manual diff inspection | — | [W] | 1 |
| F5 | Bug Fix | `run.sh --offline` lookup: change from `$fixture/.captured` to most-recent `$RESULTS_DIR/${fixture_name}-*.captured.txt` | `test-runner.sh::test_offline_mode_picks_newest_capture` | F1 | [G] | 1 |
| F6 | RF | `tests/e2e/expected/false-test-claim.pattern`: tighten — remove bare `tdd-manager reported`, require co-occurring `CRITICAL` or `NEEDS CHANGES` marker on second pattern line | `test-runner.sh::test_false_test_claim_pattern_rejects_prompt_echo` | — | [G] | 1 |
| F7 | W | `agents/code-reviewer.md` line 23 region: add explicit body-inspection prohibition for build/test commands (no `rm`/`mv`/`>`/`>>`/`sed -i` in script body) | manual diff reflection | — | [W] | 1 |
| F8 | Feature | `run.sh` rejects unknown mode flags with exit 2 (closes silent-fallthrough to live-mode for typos like `--bogus`) | `test-runner.sh::test_unknown_mode_rejected` | F1 | [G] | 1 |
| F9 | Bug Fix | `build-fails` fixture hermetic build: `setup-fixtures.sh` runs `npm install` so `tsc` actually fires; tighten `build-fails.pattern` back to strict `## Build Verification: ✗ failed` (no Verdict fallback) | `test-runner.sh::test_build_fails_fixture_runs_tsc` | F8 | [G] | 1 |
| F10 | W | Update `tests/e2e/README.md` (hermetic-build caveats + setup needs npm + accepted-modes section) and `.gitignore` (`tests/e2e/fixtures/`, `tests/e2e/results/`) | manual diff inspection | F9 | [W] | 1 |
| F11 | Bug Fix | `test-runner.sh`: 5 test fns now set `RESULTS_DIR="$tmp/results"` (per-fixture, named-agent, skeleton, self-check, unknown-mode) — also added `test_results_dir_isolated_per_test` guard | `test-runner.sh::test_results_dir_isolated_per_test` | — | [G] | 1 |
| F12 | Feature | `run.sh`: detect zero-byte capture file after `invoke_reviewer`, FAIL with explicit "zero-byte capture" diagnostic instead of silent pattern-mismatch | `test-runner.sh::test_zero_byte_capture_diagnostic` | F11 | [G] | 1 |
| F13 | RF | `run.sh`: dropped unreachable inner `*)` defensive arm — upfront allowlist at :17-24 is sole gate | inline grep+test-runner run | F12 | [RF] | 1 |
| F14 | W | Commit harness + plan + log artifacts with conventional message covering F8+F9 (and F11-F13 follow-up); `tests/e2e/{run.sh,test-runner.sh,setup-fixtures.sh,README.md,expected/}` + `.zensu/plans/` + `.zensu/logs/` + agent .md + .gitignore | manual `git log -1 --stat` | F11,F12,F13 | [W] | 1 |

### Step F11 — Isolate RESULTS_DIR in test-runner.sh

- [x] **RED**: Test `test_results_dir_isolated_per_test` — snapshots canonical `tests/e2e/results/` before suite, asserts no new files after. FAILED correctly on current code (`myfx-*.captured.txt` + `report-*.txt` leaks from 5 tests missing RESULTS_DIR env).
- [x] **GREEN**: Added `RESULTS_DIR="$tmp/results"` to env-prefix in `test_invokes_claude_print_per_fixture` (:181), `test_invokes_named_agent` (:300), `test_skeleton_reports_total_counts`, `test_self_check_skips_claude`, `test_unknown_mode_rejected`. Root cause fixed beyond user-spec narrow `myfx-*` (also `report-*.txt`).

### Step F12 — Zero-byte capture diagnostic

- [x] **RED**: Test `test_zero_byte_capture_diagnostic` — creates an empty `captured.txt` in RESULTS_DIR + matching pattern, runs `run.sh --offline`, asserts output contains both `FAIL` and `zero-byte capture` for that fixture. Failed correctly (silent pattern-mismatch, no diagnostic substring).
- [x] **GREEN**: In `run.sh` fixture loop (after MODE case sets `$captured_file`, before pattern-file existence check), added `[ ! -s "$captured_file" ] && { check "$fixture_name (zero-byte capture — claude --print produced no output)" FAIL; continue; }`. Applies in `--offline` (empty existing capture) and full mode (claude --print failure).

### Step F13 — Collapse unreachable inner case branch

- [x] **GREEN-BEFORE**: test-runner.sh 13/13 PASS + `run.sh --bogus` rc=2 + "unknown mode" message.
- [x] **CHANGE**: In `run.sh` inner case, removed the `*)` branch. Three branches remain: `--self-check)`, `--offline)`, `""|full)`. No comment replacement.
- [x] **GREEN-AFTER**: test-runner.sh 13/13 PASS + `run.sh --bogus` rc=2 (caught by upfront allowlist alone).

### Step F14 — Commit harness + plan + log

- [x] **WIRED**: Commit `fdf1207` `feat(e2e): hermetic build-fails fixture + unknown-flag rejection` — 14 files / 1145 ins / 9 del. Includes harness (5 e2e files + 5 patterns), agent .md edits, .gitignore, plan, log. `git log -1 --stat` verified all expected paths present. NOTE: the plan + log entries describing this commit + its [W] mark land in a follow-up "docs(plan): record F11-F14" commit since they describe the commit itself.

### Step F8 — Reject unknown mode flags

- [x] **RED**: Test `test_unknown_mode_rejected` — runs `bash run.sh --bogus` against empty fixtures dir, asserts (a) exit code = 2 and (b) error message mentions "unknown mode" or rejects it. Failed correctly (rc=0, no error message) before implementation.
- [x] **GREEN**: Added upfront `case "$MODE"` allowlist after MODE assignment + kept inner case for defense-in-depth. `--bogus` now exits 2 with `FAIL  unknown mode '$MODE' — accepted: --self-check, --offline, (no arg / full)`.

### Step F9 — Hermetic build-fails fixture

- [x] **RED**: Test `test_build_fails_fixture_runs_tsc` — after `setup-fixtures.sh`, runs `./node_modules/.bin/tsc` and asserts (a) exit code != 0 and (b) `TS2322` substring in output. Failed correctly (`node_modules/typescript missing`) before implementation.
- [x] **GREEN**: `make_build_fails()` now pins `typescript` to `5.6.3` (exact, lockfile-friendly), writes a fixture-local `.gitignore` excluding `node_modules/`, and runs `npm install --silent --no-audit --no-fund` after commits (with graceful WARNING fallback if `npm` is absent). `setup-fixtures.sh` now respects `FIXTURES_DIR` env override so the test can sandbox into a tmp dir. `build-fails.pattern` collapsed alternation to a single strict line `## Build [Vv]erification:.*(failed|✗)` — Verdict-fallback removed.

### Step F10 — Doc + .gitignore updates

- [x] **WIRED**: `.gitignore` now lists `tests/e2e/fixtures/` and `tests/e2e/results/` as their own bullet (alongside the existing `node_modules/` rule which covers the per-fixture installs). `tests/e2e/README.md` documents the `npm` requirement, hermetic build caveats (~23 MB, ~1 s), pinned TypeScript version (`5.6.3`), and explicit accepted-modes for `run.sh` so users don't misspell `--offline` and trigger live API spend.

## Final Verification

- [x] Step 1-4 RED→GREEN cycles all GREEN
- [x] All 5 fixture setup scripts run idempotently and produce deterministic main/feature topology
- [x] Both agent .md files are valid markdown (frontmatter parses, phase numbering continuous)
- [x] `bash tests/e2e/run.sh --self-check` exits 0
- [x] `bash tests/e2e/test-runner.sh` reports 11/11 PASS (5 original + 4 added in F1-F7 follow-up + 2 added in F8-F10 follow-up)
- [x] `bash tests/e2e/run.sh --offline` against the live-run captures reports 5/5 PASS — confirms the named-agent invocation produces the structured Phase 5 report and all 5 pattern files match; build-fails uses tightened pattern (no Verdict-fallback) and fresh capture proves the build-verification guardrail actually fires
- [x] `bash tests/e2e/run.sh` (live) reports 5/5 PASS against fresh captures — build-fails capture confirms `## Build Verification: ✗ failed` line is present (reviewer ran the build hermetically)
- [x] `bash tests/e2e/run.sh --bogus` rejects unknown mode with rc=2 and "unknown mode" message — typos no longer burn API spend
- [x] Existing eval suite (`config-gate`) still 18/18 PASS — no regression
- [x] Existing eval suite (`tdd-review-chain`) still 21/21 PASS — no regression
- [x] All 10 follow-up findings addressed (F1-F10)
- [x] **Caveat**: `tests/e2e/fixtures/build-fails/node_modules/` is generated by `setup-fixtures.sh` at ~23 MB. Fixture-local `.gitignore` excludes it; top-level `.gitignore` also excludes `tests/e2e/fixtures/`. `npm` is now a hard requirement for the build-fails guardrail (graceful WARNING fallback when npm missing).
- [ ] **Known hazard** (carried from prior round): `evals/tdd-manager/run-eval.sh --self-check` destructively overwrites `agents/code-reviewer.md` and `agents/tdd-manager.md` to a pristine pre-guardrail snapshot during its execution, and wipes `.zensu/`. Re-run that eval with caution; do not invoke from the same worktree as live agent edits.
